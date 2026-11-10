"""
DataLakePocObjects Lambda
-------------------------
Lists, creates or deletes objects in the data lake bucket on the
Storage account. Access chain: assume ASSUME_ROLE_ARN (the Access Grants
grantee — a Storage role or a Feeder role), then call S3 Access Grants on the
Storage account with those credentials for scoped credentials.

Event:
  {"action": "list"}
  {"action": "create"}                 # key optional, generated if absent
  {"action": "create", "key": "a.txt", "body": "hello"}
  {"action": "delete", "key": "a.txt"}
  Add "no_source_identity": true to skip SourceIdentity (testing).

Environment variables:
  BUCKET_NAME         Name of the target S3 bucket on the Storage account.
  STORAGE_ACCOUNT_ID  AWS account ID of the Storage account.
  ASSUME_ROLE_ARN     ARN of the grantee role to assume.
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET_NAME        = os.environ["BUCKET_NAME"]
STORAGE_ACCOUNT_ID = os.environ["STORAGE_ACCOUNT_ID"]
ASSUME_ROLE_ARN    = os.environ["ASSUME_ROLE_ARN"]


def scoped_s3_client(target, permission, set_source_identity=True):
    # Step 1: assume the grantee role.
    # SourceIdentity = this Lambda's Feeder role name; STS keeps it on the
    # chained session so it can show up in Storage's CloudTrail.
    sts = boto3.client("sts")
    kwargs = {
        "RoleArn":         ASSUME_ROLE_ARN,
        "RoleSessionName": os.environ["AWS_LAMBDA_FUNCTION_NAME"],
    }
    if set_source_identity:
        kwargs["SourceIdentity"] = sts.get_caller_identity()["Arn"].split("/")[1]
    assumed = sts.assume_role(**kwargs)
    storage_creds = assumed["Credentials"]

    # Step 2: obtain scoped credentials from Storage's S3 Access Grants.
    s3control = boto3.client(
        "s3control",
        aws_access_key_id     = storage_creds["AccessKeyId"],
        aws_secret_access_key = storage_creds["SecretAccessKey"],
        aws_session_token     = storage_creds["SessionToken"],
    )
    scoped_creds = s3control.get_data_access(
        AccountId  = STORAGE_ACCOUNT_ID,
        Target     = target,
        Permission = permission,
    )["Credentials"]

    # Step 3: S3 client using the scoped credentials.
    return boto3.client(
        "s3",
        aws_access_key_id     = scoped_creds["AccessKeyId"],
        aws_secret_access_key = scoped_creds["SecretAccessKey"],
        aws_session_token     = scoped_creds["SessionToken"],
    )


def lambda_handler(event, context):
    event  = event or {}
    action = event.get("action", "list")
    si     = not event.get("no_source_identity", False)

    try:
        if action == "list":
            s3 = scoped_s3_client(f"s3://{BUCKET_NAME}/*", "READ", si)
            files = []
            for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET_NAME):
                files.extend(obj["Key"] for obj in page.get("Contents", []))
            result = {"status": "success", "action": action, "files": files, "count": len(files)}

        elif action == "create":
            timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
            key = event.get("key") or f"upload-{timestamp}-{uuid.uuid4().hex[:8]}.txt"
            s3 = scoped_s3_client(f"s3://{BUCKET_NAME}/{key}", "WRITE", si)
            s3.put_object(
                Bucket      = BUCKET_NAME,
                Key         = key,
                Body        = event.get("body", "").encode(),
                ContentType = "text/plain",
            )
            result = {"status": "success", "action": action, "key": key}

        elif action == "delete":
            key = event["key"]
            s3 = scoped_s3_client(f"s3://{BUCKET_NAME}/{key}", "WRITE", si)
            s3.delete_object(Bucket=BUCKET_NAME, Key=key)
            result = {"status": "success", "action": action, "key": key}

        else:
            result = {"status": "error", "message": f"Unknown action '{action}' (use list, create or delete)"}

    except ClientError as e:
        result = {
            "status":     "error",
            "action":     action,
            "operation":  e.operation_name,   # AssumeRole / GetDataAccess / S3 call
            "error_code": e.response["Error"]["Code"],
            "message":    e.response["Error"]["Message"],
        }

    logger.info(json.dumps(result))
    return result
