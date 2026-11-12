# Troubleshooting

| Symptom | Go to |
|---|---|
| An attribution query returns **0 rows** | checks 0–5, in order |
| Query 1 returns rows, but **`grantee_role_arn` is empty** | check 6 |
| The CSV **header line shows up as a row** in `access_grants_history` | check 7 |
| The **EventBridge rule doesn't fire** / the grants history CSV doesn't change | check 8 |

## Attribution query returns 0 rows

The attribution queries (`SQL_QUERIES.md`, `DATALAKE_README.md` section 10) are a
chain of joins. If **any** link is empty, the result is 0 rows. Run the checks
below in order, in Athena (workgroup `cloudtrail-correlation`), and stop at the
first one that returns nothing — that's the broken link.

Replace `<DATALAKE_BUCKET>` with your bucket name. Use the current `year`/`month`.

Wait at least **15 minutes** after the Lambda test before concluding anything:
management events (`GetDataAccess`, `AssumeRole`) often arrive later than the
S3 data events.

---

## 0. Was the table created by script 17?

```sql
SHOW CREATE TABLE cloudtrail_logs.storage_datalake_trail;
```

The queries need these columns: `eventtime`, `eventsource`, `eventname`,
`useridentity` (with `arn`, `accountid`, and `sessioncontext` containing
`sessionissuer` **and `sourceidentity`**), `requestparameters`,
`additionaleventdata`, `sharedeventid`. A table created with the CloudTrail
console's "Create Athena table" (older column list) or by hand may lack some
of them — e.g. `eventcategory` or `sourceidentity`. Simplest fix: drop it and
recreate it with `17_storage_glue_athena.sh` (partition projection, nothing to
load afterwards). Same for `feeder_trail`.

## 1. Does the Storage table see any logs at all?

```sql
SELECT count(*) AS events, min(eventtime) AS first, max(eventtime) AS last
FROM cloudtrail_logs.storage_datalake_trail
WHERE year = '2026' AND month = '11';
```

**0 rows / count 0** → the table points to the wrong S3 path. Compare the
table's location with where the trail really writes:

```
aws s3 ls s3://<STORAGE_CT_BUCKET>/AWSLogs/ --profile <storage>
```

- Expected: `AWSLogs/<STORAGE_ACCOUNT_ID>/CloudTrail/<REGION>/YYYY/MM/DD/`.
- **Organization trail** (common in PROD): `AWSLogs/<o-xxxxxxxxxx>/<ACCOUNT_ID>/CloudTrail/<REGION>/…`
  → recreate the table with that prefix in `LOCATION` **and** in
  `storage.location.template`.
- Different region in the path than `REGION` in `.env` → same fix.
- Trail writes to another bucket (an existing trail was reused) → point the
  table at that bucket.

Same check for `cloudtrail_logs.feeder_trail` (needed by Query 1 only).

---

## 2. Are the S3 data events on the data lake logged, and by which role?

```sql
SELECT eventname, useridentity.arn AS caller, count(*) AS n, max(eventtime) AS last
FROM cloudtrail_logs.storage_datalake_trail
WHERE year = '2026' AND month = '11'
  AND eventsource = 's3.amazonaws.com'
  AND requestparameters LIKE '%<DATALAKE_BUCKET>%'
  AND eventname IN ('PutObject', 'GetObject', 'DeleteObject', 'CopyObject', 'ListObjects')
GROUP BY 1, 2
ORDER BY last DESC;
```

