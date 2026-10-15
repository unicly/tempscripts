"""
Restore an Iceberg table into a new S3 folder with rewrite_table_path and register it in AWS Glue.

Runs on OSS Spark with the Apache Iceberg runtime (Amazon EMR, EMR Serverless, AWS Glue 5 jobs).
It does NOT run on Databricks clusters: Databricks Runtime doesn't ship the OSS Iceberg Spark
procedures (CALL ... system.rewrite_table_path) and loading OSS Iceberg jars isn't supported there.

Requirements
- Iceberg Spark runtime with the rewrite_table_path procedure (check your Iceberg version) and the
  AWS bundle (GlueCatalog, S3FileIO) on the classpath.
- The files of the source table must be readable at the paths recorded INSIDE its metadata
  (the "source prefix"). See docs/iceberg/25-run-rewrite-table-path-restore.md.
- IAM permissions: read source prefix + staging, write target prefix + staging, Glue create/drop table.

Example (EMR):
  spark-submit restore_with_rewrite_table_path.py \
    --metadata-dir     s3://old-bucket/path/orders/metadata/ \
    --target-prefix    s3://new-bucket/restored/orders \
    --staging          s3://new-bucket/_iceberg_staging/orders/ \
    --warehouse        s3://new-bucket/warehouse/ \
    --target-table     restored.orders
"""
import argparse
import json
import re
from urllib.parse import urlparse

import boto3
from pyspark.sql import SparkSession

CATALOG = "glue"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--metadata-dir", help="s3://.../metadata/ folder of the source table (latest metadata.json is picked)")
    p.add_argument("--metadata-file", help="explicit s3://.../xxxxx.metadata.json (overrides --metadata-dir)")
    p.add_argument("--source-prefix", help="prefix written inside the metadata; default: 'location' of the metadata.json")
    p.add_argument("--target-prefix", required=True, help="new table folder, e.g. s3://new-bucket/restored/orders")
    p.add_argument("--staging", required=True, help="staging folder for rewritten metadata, e.g. s3://new-bucket/_staging/orders/")
    p.add_argument("--warehouse", required=True, help="Glue catalog warehouse path (only used for new tables)")
    p.add_argument("--target-table", required=True, help="Glue table to register, as database.table")
    p.add_argument("--tmp-table", default="restore_tmp.source_table", help="temporary Glue table for the source")
    p.add_argument("--dry-run", action="store_true", help="rewrite metadata but don't copy files or register")
    return p.parse_args()


def split_s3(uri):
    u = urlparse(uri)
    if u.scheme not in ("s3", "s3a"):
        raise ValueError(f"not an s3 URI: {uri}")
    return u.netloc, u.path.lstrip("/")


def find_latest_metadata(s3, metadata_dir):
    """Return the s3 URI of the metadata.json with the highest version number."""
    bucket, prefix = split_s3(metadata_dir.rstrip("/") + "/")
    candidates = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.endswith(".metadata.json"):
                continue
            m = re.match(r"^(\d+)-", key.rsplit("/", 1)[-1])
            candidates.append((int(m.group(1)) if m else -1, obj["LastModified"], key))
    if not candidates:
        raise FileNotFoundError(f"no *.metadata.json under {metadata_dir}")
    _, _, key = max(candidates)
    return f"s3://{bucket}/{key}"


def read_json(s3, uri):
    bucket, key = split_s3(uri)
    return json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())


def check_current_snapshot_readable(s3, meta):
    """Fail early if the current snapshot's manifest list isn't at the path recorded in the metadata."""
    current = meta.get("current-snapshot-id")
    if current in (None, -1):
        print("table has no current snapshot (empty table)")
        return
    snap = next(s for s in meta["snapshots"] if s["snapshot-id"] == current)
    bucket, key = split_s3(snap["manifest-list"])
    try:
        s3.head_object(Bucket=bucket, Key=key)
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(
            f"manifest list {snap['manifest-list']} is not readable. rewrite_table_path reads the "
            f"source files at the paths recorded in the metadata, so restore them there first."
        ) from e


def copy_partition(rows):
    s3 = boto3.client("s3")
    for src, dst in rows:
        sb, sk = split_s3(src)
        db, dk = split_s3(dst)
        s3.copy({"Bucket": sb, "Key": sk}, db, dk)  # managed copy, multipart for large files


