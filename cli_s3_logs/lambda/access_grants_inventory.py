"""
AccessGrantsInventory Lambda
----------------------------
Snapshots all S3 Access Grants (grant ID -> grantee) to S3 as JSON lines,
one file per run: s3://<BUCKET>/<PREFIX><timestamp>.json

Environment variables:
  ACCOUNT_ID  Account that owns the Access Grants instance.
  BUCKET      Inventory bucket.
  PREFIX      Key prefix, e.g. "access-grants/".
"""

import json
import os
from datetime import datetime, timezone

import boto3

ACCOUNT_ID = os.environ["ACCOUNT_ID"]
BUCKET     = os.environ["BUCKET"]
PREFIX     = os.environ.get("PREFIX", "access-grants/")


def lambda_handler(event, context):
    s3control = boto3.client("s3control")
    now = datetime.now(timezone.utc)
    lines, token = [], None
    while True:
        kwargs = {"AccountId": ACCOUNT_ID, "MaxResults": 1000}
        if token:
            kwargs["NextToken"] = token
        resp = s3control.list_access_grants(**kwargs)
        for g in resp.get("AccessGrantsList", []):
            lines.append(json.dumps({
                "grant_id":           g["AccessGrantId"],
                "grant_arn":          g["AccessGrantArn"],
                "grantee_type":       g["Grantee"]["GranteeType"],
                "grantee_identifier": g["Grantee"]["GranteeIdentifier"],
                "permission":         g["Permission"],
                "grant_scope":        g.get("GrantScope"),
                "location_id":        g.get("AccessGrantsLocationId"),
                "created_at":         g["CreatedAt"].isoformat(),
                "exported_at":        now.isoformat(),
            }))
        token = resp.get("NextToken")
        if not token:
            break

    key = f"{PREFIX}{now.strftime('%Y%m%dT%H%M%SZ')}.json"
    boto3.client("s3").put_object(Bucket=BUCKET, Key=key,
                                  Body="\n".join(lines).encode(),
                                  ContentType="application/json")
    return {"grants": len(lines), "key": key}
