#!/usr/bin/env bash
# 09 — Feeder: Lambda DataLakePocObjects (list / create / delete in the data
# lake through Access Grants). Code: lambda/data_lake_poc_objects.py.
# Re-run to deploy code changes.
source "$(dirname "$0")/lib.sh"

deploy_lambda "$FEEDER_PROFILE" DataLakePocObjects \
  "arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederDataLakeLambdaRole" \
  "${LAMBDA_DIR}/data_lake_poc_objects.py" data_lake_poc_objects.lambda_handler 30 \
  "BUCKET_NAME=${DATALAKE_BUCKET},STORAGE_ACCOUNT_ID=${STORAGE_ACCOUNT_ID},ASSUME_ROLE_ARN=arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederAccessGrantsRole"

log "done: DataLakePocObjects (test with 13_test.sh)"