def main():
    args = parse_args()
    s3 = boto3.client("s3")

    metadata_file = args.metadata_file or find_latest_metadata(s3, args.metadata_dir)
    meta = read_json(s3, metadata_file)
    source_prefix = (args.source_prefix or meta["location"]).rstrip("/")
    target_prefix = args.target_prefix.rstrip("/")
    print(f"metadata file : {metadata_file}")
    print(f"table-uuid    : {meta.get('table-uuid')}")
    print(f"source prefix : {source_prefix}")
    print(f"target prefix : {target_prefix}")
    check_current_snapshot_readable(s3, meta)

    spark = (
        SparkSession.builder.appName("iceberg-restore-rewrite-table-path")
        .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
        .config(f"spark.sql.catalog.{CATALOG}", "org.apache.iceberg.spark.SparkCatalog")
        .config(f"spark.sql.catalog.{CATALOG}.catalog-impl", "org.apache.iceberg.aws.glue.GlueCatalog")
        .config(f"spark.sql.catalog.{CATALOG}.io-impl", "org.apache.iceberg.aws.s3.S3FileIO")
        .config(f"spark.sql.catalog.{CATALOG}.warehouse", args.warehouse)
        .getOrCreate()
    )

    tmp_db = args.tmp_table.split(".")[0]
    tgt_db = args.target_table.split(".")[0]
    spark.sql(f"CREATE NAMESPACE IF NOT EXISTS {CATALOG}.{tmp_db}")
    spark.sql(f"CREATE NAMESPACE IF NOT EXISTS {CATALOG}.{tgt_db}")

    # 1. Register the source metadata.json as a temporary Glue table
    spark.sql(f"DROP TABLE IF EXISTS {CATALOG}.{args.tmp_table}")  # no PURGE: files are never deleted
    spark.sql(f"CALL {CATALOG}.system.register_table(table => '{args.tmp_table}', metadata_file => '{metadata_file}')")
    print("source rows   :", spark.table(f"{CATALOG}.{args.tmp_table}").count())

    # 2. Rewrite all paths (metadata.json, manifest lists, manifests, position deletes) into staging
    res = spark.sql(f"""
        CALL {CATALOG}.system.rewrite_table_path(
          table            => '{args.tmp_table}',
          source_prefix    => '{source_prefix}',
          target_prefix    => '{target_prefix}',
          staging_location => '{args.staging}')
    """).collect()[0]
    latest_version, file_list = res["latest_version"], res["file_list_location"]
    print(f"latest version: {latest_version}")
    print(f"file list     : {file_list}")

    pairs = spark.read.csv(file_list).toDF("src", "dst")
    target_metadata = (
        pairs.filter(pairs.dst.endswith(latest_version.rsplit("/", 1)[-1])).select("dst").first()["dst"]
    )
    print(f"target metadata.json: {target_metadata}")
    if args.dry_run:
        print("dry run: nothing copied, nothing registered")
        return

    # 3. Copy: data/delete files first, then manifests, then metadata.json files last
    is_meta_json = pairs.dst.endswith(".metadata.json")
    is_metadata = pairs.dst.contains("/metadata/")
    for name, cond in [
        ("data and delete files", ~is_metadata),
        ("manifests and manifest lists", is_metadata & ~is_meta_json),
        ("metadata.json files", is_meta_json),
    ]:
        part = pairs.filter(cond)
        print(f"copying {part.count()} {name}")
        part.rdd.map(lambda r: (r.src, r.dst)).foreachPartition(copy_partition)

    # 4. Drop the temporary table (no PURGE) and register the restored table
    spark.sql(f"DROP TABLE {CATALOG}.{args.tmp_table}")
    spark.sql(f"CALL {CATALOG}.system.register_table(table => '{args.target_table}', metadata_file => '{target_metadata}')")

    # 5. Validate
    restored = f"{CATALOG}.{args.target_table}"
    print("restored rows :", spark.table(restored).count())
    spark.sql(f"SELECT snapshot_id, committed_at, operation FROM {restored}.snapshots ORDER BY committed_at").show(truncate=False)


if __name__ == "__main__":
    main()
