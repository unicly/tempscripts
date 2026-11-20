# Manual teardown — CORE and STORAGE accounts

Commands that delete everything created with
[manual_deployment.md](manual_deployment.md), roughly in reverse order.

> ⚠️ **Permanent.** This deletes the CloudTrail logs of all STORAGE accounts,
> the grants history CSVs and the Athena query history. Nothing can be restored
> afterwards. Back up what you want to keep first (step 1).
>
> The CloudTrail log bucket has **Object Lock**: in `COMPLIANCE` mode it can't be
> deleted until its newest log is 365 days old (step 5.5).

**Order:**

| Step | Account | Why here |
|---|---|---|
| 1 | CORE | back up first |
| 2 | CORE | **alerts off first**: otherwise deleting the trails sends "trail changed" emails, and two hours later "no logs" alarms |
| 3 | each STORAGE | trail, forwarding, RAM share, inventory read role |
| 4 | each STORAGE, **optional** | Access Grants and the data lake bucket |
| 5 | CORE | Lambdas, Glue, Athena, event bus permissions, SNS, IAM, buckets |
| 6 | all | check |

**Kept by default:** the data lake buckets, their data, and the STORAGE
accounts' Access Grants (instance, location, grants, location role). Step 4
removes them, but only run it if nothing else uses them.

---

## 0. Variables

Run everything in **bash**. Use the same values as the deployment (its step 0):

```bash
export REGION="eu-west-1"
export CORE_PROFILE="core"
export CORE_ACCOUNT_ID="111111111111"             # <- change
STORAGE_ACCOUNTS=("222222222222" "333333333333")  # <- change

export LOG_BUCKET="cloudtrail-logs-datalake-${CORE_ACCOUNT_ID}"
export ATHENA_RESULTS_BUCKET="athena-query-results-datalake-${CORE_ACCOUNT_ID}"
export INVENTORY_BUCKET="access-grants-inventory-${CORE_ACCOUNT_ID}"
export GRANTS_PREFIX="access-grants-history/"

export STORAGE_TRAIL="StorageDataLakeTrail"
export GLUE_DATABASE="cloudtrail_logs"
export ATHENA_WORKGROUP="cloudtrail-correlation"

CORE=(--region "$REGION" --profile "$CORE_PROFILE")
```

Helper used in steps 3–5. A role can only be deleted once its inline policies
are deleted and its managed policies detached:

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
```

A command for something that no longer exists fails with a "not found" error
(`ResourceNotFoundException`, `NoSuchEntity`, `NoSuchBucket`, …). That's fine:
continue with the next one.

---

## 1. CORE — back up (optional)

The grants history, one CSV per STORAGE account:

```bash
aws s3 cp "s3://${INVENTORY_BUCKET}/${GRANTS_PREFIX}" ./grants_history_backup/ --recursive "${CORE[@]}"
```

The Athena saved queries, if you saved any in the workgroup (name and SQL of
each):

```bash
for id in $(aws athena list-named-queries --work-group "$ATHENA_WORKGROUP" "${CORE[@]}" \
              --query 'NamedQueryIds[]' --output text); do
  aws athena get-named-query --named-query-id "$id" "${CORE[@]}" --query 'NamedQuery.{name:Name, sql:QueryString}'
done > athena_saved_queries_backup.json
```

The CloudTrail logs themselves (can be large):

```bash
aws s3 sync "s3://${LOG_BUCKET}/AWSLogs/" ./cloudtrail_logs_backup/ "${CORE[@]}"
```

---

## 2. CORE — alerts off

### 2.1 CloudWatch alarms

```bash
ALARMS=(AccessGrantsInventoryErrors)
for a in "${STORAGE_ACCOUNTS[@]}"; do ALARMS+=("CloudTrailLogsMissing-${a}"); done
aws cloudwatch delete-alarms --alarm-names "${ALARMS[@]}" "${CORE[@]}"
```

The metric `DataLake/CloudTrailDelivery` can't be deleted. Once the Lambda
stops publishing, it disappears from the console after two weeks; you aren't
charged for it after that.

### 2.2 EventBridge rules

A rule can only be deleted once its targets are removed. The target IDs are
the ones from deployment step 8.

```bash
for r in AccessGrantsInventoryOnChange:inventory AccessGrantsInventoryDaily:inventory \
         LogDeliveryMonitorSchedule:monitor TrailChangeAlert:email; do
  aws events remove-targets --rule "${r%%:*}" --ids "${r##*:}" "${CORE[@]}"
  aws events delete-rule --name "${r%%:*}" "${CORE[@]}"
