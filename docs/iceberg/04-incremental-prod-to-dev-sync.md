# Incremental prod → dev sync with the Iceberg changelog view

Goal: keep a dev Iceberg table in sync with a (very large) prod Iceberg table by
applying only the **delta** since the last sync, instead of copying the full table.

Approach: a Spark job that uses Iceberg's `create_changelog_view` procedure to get the
rows that changed in prod between two snapshots, then `MERGE`s those rows into dev. The
job remembers which prod snapshot it last synced, so each run picks up exactly where the
previous one stopped.

## How it works

1. **One-time bootstrap:** full-copy prod into dev and record the prod snapshot ID you
   copied from.
2. **Each run:**
   - Read the last synced prod snapshot ID (stored as a table property on dev).
   - Get prod's current snapshot ID.
   - Create a changelog view over `(last, current]`. The start snapshot is exclusive.
   - `MERGE` the net changes into dev.
   - Save `current` as the new watermark.

## Bootstrap (once)

```sql
CREATE TABLE dev_cat.db.events USING iceberg
AS SELECT * FROM prod_cat.db.events VERSION AS OF <snap_id>;

ALTER TABLE dev_cat.db.events
SET TBLPROPERTIES ('sync.prod-snapshot-id' = '<snap_id>');
```

Use `VERSION AS OF` so the copy and the recorded ID refer to exactly the same snapshot.

## The Spark job (PySpark)

```python
from pyspark.sql import SparkSession

PROD = "prod_cat.db.events"   # prod table
DEV  = "dev_cat.db.events"    # dev table
KEYS = ["id"]                 # primary/identifier key column(s)
WM_PROP = "sync.prod-snapshot-id"

spark = (SparkSession.builder
    .config("spark.sql.extensions",
            "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
    # configure both catalogs (prod_cat, dev_cat) here: type, uri, warehouse...
    .getOrCreate())

# 1. Watermarks
props = {r.key: r.value for r in spark.sql(f"SHOW TBLPROPERTIES {DEV}").collect()}
start_snap = props.get(WM_PROP)
if start_snap is None:
    raise RuntimeError("Dev not bootstrapped – do a full copy first and set the property")

end_snap = spark.sql(
    f"SELECT snapshot_id FROM {PROD}.refs WHERE name = 'main'").first()[0]

if str(end_snap) == start_snap:
    print("Nothing to sync"); spark.stop(); raise SystemExit(0)

# 2. Changelog view with net changes (collapses multiple commits per key)
keys_sql = ", ".join(f"'{k}'" for k in KEYS)
spark.sql(f"""
  CALL prod_cat.system.create_changelog_view(
    table              => '{PROD.split('.', 1)[1]}',
    options            => map('start-snapshot-id', '{start_snap}',
                              'end-snapshot-id',   '{end_snap}'),
    identifier_columns => array({keys_sql}),
    net_changes        => true,
    changelog_view     => 'prod_changes'
  )
""")

# 3. One row per key: if the net result contains an INSERT, upsert it; else delete
spark.sql(f"""
  CREATE OR REPLACE TEMP VIEW prod_delta AS
  SELECT * FROM (
    SELECT *, row_number() OVER (
             PARTITION BY {', '.join(KEYS)}
             ORDER BY CASE WHEN _change_type = 'INSERT' THEN 0 ELSE 1 END) AS _rn
    FROM prod_changes)
  WHERE _rn = 1
""")

cols   = [f.name for f in spark.table(DEV).schema.fields]
on     = " AND ".join(f"t.{k} = s.{k}" for k in KEYS)
set_   = ", ".join(f"t.{c} = s.{c}" for c in cols)
ins_c  = ", ".join(cols)
ins_v  = ", ".join(f"s.{c}" for c in cols)

spark.sql(f"""
  MERGE INTO {DEV} t
  USING prod_delta s
  ON {on}
  WHEN MATCHED AND s._change_type = 'DELETE' THEN DELETE
  WHEN MATCHED THEN UPDATE SET {set_}
  WHEN NOT MATCHED AND s._change_type = 'INSERT' THEN INSERT ({ins_c}) VALUES ({ins_v})
""")

# 4. Advance the watermark
spark.sql(f"ALTER TABLE {DEV} SET TBLPROPERTIES ('{WM_PROP}' = '{end_snap}')")
```

## Things to watch

- **Snapshot expiration on prod is the biggest risk.** If `expire_snapshots` on prod
  removes the snapshot stored as your watermark, the changelog can't be computed and you
  need a new full copy. Keep prod's snapshot retention longer than your sync interval,
  and make the job fail loudly when the start snapshot is missing.
- **You need a key.** `identifier_columns` and the `MERGE` both depend on a primary key.
  Without one, net changes are computed on whole rows and the `MERGE` gets messy.
- **`net_changes` and `compute_updates` can't both be true.** With `net_changes`, an
  update appears as a `DELETE` of the old row plus an `INSERT` of the new one. The
  `row_number` step above handles that.
- **Merge-on-read tables:** older Iceberg versions don't support changelog scans over
  snapshots that contain delete files. If prod uses `write.delete.mode=merge-on-read`,
  check that your version handles it. Copy-on-write tables work.
- **Re-running is safe.** The `MERGE` and the watermark update aren't atomic. But
  re-applying the same net delta (upsert or delete by key) gives the same result, so if
  the job dies between the two steps, just run it again.
- **Schema changes:** the dynamic column list follows dev's schema. If prod adds a
  column, add it to dev with `ALTER TABLE` before the next sync.
- **Append-only prod has a simpler option.** If prod is only ever appended to, skip the
  changelog and use an incremental read with an append:

  ```python
  spark.read.format("iceberg") \
      .option("start-snapshot-id", start_snap) \
      .option("end-snapshot-id", end_snap) \
      .load(PROD).writeTo(DEV).append()
  ```

## Running it

Schedule it as a normal Spark job (Airflow, cron, etc.), as often as your prod snapshot
retention allows. Test it on a small table first, especially the catalog configuration
and the `table =>` argument of the procedure.
