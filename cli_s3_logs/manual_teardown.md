# Manual teardown

Commands that delete everything created with
[manual_deployment.md](manual_deployment.md), in reverse order.

> ⚠️ **Permanent.** This deletes the CloudTrail logs, the grants history CSV and
> the Athena saved queries and query history. Nothing can be restored
> afterwards. Back up what you want to keep first (step 1).

**Not deleted:** the data lake bucket and its data, the S3 Access Grants
instance, its locations and grants, and the RAM share. The deployment guide
doesn't create them, and other consumers may depend on them.

## 0. Variables

The same values you used for the deployment.

```bash
export REGION="eu-west-1"
export STORAGE_PROFILE="storage"                 # CLI profile of the Storage account
export STORAGE_ACCOUNT_ID="222222222222"         # <- change
export FEEDER_PROFILE="feeder"                   # CLI profile of the Feeder account
export FEEDER_ACCOUNT_ID="111111111111"          # <- change

export STORAGE_CT_BUCKET="cloudtrail-logs-datalake-${STORAGE_ACCOUNT_ID}"
export ATHENA_RESULTS_BUCKET="athena-query-results-datalake-${STORAGE_ACCOUNT_ID}"
export INVENTORY_BUCKET="access-grants-inventory-${STORAGE_ACCOUNT_ID}"
export GRANTS_CSV_KEY="access-grants-history/access_grants_history.csv"

export STORAGE_TRAIL="StorageDataLakeTrail"
export GLUE_DATABASE="cloudtrail_logs"
export ATHENA_WORKGROUP="cloudtrail-correlation"
```

A command for something that no longer exists fails with a "not found" error
(`ResourceNotFoundException`, `NoSuchEntity`, `NoSuchBucket`, …). That's fine:
continue with the next one.

---

## 1. Back up (optional)

The grants history CSV:

```bash
aws s3 cp "s3://${INVENTORY_BUCKET}/${GRANTS_CSV_KEY}" ./access_grants_history_backup.csv \
  --profile "$STORAGE_PROFILE"
```

The Athena saved queries (one JSON file with name and SQL of each):

```bash
for id in $(aws athena list-named-queries --work-group "$ATHENA_WORKGROUP" \
              --region "$REGION" --profile "$STORAGE_PROFILE" --query 'NamedQueryIds[]' --output text); do
  aws athena get-named-query --named-query-id "$id" --region "$REGION" --profile "$STORAGE_PROFILE" \
    --query 'NamedQuery.{name:Name, sql:QueryString}'
done > athena_saved_queries_backup.json
```

---

## 2. EventBridge rules (Storage)

A rule can only be deleted once its targets are removed.

```bash
for r in AccessGrantsInventoryOnChange AccessGrantsInventoryDaily; do
  aws events remove-targets --rule "$r" --ids inventory --region "$REGION" --profile "$STORAGE_PROFILE"
  aws events delete-rule --name "$r" --region "$REGION" --profile "$STORAGE_PROFILE"
done
```

If you created the daily run in **EventBridge Scheduler** (console) instead of
as a rule:

```bash
aws scheduler delete-schedule --name AccessGrantsInventoryDaily --region "$REGION" --profile "$STORAGE_PROFILE"
```

The Scheduler's execution role (created by the console, name starting with
`Amazon_EventBridge_Scheduler_LAMBDA_`) can then be deleted in IAM as well.

---

## 3. Lambda functions

Deleting a function also removes its permissions for EventBridge and its
concurrency setting.

```bash
aws lambda delete-function --function-name AccessGrantsInventory --region "$REGION" --profile "$STORAGE_PROFILE"
aws lambda delete-function --function-name DataLakePocObjects   --region "$REGION" --profile "$FEEDER_PROFILE"
```

Their **CloudWatch log groups** are created automatically on the first run and
stay after the function is deleted:

```bash
aws logs delete-log-group --log-group-name /aws/lambda/AccessGrantsInventory --region "$REGION" --profile "$STORAGE_PROFILE"
aws logs delete-log-group --log-group-name /aws/lambda/DataLakePocObjects   --region "$REGION" --profile "$FEEDER_PROFILE"
```

---

## 4. Glue tables and database (Storage)

Dropping the tables only removes their definitions; the data in S3 stays until
step 7.

```bash
for t in storage_datalake_trail access_grants_history; do
  aws glue delete-table --database-name "$GLUE_DATABASE" --name "$t" --region "$REGION" --profile "$STORAGE_PROFILE"
done
aws glue delete-database --name "$GLUE_DATABASE" --region "$REGION" --profile "$STORAGE_PROFILE"
```

---

## 5. Athena workgroup (Storage)

`--recursive-delete-option` also deletes the workgroup's **saved queries** and
query history; without it, deletion fails if the workgroup holds any. The
results in S3 stay until step 7.

```bash
aws athena delete-work-group --work-group "$ATHENA_WORKGROUP" --recursive-delete-option \
  --region "$REGION" --profile "$STORAGE_PROFILE"
```

