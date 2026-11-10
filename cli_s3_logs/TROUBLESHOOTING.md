# Attribution query returns 0 rows — troubleshooting

The attribution queries (`SQL_QUERIES.md`, `DATALAKE_README.md` step 10) are a
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
- **Rows, but `caller` is not `…:assumed-role/S3AccessGrantsLocationRole/access-grants-…`**
  → your Access Grants location uses a **different location role name**. The
  queries filter on that name. Change, in every query,
  ```sql
  AND useridentity.arn LIKE '%S3AccessGrantsLocationRole/access-grants-%'
  ```
  to your role name, or role-name independent:
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

**README query (inventory table):**

```sql
SELECT grant_id, grantee_identifier, exported_at
FROM cloudtrail_logs.access_grants
ORDER BY exported_at DESC
LIMIT 20;
```

- **No rows** → no snapshot yet, or the table points elsewhere. Run the
  inventory Lambda once (`aws lambda invoke --function-name AccessGrantsInventory …`)
  and check `s3://<INVENTORY_BUCKET>/access-grants/` has a `.json` file.
- Rows but your `grant_id` from check 4 isn't there → the grant was created
  after the last snapshot; invoke the Lambda again.

---

## 6. Query 1 only: is the Feeder copy of GetDataAccess there?

```sql
SELECT eventtime, sharedeventid, useridentity.sessioncontext.sessionissuer.arn AS feeder_role_arn
FROM cloudtrail_logs.feeder_trail
WHERE year = '2026' AND month = '11' AND eventname = 'GetDataAccess'
ORDER BY eventtime DESC
LIMIT 20;
```

Query 1 uses a LEFT JOIN here, so a missing Feeder copy gives an empty
`grantee_role_arn` — not 0 rows. If Query 1 returns 0, the cause is in checks 1–4.

---

## Quick reference: what each link needs

| Link | Needs | Typical cause of 0 rows |
|---|---|---|
| table → logs | `LOCATION` = real trail path | organization trail path, other region, other bucket |
| S3 data events | data-event selector on the bucket | wrong bucket name in selector |
| S3 event filter | location role name in `LIKE` | existing Access Grants setup with another role name |
| AssumeRole + GetDataAccess | management events | selector, or not delivered yet |
| grant → role | grant IDs in lookup | PoC IDs left in Query 2, empty `access_grants` table |