done
```

---

## 3. STORAGE — repeat for every STORAGE account

Set the values of **the account you're removing**:

```bash
export STORAGE_PROFILE="storage-a"               # <- CLI profile of this STORAGE account
export STORAGE_ACCOUNT_ID="222222222222"         # <- its account ID
ST=(--region "$REGION" --profile "$STORAGE_PROFILE")
```

### 3.1 CloudTrail trail

Deleting the trail stops its delivery to CORE. The logs already written stay
in CORE until step 5.5.

```bash
aws cloudtrail delete-trail --name "$STORAGE_TRAIL" "${ST[@]}"
```

### 3.2 EventBridge forwarding to CORE

```bash
aws events remove-targets --rule ForwardToCore --ids core "${ST[@]}"
aws events delete-rule --name ForwardToCore "${ST[@]}"
delete_role "$STORAGE_PROFILE" EventBridgeForwardToCoreRole
```

### 3.3 RAM share with CORE

Deleting the share removes it in CORE as well: CORE's consumers can no longer
get credentials from this account's Access Grants.

```bash
SHARE_ARN=$(aws ram get-resource-shares --resource-owner SELF --name S3AccessGrantsCoreShare \
              --resource-share-status ACTIVE "${ST[@]}" --query 'resourceShares[0].resourceShareArn' --output text)
aws ram delete-resource-share --resource-share-arn "$SHARE_ARN" "${ST[@]}"
```

### 3.4 Inventory read role

```bash
delete_role "$STORAGE_PROFILE" AccessGrantsInventoryReadRole
```

**Next STORAGE account:** go back to the start of step 3 (or run step 4 first
for this account).

---

## 4. STORAGE — Access Grants and data lake bucket (optional)

> ⚠️ Only if **nothing else** uses them. Deleting the Access Grants instance
> cuts off every consumer of the data lake; deleting the bucket deletes the data.

Run it per STORAGE account, with the values from step 3 and the bucket name
from the deployment:

```bash
export DATALAKE_BUCKET="datalake-${STORAGE_ACCOUNT_ID}"   # <- as in deployment step 5
```

### 4.1 Grants, locations, instance

The instance can only be deleted once it has no grants and no locations, and
a location once it has no grants. The RAM share must be gone (3.3).

```bash
for g in $(aws s3control list-access-grants --account-id "$STORAGE_ACCOUNT_ID" "${ST[@]}" \
             --query 'AccessGrantsList[].AccessGrantId' --output text); do
  aws s3control delete-access-grant --account-id "$STORAGE_ACCOUNT_ID" --access-grant-id "$g" "${ST[@]}"
done
for l in $(aws s3control list-access-grants-locations --account-id "$STORAGE_ACCOUNT_ID" "${ST[@]}" \
             --query 'AccessGrantsLocationsList[].AccessGrantsLocationId' --output text); do
  aws s3control delete-access-grants-location --account-id "$STORAGE_ACCOUNT_ID" --access-grants-location-id "$l" "${ST[@]}"
done
aws s3control delete-access-grants-instance --account-id "$STORAGE_ACCOUNT_ID" "${ST[@]}"
```

(Each list returns at most 1000 entries per call; with more grants, run the
first loop again until it finds none.)

The location role, now that no location uses it:

```bash
delete_role "$STORAGE_PROFILE" S3AccessGrantsLocationRole
```

### 4.2 Data lake bucket

The bucket policy denies everything except Access Grants and
`STORAGE_ADMIN_ARN`: run this with a profile **for that admin role or user**.
With any other identity, even an administrator, `AccessDenied` comes back; then
only the account's root user can remove the policy.

```bash
aws s3api delete-bucket-policy --bucket "$DATALAKE_BUCKET" "${ST[@]}"
aws s3 rb "s3://${DATALAKE_BUCKET}" --force "${ST[@]}"
```

`--force` deletes all objects first. If the bucket has versioning enabled, it
only adds delete markers and `rb` fails; then use `empty_locked_bucket` from
step 5.5 (it works on any versioned bucket, with `ST` in place of `CORE`).

---

## 5. CORE — the rest

### 5.1 Lambda functions

Deleting a function also removes its EventBridge permissions and its
concurrency setting. Their log groups stay and are deleted separately.

```bash
for f in AccessGrantsInventory LogDeliveryMonitor; do
  aws lambda delete-function --function-name "$f" "${CORE[@]}"
  aws logs delete-log-group --log-group-name "/aws/lambda/$f" "${CORE[@]}"
