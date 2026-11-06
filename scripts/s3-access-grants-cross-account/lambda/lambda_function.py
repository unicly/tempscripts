"""
Lambda (account B) that uses S3 Access Grants in account A to:
  1. list the objects under a prefix,
  2. create a test file under that prefix,
  3. delete that file.

The function's own role has no S3 permissions. It calls s3:GetDataAccess on
the Access Grants instance in account A and uses the temporary credentials
that Access Grants returns.

Environment variables:
  ACCESS_GRANTS_ACCOUNT_ID  account A (owner of the Access Grants instance)
  BUCKET                    bucket in account A
  PREFIX                    prefix covered by the grant, e.g. "data/" ("" for the whole bucket)
  DURATION_SECONDS          optional, lifetime of the temporary credentials (900-43200, default 900)
"""
import json
import os
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

ACCOUNT_ID = os.environ["ACCESS_GRANTS_ACCOUNT_ID"]
BUCKET = os.environ["BUCKET"]
PREFIX = os.environ.get("PREFIX", "")
DURATION_SECONDS = int(os.environ.get("DURATION_SECONDS", "900"))

s3control = boto3.client("s3control")


def get_grant_credentials():
    """Ask S3 Access Grants (account A) for temporary READWRITE credentials on the prefix."""
    response = s3control.get_data_access(
        AccountId=ACCOUNT_ID,
        Target=f"s3://{BUCKET}/{PREFIX}*",
        Permission="READWRITE",
        Privilege="Default",  # credentials scoped to the matched grant
        DurationSeconds=DURATION_SECONDS,
    )
    print(f"Matched grant target: {response['MatchedGrantTarget']}")
    return response["Credentials"]


def s3_client_from(credentials):
    return boto3.client(
        "s3",
        aws_access_key_id=credentials["AccessKeyId"],
        aws_secret_access_key=credentials["SecretAccessKey"],
        aws_session_token=credentials["SessionToken"],
    )


def list_objects(s3, max_keys=100):
    keys = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=PREFIX, PaginationConfig={"MaxItems": max_keys}):
        keys.extend(obj["Key"] for obj in page.get("Contents", []))
    return keys


def lambda_handler(event, context):
    try:
        s3 = s3_client_from(get_grant_credentials())

        # 1. List
        keys = list_objects(s3)
        print(f"{len(keys)} object(s) under s3://{BUCKET}/{PREFIX}: {keys[:20]}")

        # 2. Create a test file
        test_key = f"{PREFIX}access-grants-test-{uuid.uuid4().hex}.txt"
        body = f"Written by Lambda through S3 Access Grants at {datetime.now(timezone.utc).isoformat()}\n"
        s3.put_object(Bucket=BUCKET, Key=test_key, Body=body.encode())
        print(f"Created s3://{BUCKET}/{test_key}")

        # 3. Delete it
        s3.delete_object(Bucket=BUCKET, Key=test_key)
        print(f"Deleted s3://{BUCKET}/{test_key}")

        return {
            "statusCode": 200,
            "body": json.dumps({
                "listed": len(keys),
                "sample": keys[:20],
                "created_and_deleted": test_key,
            }),
        }
    except ClientError as e:
        error = e.response.get("Error", {})
        print(f"{e.operation_name} failed: {error.get('Code')}: {error.get('Message')}")
        if e.operation_name == "GetDataAccess":
            print("Check: grant for this role in account A, Access Grants resource policy for this account, "
                  "s3:GetDataAccess in this role's policy, same region as the Access Grants instance.")
        raise