- **No rows** → the trail doesn't log data events for this bucket. Check the
  trail's advanced event selectors: `resources.ARN StartsWith
  arn:aws:s3:::<DATALAKE_BUCKET>/` (exact bucket name, trailing `/`), and that
  the trail is logging (`aws cloudtrail get-trail-status`).
- **Rows** → the `caller` is your **location role**:
  `…:assumed-role/<location role>/access-grants-<uuid>`. The queries in
  `SQL_QUERIES.md` match any role name (they look for `/access-grants-<uuid>`
  at the end). If you use an older copy of a query that filters with
  `LIKE '%S3AccessGrantsLocationRole/access-grants-%'` and your role has another
  name, replace that line with
  ```sql
  AND regexp_like(useridentity.arn, '/access-grants-[a-f0-9-]+$')
  ```

---

## 3. Is Access Grants' internal AssumeRole logged?

```sql
SELECT eventtime,
       regexp_extract(requestparameters, '"roleArn"\s*:\s*"([^"]+)"', 1)         AS location_role,
       regexp_extract(requestparameters, '"roleSessionName"\s*:\s*"([^"]+)"', 1) AS session_name
FROM cloudtrail_logs.storage_datalake_trail
WHERE year = '2026' AND month = '11'
  AND eventsource = 'sts.amazonaws.com' AND eventname = 'AssumeRole'
  AND requestparameters LIKE '%access-grants-%'
ORDER BY eventtime DESC
LIMIT 20;
```

- **No rows** → management events aren't logged (selector), or not delivered
  yet. The trail needs the management-events selector; `sts.amazonaws.com`
  must not be excluded.
- Rows → compare `session_name` with the `access-grants-<uuid>` at the end of
  `caller` in check 2. They must match for the same operation.

---

## 4. Is GetDataAccess logged, and which grant does it match?

```sql
SELECT eventtime,
       useridentity.type AS caller_type, useridentity.accountid AS caller_account,
       regexp_extract(additionaleventdata, 'grant/([a-f0-9-]+)', 1) AS grant_id,
       errorcode
FROM cloudtrail_logs.storage_datalake_trail
WHERE year = '2026' AND month = '11' AND eventname = 'GetDataAccess'
ORDER BY eventtime DESC
LIMIT 20;
```

- **No rows** → same as check 3 (management events missing or late).
- `grant_id` empty, `errorcode` set → the call was denied; the Lambda would
  then also have failed.
- Note the `grant_id` values — you need them for check 5.
- Timestamps of `GetDataAccess` and the AssumeRole in check 3 should be within
  2 seconds of each other (the query joins on that).

---

## 5. Does the grants lookup know these grant IDs?

**Query 2 (hardcoded grants):** the `VALUES` rows in the query are the
**PoC's** grant IDs. Replace them with yours:

```
aws s3control list-access-grants --account-id <STORAGE_ACCOUNT_ID> --region <REGION> --profile <storage> \
  --query 'AccessGrantsList[].[AccessGrantId, Grantee.GranteeIdentifier]' --output text
```

**Query 3 / README query (grants history table):**

```sql
SELECT observed_at, event, grant_id, grantee_identifier
FROM cloudtrail_logs.access_grants_history
ORDER BY observed_at DESC
LIMIT 20;
```

- **No rows** → the Lambda hasn't run yet, or the table points elsewhere. Run
  it once (`aws lambda invoke --function-name AccessGrantsInventory …`) and
  check that `s3://<INVENTORY_BUCKET>/access-grants-history/access_grants_history.csv`
  exists. The CloudWatch log of the run shows `appended` / `created` / `deleted`.
- **Strange rows** (shifted columns, a header line as data) → see check 7, or
  another file sits under `access-grants-history/`; the table reads every file in that
  prefix. Keep only the CSV there.
- Rows but your `grant_id` from check 4 has no `CREATED` line → the Lambda
  hasn't run since the grant was created (EventBridge rule missing or the
  event not delivered yet); invoke the Lambda once — it appends the missing grant.

---

## 6. Query 1: `grantee_role_arn` is empty

Query 1 takes the ARN of a Feeder grantee from **Feeder's copy** of
`GetDataAccess` in `feeder_trail` (LEFT JOIN on `sharedeventid`). An empty ARN
with a filled `grant_id` means that copy is missing. (If Query 1 returns 0
rows, the cause is in checks 1–4.) Query 3 doesn't need Feeder's logs.