done
```

### 5.2 Glue and Athena

Dropping the tables only removes their definitions. `--recursive-delete-option`
also deletes the workgroup's saved queries and query history. The data in S3
stays until 5.5.

```bash
for t in storage_trail access_grants_history; do
  aws glue delete-table --database-name "$GLUE_DATABASE" --name "$t" "${CORE[@]}"
done
aws glue delete-database --name "$GLUE_DATABASE" "${CORE[@]}"
aws athena delete-work-group --work-group "$ATHENA_WORKGROUP" --recursive-delete-option "${CORE[@]}"
```

### 5.3 Event bus permissions and SNS topic

Deleting the topic also deletes its email subscription.

```bash
for a in "${STORAGE_ACCOUNTS[@]}"; do
  aws events remove-permission --event-bus-name default --statement-id "AllowStorage${a}" "${CORE[@]}"
done
aws sns delete-topic --topic-arn "arn:aws:sns:${REGION}:${CORE_ACCOUNT_ID}:DataLakeAlerts" "${CORE[@]}"
```

### 5.4 IAM: Lambda roles and consumer policy

A managed policy can only be deleted once it's detached from every role, user
and group, and its older versions are deleted (step 13 of the deployment
creates new versions).

```bash
delete_role "$CORE_PROFILE" AccessGrantsInventoryRole
delete_role "$CORE_PROFILE" LogDeliveryMonitorRole

