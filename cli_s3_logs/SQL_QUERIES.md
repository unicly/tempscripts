# Attribution queries — who accessed the data lake

Three Athena queries (workgroup `cloudtrail-correlation`, database
`cloudtrail_logs`) that return, for every S3 operation made through S3 Access
Grants, the **ARN of the grantee role** — for example
`arn:aws:iam::<FEEDER_ACCOUNT_ID>:role/FeederAccessGrantsRole`.

All three work **without** callers setting `SourceIdentity`, and were verified
in the PoC for a Feeder grantee and a Storage grantee, with and without
`SourceIdentity`. **Query 3 is the one to use day to day**; 1 and 2 are kept
for comparison and troubleshooting.

| | Query 1 — joins Storage and Feeder logs | Query 2 — hardcoded grants | Query 3 — grants history table |
|---|---|---|---|
| Needs Feeder logs (`feeder_trail`) | yes, for Feeder grantees | no | no |
| Needs a grant list | no | yes, inline in the query | no — table `access_grants_history` |
| Where the role ARN comes from | Feeder's `GetDataAccess` (`sessionissuer.arn`); for Storage grantees Storage's own | the grant → grantee list | the grant's `CREATED` line in the history CSV |
| Breaks when | Feeder logs are missing or not yet replicated | a grant is created or deleted and the list isn't updated | the history Lambda hasn't run since the grant was created |
| Location role name | `S3AccessGrantsLocationRole` (edit if yours differs) | `S3AccessGrantsLocationRole` (edit if yours differs) | any name |
| Verified on | 2026-11-09, run 22:03 UTC (no RAM) | 2026-11-09, runs 22:31 / 22:43 UTC (RAM share) | 2026-11-11: same 17 rows as Query 2, incl. a grant marked `DELETED` |

**Common to all three**

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

## Why a grant lookup is needed (and why Query 2 hardcodes it)

**What Storage's logs contain:** every `GetDataAccess` event in
`storage_datalake_trail` records **the grant it matched**:

```json
"additionalEventData": {
  "accessGrantsInfo": {
    "matchedAccessGrantArn": "arn:aws:s3:eu-west-1:637423360780:access-grants/default/grant/9d46a38b-7410-4355-8202-7dc3e1fb34af"
  }
}
```

The queries take the grant ID from it:

```sql
regexp_extract(additionaleventdata, 'grant/([a-f0-9-]+)', 1) AS grant_id
```

**What they don't contain:** the grantee's **ARN** when the grantee is a role
in another account. Storage records a Feeder caller of `GetDataAccess` like this:

```json
"userIdentity": { "type": "AWSAccount", "accountId": "262252232556",
                  "principalId": "AROAT2D3TP5WNHLG27VGO:DataLakePocObjectsFeederRole" }
```

That is the account and the **role ID** (`AROA…`), but no role name or ARN,
and Storage can't resolve the role ID into a name.

**So the queries need a lookup from grant ID to grantee ARN.** The grant ID
always comes from the logs; only its translation to an ARN needs outside
information. The grant itself knows its grantee, but that's configuration, not
a log event. Three ways to provide it:

| Option | Source of the grantee ARN | Pros and cons |
|---|---|---|
| **Hardcoded** (Query 2) | `VALUES` rows copied from `list-access-grants` | simple, but goes stale whenever grants change |
| **Grants history table** (Query 3) | `access_grants_history` table: append-only CSV kept by the `AccessGrantsInventory` Lambda | always current, keeps deleted grants |
| **Feeder's logs** (Query 1) | Feeder's copy of `GetDataAccess`, matched by `sharedeventid` | needs Feeder's management events in Storage; also gives the session and, via Feeder's `AssumeRole`, who assumed the role |

**For Storage grantees** the ARN *is* in Storage's logs
(`useridentity.sessioncontext.sessionissuer.arn`), because the caller is in the
same account. The lookup is only needed for grantees in other accounts — the
main case for a data lake.

