# CloudTrail data events: why and where

You turn data events on **in CloudTrail, on the trail**, not on the bucket.
The bucket has no setting for them.

## Why they're needed

CloudTrail logs two kinds of events:

| Category | Examples | Logged by default? |
|---|---|---|
| **Management events** | `GetDataAccess`, `AssumeRole`, `CreateAccessGrant` | Yes |
| **Data events** | `GetObject`, `PutObject`, `DeleteObject`, `ListObjects` on objects | **No**, you must turn them on (and they cost extra) |

The actual reads and writes in the data lake are **data events**. Without
them, CloudTrail records that someone obtained Access Grants credentials
(`GetDataAccess`), but not which files they read, wrote or deleted. That's
step 1 of the chain in the queries (`SQL_QUERIES.md`), the S3 event with the
`access-grants-<uuid>` session, so it would have nothing to work with.

## Where to turn them on

**Storage trail:** data events, limited to the data lake bucket. In the
console: CloudTrail → Trails → *your trail* → **Data events** → Edit. Choose
data event type **S3**, then add a selector `resources.ARN` **starts with**
`arn:aws:s3:::<data-lake-bucket>/`. Keep the trailing `/`: the ARNs of objects
in the bucket start with it. Script `08_storage_cloudtrail.sh` does this from
the CLI.

The same trail must also log **management events**: `GetDataAccess` and Access
Grants' `AssumeRole` are management events, and the queries need them too.
Only the Storage account's trail is needed; Feeder's logs aren't used.

## What's on the bucket

In the S3 console, the bucket's **Properties** tab has an **"AWS CloudTrail
data events"** section. That's only a shortcut that sends you to CloudTrail;
it isn't a separate switch.

Don't confuse it with **Server access logging** on the same tab. That's a
different, older log in a different format, which the Glue tables and queries
don't use. You don't need it for this setup.

## Keep cost and volume down

Limit data events to the data lake bucket, as script `08` does. Don't log all
buckets. In particular, never log the bucket where the trail writes its own
logs: each log file it writes would itself be logged.