POLICY_ARN="arn:aws:iam::${CORE_ACCOUNT_ID}:policy/DataLakeConsumerAccess"
for r in $(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" "${CORE[@]}" --query 'PolicyRoles[].RoleName' --output text); do
  aws iam detach-role-policy --role-name "$r" --policy-arn "$POLICY_ARN" "${CORE[@]}"
done
for u in $(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" "${CORE[@]}" --query 'PolicyUsers[].UserName' --output text); do
  aws iam detach-user-policy --user-name "$u" --policy-arn "$POLICY_ARN" "${CORE[@]}"
done
for g in $(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" "${CORE[@]}" --query 'PolicyGroups[].GroupName' --output text); do
  aws iam detach-group-policy --group-name "$g" --policy-arn "$POLICY_ARN" "${CORE[@]}"
done
for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" "${CORE[@]}" \
             --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
  aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v" "${CORE[@]}"
done
aws iam delete-policy --policy-arn "$POLICY_ARN" "${CORE[@]}"
```

The consumers themselves (the `DataLakeReader` role, users) aren't deleted:
they belong to CORE, not to this setup.

### 5.5 Buckets

The trails must be deleted first (step 3.1), or they keep writing new logs into
the log bucket while it is being emptied.

**Athena results and grants history:** `--force` deletes all objects first,
then the bucket.

```bash
aws s3 rb "s3://${ATHENA_RESULTS_BUCKET}" --force "${CORE[@]}"
aws s3 rb "s3://${INVENTORY_BUCKET}"      --force "${CORE[@]}"
```

**CloudTrail log bucket (Object Lock).** `aws s3 rb --force` **doesn't work**
here:

- the bucket is versioned (Object Lock turns versioning on), and `--force`
  only issues plain deletes, which add delete markers instead of deleting;
- the bucket policy denies those plain deletes (`DenyDeleteMarkers`);
- every log version is locked for 365 days after it was written.

What's possible depends on the lock mode. Check it:

```bash
aws s3api get-object-lock-configuration --bucket "$LOG_BUCKET" "${CORE[@]}" \
  --query 'ObjectLockConfiguration.Rule.DefaultRetention' --output text
```

| Mode | Can the bucket be deleted now? |
|---|---|
| `GOVERNANCE` | **Yes**, if you have the permission `s3:BypassGovernanceRetention`: delete every version with the bypass flag (below) |
| `COMPLIANCE` | **No.** Nobody can delete a log before its lock expires, not even the root user. The bucket can only be deleted once the **newest** log is 365 days old |

**`GOVERNANCE`: empty and delete the bucket.** Deleting specific versions isn't
denied by the bucket policy, and `--bypass-governance-retention` lifts the lock.
The function stops if S3 refuses a version (for example in `COMPLIANCE` mode,
or without the bypass permission) instead of retrying forever.

```bash
empty_locked_bucket() {   # empty_locked_bucket <bucket>   (uses the CORE profile)
  local batch err
  while :; do
    batch=$(aws s3api list-object-versions --bucket "$1" "${CORE[@]}" \
              --no-paginate --max-keys 1000 --output json \
              --query '{Objects: [Versions[].{Key: Key, VersionId: VersionId} || `[]`, DeleteMarkers[].{Key: Key, VersionId: VersionId} || `[]`][], Quiet: `true`}')
    grep -q '"VersionId"' <<<"$batch" || break
    err=$(aws s3api delete-objects --bucket "$1" "${CORE[@]}" \
            --bypass-governance-retention --delete "$batch" \
            --query 'Errors[0].[Code, Key, Message]' --output text)
    if [ "$err" != "None" ]; then
      echo "S3 refused to delete a version: $err" >&2
      return 1
    fi
  done
  aws s3api delete-bucket-policy --bucket "$1" "${CORE[@]}"
  aws s3api delete-bucket --bucket "$1" "${CORE[@]}"
}
empty_locked_bucket "$LOG_BUCKET"
```

Expect a long run: every STORAGE account adds a log file every few minutes,
and the function deletes 1000 versions per call.

**`COMPLIANCE`: wait, then delete.** With all trails deleted (step 3.1), no new
locked logs arrive. Find out when the newest log's lock ends:

```bash
KEY=$(aws s3api list-objects-v2 --bucket "$LOG_BUCKET" --prefix "AWSLogs/" "${CORE[@]}" \
        --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)
aws s3api get-object-retention --bucket "$LOG_BUCKET" --key "$KEY" "${CORE[@]}" \
  --query 'Retention.RetainUntilDate' --output text
```

Until that date:

- keep the bucket and its **lifecycle rule**: it deletes each log as soon as its
  lock has expired, so the bucket empties itself over the year;
- you pay for the storage of the logs that are still there.

After that date, run `empty_locked_bucket "$LOG_BUCKET"` (above) to remove
what's left and delete the bucket.

---

## 6. Check

Each command should now fail with a "not found" error, or return an empty list.

**CORE:**

```bash
aws cloudwatch describe-alarms --alarm-name-prefix CloudTrailLogsMissing "${CORE[@]}" --query 'MetricAlarms[].AlarmName'
aws events list-rules "${CORE[@]}" --query 'Rules[].Name' --output text | tr '\t' '\n' \
  | grep -E 'AccessGrantsInventory|LogDeliveryMonitor|TrailChangeAlert'
aws events describe-event-bus --name default "${CORE[@]}" --query Policy --output text | grep -o 'AllowStorage[0-9]*'
for f in AccessGrantsInventory LogDeliveryMonitor; do aws lambda get-function --function-name "$f" "${CORE[@]}"; done
aws glue get-database --name "$GLUE_DATABASE" "${CORE[@]}"
aws athena get-work-group --work-group "$ATHENA_WORKGROUP" "${CORE[@]}"
aws sns get-topic-attributes --topic-arn "arn:aws:sns:${REGION}:${CORE_ACCOUNT_ID}:DataLakeAlerts" "${CORE[@]}"
for r in AccessGrantsInventoryRole LogDeliveryMonitorRole; do aws iam get-role --role-name "$r" "${CORE[@]}" --query Role.Arn --output text; done
aws iam get-policy --policy-arn "arn:aws:iam::${CORE_ACCOUNT_ID}:policy/DataLakeConsumerAccess" "${CORE[@]}"
for b in "$LOG_BUCKET" "$ATHENA_RESULTS_BUCKET" "$INVENTORY_BUCKET"; do
  aws s3api head-bucket --bucket "$b" "${CORE[@]}" 2>/dev/null && echo "STILL EXISTS: $b"
done
aws ram get-resource-shares --resource-owner OTHER-ACCOUNTS --name S3AccessGrantsCoreShare \
  --resource-share-status ACTIVE "${CORE[@]}" --query 'resourceShares[].owningAccountId'
```

The grep and the head-bucket loop print nothing when everything is gone. The
log bucket still existing is expected in `COMPLIANCE` mode (step 5.5).

**Each STORAGE account** (with its `ST` from step 3):

```bash
aws cloudtrail get-trail --name "$STORAGE_TRAIL" "${ST[@]}"
aws events describe-rule --name ForwardToCore "${ST[@]}"
for r in EventBridgeForwardToCoreRole AccessGrantsInventoryReadRole; do
  aws iam get-role --role-name "$r" "${ST[@]}" --query Role.Arn --output text
done
aws ram get-resource-shares --resource-owner SELF --name S3AccessGrantsCoreShare \
  --resource-share-status ACTIVE "${ST[@]}" --query 'resourceShares[].name'
```

If you ran step 4, also: `aws s3control get-access-grants-instance --account-id
"$STORAGE_ACCOUNT_ID" "${ST[@]}"` and `aws s3api head-bucket --bucket
"$DATALAKE_BUCKET" "${ST[@]}"` should fail.

Finally, the JSON and Python files the deployment wrote to your working folder
can be deleted.