---

## 6. CloudTrail trail (Storage)

Deleting the trail stops logging. The logs already written stay until step 7.

```bash
aws cloudtrail delete-trail --name "$STORAGE_TRAIL" --region "$REGION" --profile "$STORAGE_PROFILE"
```

---

## 7. Buckets (Storage)

A bucket must be empty before it can be deleted; `--force` deletes all objects
first, then the bucket.

```bash
aws s3 rb "s3://${STORAGE_CT_BUCKET}"     --force --profile "$STORAGE_PROFILE"
aws s3 rb "s3://${ATHENA_RESULTS_BUCKET}" --force --profile "$STORAGE_PROFILE"
aws s3 rb "s3://${INVENTORY_BUCKET}"      --force --profile "$STORAGE_PROFILE"
```

The trail must be deleted first (step 6), or it keeps writing new log files
into the bucket while it is being emptied.

**If versioning was turned on** for a bucket, `--force` only removes the current
versions and `rb` then fails with `BucketNotEmpty`. Delete all versions and
delete markers (1000 per call), then the bucket:

```bash
empty_versioned_bucket() {   # empty_versioned_bucket <bucket>
  local batch
  while :; do
    batch=$(aws s3api list-object-versions --bucket "$1" --profile "$STORAGE_PROFILE" \
              --no-paginate --max-keys 1000 --output json \
              --query '{Objects: [Versions[].{Key: Key, VersionId: VersionId} || `[]`, DeleteMarkers[].{Key: Key, VersionId: VersionId} || `[]`][], Quiet: `true`}')
    grep -q '"VersionId"' <<<"$batch" || break
    aws s3api delete-objects --bucket "$1" --profile "$STORAGE_PROFILE" --delete "$batch" >/dev/null
  done
  aws s3api delete-bucket --bucket "$1" --profile "$STORAGE_PROFILE"
}
empty_versioned_bucket "$STORAGE_CT_BUCKET"
```

---

## 8. IAM roles

A role can only be deleted once its inline policies are deleted and its managed
policies detached. Do this last: until the Lambdas are gone, they still use
these roles.

```bash
# delete_role <profile> <role>
delete_role() {
  local p
  for p in $(aws iam list-role-policies --role-name "$2" --profile "$1" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$2" --policy-name "$p" --profile "$1"
  done
  for p in $(aws iam list-attached-role-policies --role-name "$2" --profile "$1" \
               --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$2" --policy-arn "$p" --profile "$1"
  done
  aws iam delete-role --role-name "$2" --profile "$1"
}

delete_role "$STORAGE_PROFILE" AccessGrantsInventoryRole
delete_role "$FEEDER_PROFILE"  FeederAccessGrantsRole
delete_role "$FEEDER_PROFILE"  FeederDataLakeLambdaRole
```

**`S3AccessGrantsLocationRole`:** delete it only if **no Access Grants location
uses it** any more. As long as a location refers to it, deleting the role
breaks every grant on that location. Check first:

```bash
aws s3control list-access-grants-locations --account-id "$STORAGE_ACCOUNT_ID" \
  --region "$REGION" --profile "$STORAGE_PROFILE" \
  --query 'AccessGrantsLocationsList[].[LocationScope, IAMRoleArn]' --output table
```

If the role no longer appears there:

```bash
delete_role "$STORAGE_PROFILE" S3AccessGrantsLocationRole
```

---

## 9. Check

Each command should now fail with a "not found" error, or return an empty list.

```bash
S=(--region "$REGION" --profile "$STORAGE_PROFILE")
F=(--region "$REGION" --profile "$FEEDER_PROFILE")

aws events list-rules --name-prefix AccessGrantsInventory "${S[@]}" --query 'Rules[].Name'
aws lambda get-function --function-name AccessGrantsInventory "${S[@]}"
aws lambda get-function --function-name DataLakePocObjects "${F[@]}"
aws glue get-database --name "$GLUE_DATABASE" "${S[@]}"
aws athena get-work-group --work-group "$ATHENA_WORKGROUP" "${S[@]}"
aws cloudtrail get-trail --name "$STORAGE_TRAIL" "${S[@]}"
for b in "$STORAGE_CT_BUCKET" "$ATHENA_RESULTS_BUCKET" "$INVENTORY_BUCKET"; do
  aws s3api head-bucket --bucket "$b" --profile "$STORAGE_PROFILE" && echo "STILL EXISTS: $b"
done
for r in AccessGrantsInventoryRole S3AccessGrantsLocationRole; do
  aws iam get-role --role-name "$r" --profile "$STORAGE_PROFILE" --query Role.Arn --output text
done
for r in FeederAccessGrantsRole FeederDataLakeLambdaRole; do
  aws iam get-role --role-name "$r" --profile "$FEEDER_PROFILE" --query Role.Arn --output text
done
```

`S3AccessGrantsLocationRole` still existing is expected if you kept it in step 8.
