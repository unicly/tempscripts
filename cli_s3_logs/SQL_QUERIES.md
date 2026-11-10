# Attribution queries — who accessed the data lake

Two Athena queries (workgroup `cloudtrail-correlation`, database
`cloudtrail_logs`) that return, for every S3 operation made through S3 Access
Grants, the **ARN of the grantee role** — for example
`arn:aws:iam::<FEEDER_ACCOUNT_ID>:role/FeederAccessGrantsRole`.

Both work **without** callers setting `SourceIdentity`. Both were verified on
2026-11-09 in the PoC, for a Feeder grantee and a Storage grantee, with and
without `SourceIdentity`.

| | Query 1 — joins Storage and Feeder logs | Query 2 — hardcoded grants |
|---|---|---|
| Needs Feeder logs (`feeder_trail`) | yes, for Feeder grantees | no |
| Needs a grant list | no | yes, inline in the query |
| Where the role ARN comes from | Feeder's `GetDataAccess` (`sessionissuer.arn`); for Storage grantees Storage's own | the grant → grantee list |
| Breaks when | Feeder logs are missing or not yet replicated | a grant is created or deleted and the list isn't updated |
| Verified on | test run 22:03 UTC (no RAM) | test runs 22:31 and 22:43 UTC (RAM share) |

A third variant, which replaces the hardcoded list with the automatically
updated `access_grants` table, is in [DATALAKE_README.md](DATALAKE_README.md), step 10.

**Common to both**

- Chain: S3 data event → `access-grants-<uuid>` session (exact) → Access
  Grants' internal `AssumeRole` → `GetDataAccess` (timestamp within ±2 s — the
  only link without a shared ID).
- If two **different** grantees call within the same 2 seconds, one S3 event
  can appear twice, once per grantee.
- One grant per consuming role, otherwise the grantee isn't unique.
- Set `year` and `month` in every CTE to the period you query (partition
  filter — avoids scanning all logs).
- CloudTrail delivers after 5–15 minutes; management events can arrive later
  than the S3 data events. Query only once both are in.

---

## Query 1 — join Storage and Feeder logs

Finds the Storage copy of each `GetDataAccess` call and, for Feeder grantees,
the Feeder copy of the same call through `sharedeventid` (identical in both
accounts). Feeder's copy contains the full role ARN; Storage's copy only has
the Feeder account and role ID. For Storage grantees, Storage's own copy
already has the role ARN.

Also returns the grant ID and the caller's account.

```sql
WITH ag_sessions AS (          -- Access Grants vends a scoped session (Storage trail)
    SELECT from_iso8601_timestamp(eventtime) AS t,
           regexp_extract(requestparameters, '"roleSessionName"\s*:\s*"([^"]+)"', 1) AS session_name
    FROM cloudtrail_logs.storage_datalake_trail
    WHERE year = '2026' AND month = '11'
      AND eventsource = 'sts.amazonaws.com' AND eventname = 'AssumeRole'
      AND requestparameters LIKE '%access-grants-%'
),
storage_gda AS (               -- GetDataAccess as seen by Storage
    SELECT from_iso8601_timestamp(eventtime) AS t, sharedeventid,
           useridentity.accountid                         AS caller_account,
           useridentity.sessioncontext.sessionissuer.arn  AS same_account_role_arn,   -- set for Storage grantees
           regexp_extract(additionaleventdata, 'grant/([a-f0-9-]+)', 1) AS grant_id
    FROM cloudtrail_logs.storage_datalake_trail
    WHERE year = '2026' AND month = '11' AND eventname = 'GetDataAccess'
),
feeder_gda AS (                -- the same call as seen by Feeder (only for Feeder grantees)
    SELECT sharedeventid,
           useridentity.sessioncontext.sessionissuer.arn AS feeder_role_arn
    FROM cloudtrail_logs.feeder_trail
    WHERE year = '2026' AND month = '11' AND eventname = 'GetDataAccess'
),
s3_events AS (
    SELECT from_iso8601_timestamp(eventtime) AS t, eventtime, eventname,
           regexp_extract(useridentity.arn, '(access-grants-[a-f0-9-]+)$', 1) AS session_name,
           useridentity.sessioncontext.sourceidentity AS source_identity,
           regexp_extract(requestparameters, '"bucketName"\s*:\s*"([^"]+)"', 1) AS bucket,
           regexp_extract(requestparameters, '"key"\s*:\s*"([^"]+)"', 1)        AS file_path
    FROM cloudtrail_logs.storage_datalake_trail
    WHERE year = '2026' AND month = '11'
      AND eventsource = 's3.amazonaws.com'
      AND eventname IN ('GetObject', 'PutObject', 'DeleteObject', 'CopyObject', 'ListObjects')
      AND useridentity.arn LIKE '%S3AccessGrantsLocationRole/access-grants-%'
)
SELECT DISTINCT
    s3.eventtime,
    coalesce(f.feeder_role_arn, g.same_account_role_arn) AS grantee_role_arn,
    g.caller_account,
    g.grant_id,
    s3.source_identity,
    s3.eventname AS operation,
    s3.bucket,
    s3.file_path
FROM s3_events s3
JOIN ag_sessions ag    ON ag.session_name = s3.session_name                       -- exact
JOIN storage_gda g     ON abs(to_unixtime(g.t) - to_unixtime(ag.t)) <= 2          -- timing only
LEFT JOIN feeder_gda f ON f.sharedeventid = g.sharedeventid                       -- exact
ORDER BY s3.eventtime DESC
```