**6.1 Does `feeder_trail` contain management events and `GetDataAccess`?**

```sql
SELECT eventcategory,
       count(*)                              AS events,
       count_if(eventname = 'GetDataAccess') AS get_data_access,
       max(eventtime)                        AS last
FROM cloudtrail_logs.feeder_trail
WHERE year = '2026' AND month = '11'
GROUP BY eventcategory;
```

| Result | Cause | Fix |
|---|---|---|
| no rows | table points to the wrong path in the replica bucket | as check 1, for `feeder_trail` |
| only `Data` | **the Feeder trail logs no management events** — seen in practice | Feeder: CloudTrail → trail → **Management events** → Read and Write. Applies from then on; earlier calls stay without a Feeder copy |
| `Management`, but `get_data_access = 0` | not replicated yet, or `s3.amazonaws.com` excluded in the selector | wait ~20 min (CloudTrail + replication); check selector and replication status |
| `get_data_access > 0` | events are there | 6.2 |

**6.2 Do the Feeder and Storage copies share a `sharedeventid`?**

```sql
SELECT s.eventtime, s.sharedeventid,
       f.useridentity.sessioncontext.sessionissuer.arn AS feeder_role_arn
FROM cloudtrail_logs.storage_datalake_trail s
LEFT JOIN cloudtrail_logs.feeder_trail f
  ON f.sharedeventid = s.sharedeventid AND f.eventname = 'GetDataAccess'
 AND f.year = '2026' AND f.month = '11'
WHERE s.year = '2026' AND s.month = '11' AND s.eventname = 'GetDataAccess'
ORDER BY s.eventtime DESC
LIMIT 20;
```

In the PoC every pair matched. `feeder_role_arn` empty here for recent calls →
those calls happened before Feeder's management events were on, or haven't
been replicated yet.

---

## 7. The CSV header appears as a row in `access_grants_history`

Symptom: a row with `observed_at = 'observed_at'`, `event = 'event'`, … in the
results. Fix: the table property **`skip.header.line.count = 1`** — Athena then
skips the first line of every file under the table's location.
`17_storage_glue_athena.sh` sets it; tables created another way may lack it.

**In the DDL** (when creating the table):

```sql
CREATE EXTERNAL TABLE cloudtrail_logs.access_grants_history ( … )
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ('separatorChar' = ',', 'quoteChar' = '"', 'escapeChar' = '\\')
LOCATION 's3://<INVENTORY_BUCKET>/access-grants-history/'
TBLPROPERTIES ('skip.header.line.count' = '1');
```

**On an existing table** (Athena):

```sql
ALTER TABLE cloudtrail_logs.access_grants_history
SET TBLPROPERTIES ('skip.header.line.count' = '1');
```

**In the Glue console:** Data Catalog → **Tables** → the table → **Actions** →
**Edit table** → **Table properties** → **Add**: key `skip.header.line.count`,
value `1` → **Save**.

**With a Glue crawler:** create a **custom CSV classifier** with
**Column headings: Has headings** and attach it to the crawler. It then uses the
header for column names and sets `skip.header.line.count` itself. Without it the
crawler often doesn't detect the header — typically when all columns are
strings, as here.

Good to know:

- The header is skipped **in every file** under the location, so each file needs
  exactly one header line at the top. The Lambda writes it once, when it creates
  the file. A second file without a header under the same prefix would lose its
  first data line.
- With **OpenCSVSerde** every column is a `string`; convert in the query if
  needed (`CAST`, `from_iso8601_timestamp`).
- The property only affects reading; the file isn't changed.

---

## 8. The EventBridge rule doesn't fire when grants change

Symptom: you create or delete a grant, but `AccessGrantsInventory` doesn't
run and no `CREATED` / `DELETED` line is appended to the grants history CSV.
Go through the checks in order.