Strictly speaking, the grant ID and the grantee ARN appear together in
Storage's logs once: in the `CreateAccessGrant` event that created the grant.
But that event only lives as long as your log retention. A grant created three
months ago with 30 days of logs can't be resolved that way any more, which is
why the grants history keeps its own record (Query 3).

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

---

## Query 3 — Storage logs only, grants from the history table

Like Query 2, but the grant → grantee lookup comes from the Glue table
`cloudtrail_logs.access_grants_history` instead of a hardcoded list. The table
reads the append-only CSV that the Lambda `AccessGrantsInventory` keeps in
`s3://<INVENTORY_BUCKET>/access-grants-history/access_grants_history.csv`
(scripts 15–17):

| Column | Content |
|---|---|
| `observed_at` | when the Lambda saw the change (not when it happened) |
| `event` | `CREATED` — grant appeared; `DELETED` — grant disappeared |
| `grant_id`, `grant_arn` | the grant |
| `grantee_type`, `grantee_identifier` | e.g. `IAM`, `arn:aws:iam::<FEEDER_ACCOUNT_ID>:role/FeederAccessGrantsRole` |
| `permission`, `grant_scope`, `location_id` | what the grant allows, where |
| `created_at` | when the grant was created (from Access Grants) |

The Lambda runs after every `CreateAccessGrant` / `DeleteAccessGrant`
(EventBridge) and once a day. It only ever **appends** lines; existing lines
are never changed or removed. A grant's `CREATED` line therefore stays after
the grant is deleted, so old log events still resolve to the right role —
grant IDs are never reused.

The S3 event filter matches any location role name (`/access-grants-<uuid>` at
the end of the caller ARN), so this query works with an existing Access Grants
setup whose location role isn't called `S3AccessGrantsLocationRole`.

```sql
WITH grants AS (               -- from the append-only grants history (Glue table)
    SELECT DISTINCT grant_id, grantee_identifier AS grantee_role_arn
    FROM cloudtrail_logs.access_grants_history
    WHERE event = 'CREATED'    -- grant IDs are never reused, so deleted grants still resolve
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
      AND regexp_like(useridentity.arn, '/access-grants-[a-f0-9-]+$')   -- any location role name
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

If an S3 event is missing from the result although Query 1 shows it, its grant
has no `CREATED` line yet: invoke `AccessGrantsInventory` once (it appends the
missing grant) and run the query again.

---

## Listing the grants

### Athena — from the grants history table

Needs the `access_grants_history` table (scripts 15–17).

Full history — every grant that ever existed, and when it appeared or
disappeared:

```sql
SELECT observed_at, event, grant_id, grantee_identifier, permission, grant_scope, created_at
FROM cloudtrail_logs.access_grants_history
ORDER BY observed_at, grant_id;
```

Only the grants that exist now — those whose last line is `CREATED`:

```sql
SELECT grant_id, grantee_type, grantee_identifier, permission, grant_scope, created_at
FROM (
    SELECT *, row_number() OVER (PARTITION BY grant_id
                                 ORDER BY observed_at DESC, event DESC) AS rn
    FROM cloudtrail_logs.access_grants_history
)
WHERE rn = 1 AND event = 'CREATED'
ORDER BY created_at;
```

The table is as current as the Lambda's last run: right after every
`CreateAccessGrant` / `DeleteAccessGrant`, and daily. Invoke
`AccessGrantsInventory` to bring it up to date immediately.

### AWS CLI — always current

Run in the account that owns the Access Grants instance:

```
aws s3control list-access-grants --account-id <STORAGE_ACCOUNT_ID> --region <REGION> --profile <storage> \
  --query 'AccessGrantsList[].[AccessGrantId, Grantee.GranteeType, Grantee.GranteeIdentifier, Permission, GrantScope, CreatedAt]' \
  --output table
```

Filter with `--grantee-identifier <role-arn>` or `--grant-scope 's3://<bucket>/*'`.

### Console

S3 → **Access Grants** (left menu) → select the region → **Grants** tab.