If `grantee_role_arn` is empty for a Feeder grantee, the matching Feeder event
hasn't reached `feeder_trail` yet (replication delay) or Feeder's trail doesn't
log management events. `caller_account` and `grant_id` are filled anyway.

To also see **who assumed** the grantee role (idea, not tested), join `feeder_trail` once more on
Feeder's `AssumeRole` events where `requestparameters` contains the grantee
role ARN and `responseelements` contains the access key used on Feeder's
`GetDataAccess` (`useridentity.accesskeyid`).

---

## Query 2 — Storage logs only, grants hardcoded

Uses only Storage's logs. The grant matched by each `GetDataAccess`
(`matchedAccessGrantArn`) is translated into its grantee with an inline list.

Generate the list from the live grants:

```
aws s3control list-access-grants --account-id <STORAGE_ACCOUNT_ID> --region <REGION> \
  --query 'AccessGrantsList[].[AccessGrantId, Grantee.GranteeIdentifier]' --output text
```

and replace the `VALUES` rows. The two rows below are the PoC's grants.

```sql
WITH grants (grant_id, grantee_role_arn) AS (   -- from: aws s3control list-access-grants
    VALUES
      ('577e0997-7d6c-4435-b9a0-0abde5fd59b0', 'arn:aws:iam::637423360780:role/StorageAssumeRoleBucketRole'),
      ('9d46a38b-7410-4355-8202-7dc3e1fb34af', 'arn:aws:iam::262252232556:role/FeederAccessGrantsRole')
),
ag_sessions AS (               -- Access Grants vends a scoped session
    SELECT from_iso8601_timestamp(eventtime) AS t,
           regexp_extract(requestparameters, '"roleSessionName"\s*:\s*"([^"]+)"', 1) AS session_name
    FROM cloudtrail_logs.storage_datalake_trail
    WHERE year = '2026' AND month = '11'
      AND eventsource = 'sts.amazonaws.com' AND eventname = 'AssumeRole'
      AND requestparameters LIKE '%access-grants-%'
),
gda AS (                       -- GetDataAccess: which grant was matched
    SELECT from_iso8601_timestamp(eventtime) AS t,
           regexp_extract(additionaleventdata, 'grant/([a-f0-9-]+)', 1) AS grant_id
    FROM cloudtrail_logs.storage_datalake_trail
    WHERE year = '2026' AND month = '11' AND eventname = 'GetDataAccess'
),
s3_events AS (
    SELECT eventtime, eventname,
           regexp_extract(useridentity.arn, '(access-grants-[a-f0-9-]+)$', 1) AS session_name,
           regexp_extract(requestparameters, '"bucketName"\s*:\s*"([^"]+)"', 1) AS bucket,
           regexp_extract(requestparameters, '"key"\s*:\s*"([^"]+)"', 1)        AS file_path
    FROM cloudtrail_logs.storage_datalake_trail
    WHERE year = '2026' AND month = '11'
      AND eventsource = 's3.amazonaws.com'
      AND eventname IN ('GetObject', 'PutObject', 'DeleteObject', 'CopyObject', 'ListObjects')
      AND useridentity.arn LIKE '%S3AccessGrantsLocationRole/access-grants-%'
)
SELECT DISTINCT
    s3.eventtime,
    gr.grantee_role_arn,
    s3.eventname AS operation,
    s3.bucket,
    s3.file_path
FROM s3_events s3
JOIN ag_sessions ag ON ag.session_name = s3.session_name                    -- exact
JOIN gda g          ON abs(to_unixtime(g.t) - to_unixtime(ag.t)) <= 2       -- timing only
JOIN grants gr      ON gr.grant_id = g.grant_id                             -- exact
ORDER BY s3.eventtime DESC
```

A grant missing from the list makes its S3 events disappear from the result
(inner join). Use `LEFT JOIN grants` and select `g.grant_id` too if you'd
rather see them with an empty ARN.
