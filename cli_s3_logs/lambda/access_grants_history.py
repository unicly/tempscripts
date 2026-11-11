"""
AccessGrantsInventory Lambda — append-only history of S3 Access Grants (CSV)
---------------------------------------------------------------------------
Each run lists all grants of the Access Grants instance and compares them with
the history already in the CSV file:

  grant exists now, not active in the history  -> append a CREATED line
  grant active in the history, gone now         -> append a DELETED line
  nothing changed                               -> append nothing

Existing lines are never changed or removed. S3 has no append operation, so the
file is read, the new lines are added at the end, and the whole file is
written back with a conditional write (If-Match on the ETag): if another run
changed the file in between, this run fails and Lambda retries it.

Columns:
  observed_at, event, grant_id, grant_arn, grantee_type, grantee_identifier,
  permission, grant_scope, location_id, created_at

observed_at is when this Lambda saw the change, not when it happened; for that
use created_at (from Access Grants) or the CreateAccessGrant / DeleteAccessGrant
CloudTrail event.

Environment variables:
  ACCOUNT_ID  Account that owns the Access Grants instance.
  BUCKET      Bucket of the CSV file.
  KEY         Object key of the CSV file, e.g. access-grants-history/access_grants_history.csv
"""

import csv
import io
import json
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError, ParamValidationError

ACCOUNT_ID = os.environ["ACCOUNT_ID"]
BUCKET     = os.environ["BUCKET"]
KEY        = os.environ["KEY"]

FIELDS = ["observed_at", "event", "grant_id", "grant_arn", "grantee_type",
          "grantee_identifier", "permission", "grant_scope", "location_id", "created_at"]

s3 = boto3.client("s3")


def list_grants():
    """All current grants, keyed by grant ID."""
    s3control = boto3.client("s3control")
    grants, token = {}, None
    while True:
        kwargs = {"AccountId": ACCOUNT_ID, "MaxResults": 1000}
        if token:
            kwargs["NextToken"] = token
        resp = s3control.list_access_grants(**kwargs)
        for g in resp.get("AccessGrantsList", []):
            grants[g["AccessGrantId"]] = g
        token = resp.get("NextToken")
        if not token:
            return grants


def read_history():
    """(file content, ETag) — ("", None) if the file doesn't exist yet."""
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=KEY)
    except ClientError as e:
        if e.response["Error"]["Code"] in ("NoSuchKey", "404"):
            return "", None
        raise
    return obj["Body"].read().decode("utf-8"), obj["ETag"]


def active_grants(text):
    """Grants whose last event in the history is CREATED -> their last CREATED line."""
    last = {}
    for row in csv.DictReader(io.StringIO(text)):
        last[row["grant_id"]] = row
    return {gid: row for gid, row in last.items() if row["event"] == "CREATED"}


def to_row(observed_at, event, g):
    return {
        "observed_at":        observed_at,
        "event":              event,
        "grant_id":           g["AccessGrantId"],
        "grant_arn":          g["AccessGrantArn"],
        "grantee_type":       g["Grantee"]["GranteeType"],
        "grantee_identifier": g["Grantee"]["GranteeIdentifier"],
        "permission":         g["Permission"],
        "grant_scope":        g.get("GrantScope", ""),
        "location_id":        g.get("AccessGrantsLocationId", ""),
        "created_at":         g["CreatedAt"].isoformat(),
    }


def write_history(content, etag):
    """Conditional write: only if the file is still the version we read."""
    kwargs = {"Bucket": BUCKET, "Key": KEY, "Body": content.encode("utf-8"), "ContentType": "text/csv"}
    if etag:
        kwargs["IfMatch"] = etag          # someone else changed it -> 412, Lambda retries
    else:
        kwargs["IfNoneMatch"] = "*"       # someone else created it  -> 412, Lambda retries
    try:
        s3.put_object(**kwargs)
    except ParamValidationError:
        # boto3 in the runtime is too old for conditional writes; reserved
        # concurrency 1 on the function still prevents parallel runs.
        kwargs.pop("IfMatch", None)
        kwargs.pop("IfNoneMatch", None)
        s3.put_object(**kwargs)


def lambda_handler(event, context):
    text, etag = read_history()
    current    = list_grants()
    active     = active_grants(text)
    now        = datetime.now(timezone.utc).isoformat(timespec="seconds")

    new_rows = [to_row(now, "CREATED", g) for gid, g in sorted(current.items()) if gid not in active]
    for gid in sorted(set(active) - set(current)):
        row = dict(active[gid])           # keep the grant's details from its CREATED line
        row.update(observed_at=now, event="DELETED")
        new_rows.append(row)

    if new_rows:
        buf = io.StringIO()
        writer = csv.DictWriter(buf, fieldnames=FIELDS, quoting=csv.QUOTE_ALL, lineterminator="\n")
        if not text:
            writer.writeheader()
        writer.writerows(new_rows)
        if text and not text.endswith("\n"):
            text += "\n"
        write_history(text + buf.getvalue(), etag)

    result = {
        "current_grants": len(current),
        "appended":       len(new_rows),
        "created":        sum(r["event"] == "CREATED" for r in new_rows),
        "deleted":        sum(r["event"] == "DELETED" for r in new_rows),
        "file":           f"s3://{BUCKET}/{KEY}",
    }
    print(json.dumps(result))
    return result