**8.1 Did CloudTrail record the change, and in which region?**
In the **Storage** account: CloudTrail → **Event history**, region of the Access
Grants instance, filter **Event name** = `CreateAccessGrant` (or
`DeleteAccessGrant`). The event must be there. Note `awsRegion`, and check
there's no `errorCode` (a failed call is still an event, but nothing changed).

**8.2 Is the rule in the right place and enabled?**
EventBridge → **Rules**:

- same **region** as the event's `awsRegion` — EventBridge only sees calls
  made in its own region;
- event bus **`default`** — AWS service events (including "AWS API Call via
  CloudTrail") are only delivered to the default bus, never to a custom bus;
- status **Enabled**.

**8.3 Is the event pattern exactly right?** — *the most common cause*
Values are compared **exactly, including upper/lower case**. The pattern must be:

```json
{
  "source": ["aws.s3"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["s3.amazonaws.com"],
    "eventName": ["CreateAccessGrant", "DeleteAccessGrant"]
  }
}
```

Seen in practice: `"AWS API Call via Cloudtrail"` (lowercase *t*) — valid JSON,
but it never matches, so the rule silently never fires. Also watch for
mismatched quotes (`"s3.amazonaws.com'`).

To verify a pattern without changing grants: edit the rule → **Event pattern**
→ **Sample event** → **Enter my own**, paste the CloudTrail event record wrapped
in an EventBridge envelope, and click **Test pattern** — it should say "Sample
event matched the event pattern":

```json
{
  "version": "0",
  "id": "test",
  "detail-type": "AWS API Call via CloudTrail",
  "source": "aws.s3",
  "account": "<STORAGE_ACCOUNT_ID>",
  "time": "<eventTime from the record>",
  "region": "<awsRegion from the record>",
  "resources": [],
  "detail": <the CloudTrail event record>
}
```

**8.4 Did the rule match, and did it call the Lambda?**
Wait 2–5 minutes after a grant change, then rule → **Monitoring** (1-minute period):

| Metric | Meaning if 0 / if > 0 |
|---|---|
| **TriggeredRules** / MatchedEvents | 0 → the pattern doesn't match (8.3), or wrong region/bus (8.2) |
| **Invocations** | 0 while TriggeredRules > 0 → no target, or target misconfigured |
| **FailedInvocations** | > 0 → EventBridge couldn't call the Lambda: wrong function, or the Lambda's resource permission for `events.amazonaws.com` is missing (the console adds it automatically when you pick a Lambda target; the CLI needs `aws lambda add-permission`, see script 16) |

**8.5 Did the Lambda run, and what did it do?**
Lambda → `AccessGrantsInventory` → **Monitor** → **View CloudWatch logs**. A
successful run logs e.g. `{"appended": 1, "created": 1, "deleted": 0, …}`.
`"appended": 0` means the grant was already in the CSV. Errors such as
`PreconditionFailed` (the file changed during the run) are retried by Lambda
automatically.

---

## Quick reference: what each link needs

| Link | Needs | Typical cause of 0 rows |
|---|---|---|
| table → logs | `LOCATION` = real trail path | organization trail path, other region, other bucket |
| S3 data events | data-event selector on the bucket | wrong bucket name in selector |
| S3 event filter | `/access-grants-<uuid>` at the end of the caller ARN | an old query copy filtering on `S3AccessGrantsLocationRole` with another role name (check 2) |
| AssumeRole + GetDataAccess | management events | selector, or not delivered yet |
| grant → role | grant IDs in lookup | PoC IDs left in Query 2, grant missing from `access_grants_history` |
| Feeder ARN (Query 1) | management events on the Feeder trail | Feeder trail with data events only (check 6) |
| grant change → history CSV | EventBridge rule on the `default` bus, exact pattern | `Cloudtrail` instead of `CloudTrail` in `detail-type`; rule in another region (check 8) |
