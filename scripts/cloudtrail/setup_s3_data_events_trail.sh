#!/usr/bin/env bash
#
# Set up a CloudTrail trail that logs S3 data events for one bucket, and a Glue
# database + table to query those logs with Athena.
#
# What it does (AWS CLI only):
#   1. Creates the log bucket (public access blocked, SSE-S3, bucket owner enforced)
#      and a bucket policy that lets only this trail write to it.
#   2. Creates (or updates) the trail, with log file validation, and an advanced
#      event selector: S3 data events for objects in the monitored bucket only.
#   3. Starts logging.
#   4. Creates the Glue database (if missing) and a CloudTrail table with
#      partition projection on the date, so Athena can query it right away.
#
# Usage:
#   ./setup_s3_data_events_trail.sh \
#       --source-bucket my-data-bucket \
#       --log-bucket my-cloudtrail-logs-bucket \
#       --database cloudtrail_db \
#       --table s3_data_events \
#       [--trail-name s3-data-events-my-data-bucket] [--region eu-west-1] [--dry-run]
#
# Requirements: AWS CLI v2, credentials with cloudtrail:*, s3:* on both buckets
# and glue:* on the database/table.

set -euo pipefail

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log()   { printf '\n==> %s\n' "$*"; }
die()   { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SOURCE_BUCKET="" LOG_BUCKET="" DATABASE="" TABLE="" TRAIL_NAME="" REGION="" DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-bucket) SOURCE_BUCKET="$2"; shift 2 ;;
    --log-bucket)    LOG_BUCKET="$2";    shift 2 ;;
    --database)      DATABASE="$2";      shift 2 ;;
    --table)         TABLE="$2";         shift 2 ;;
    --trail-name)    TRAIL_NAME="$2";    shift 2 ;;
    --region)        REGION="$2";        shift 2 ;;
    --dry-run)       DRY_RUN=true;       shift ;;
    -h|--help)       usage 0 ;;
    *)               printf 'Unknown option: %s\n\n' "$1" >&2; usage 1 ;;
  esac
done

[[ -n "$SOURCE_BUCKET" && -n "$LOG_BUCKET" && -n "$DATABASE" && -n "$TABLE" ]] \
  || { printf 'Missing required option.\n\n' >&2; usage 1; }
[[ "$SOURCE_BUCKET" != "$LOG_BUCKET" ]] \
  || die "The log bucket must be different from the monitored bucket (otherwise log writes create new data events)."
[[ "$DATABASE" =~ ^[a-z0-9_]+$ && "$TABLE" =~ ^[a-z0-9_]+$ ]] \
  || die "Database and table names must be lowercase letters, digits and underscores (Athena rule)."
command -v aws >/dev/null || die "AWS CLI not found."

TRAIL_NAME="${TRAIL_NAME:-s3-data-events-${SOURCE_BUCKET}}"
TRAIL_NAME="${TRAIL_NAME:0:128}"

# Runs mutating commands, or prints them with --dry-run.
run() {
  if $DRY_RUN; then printf '[dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Context -----------------------------------------------------------------

log "Checking credentials and the monitored bucket"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
PARTITION="$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)"

aws s3api head-bucket --bucket "$SOURCE_BUCKET" >/dev/null 2>&1 \
  || die "Monitored bucket '$SOURCE_BUCKET' not found or not accessible."

if [[ -z "$REGION" ]]; then
  REGION="$(aws s3api get-bucket-location --bucket "$SOURCE_BUCKET" --query LocationConstraint --output text)"
  [[ "$REGION" == "None" || "$REGION" == "null" || -z "$REGION" ]] && REGION="us-east-1"
  [[ "$REGION" == "EU" ]] && REGION="eu-west-1"
fi
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

TRAIL_ARN="arn:${PARTITION}:cloudtrail:${REGION}:${ACCOUNT_ID}:trail/${TRAIL_NAME}"
LOG_PREFIX="AWSLogs/${ACCOUNT_ID}/CloudTrail/${REGION}"
POLICY_SID_PREFIX="CloudTrailWrite-${TRAIL_NAME}"

printf 'Account:        %s\nRegion:         %s\nMonitored:      s3://%s\nLog bucket:     s3://%s\nTrail:          %s\nGlue table:     %s.%s\n' \
  "$ACCOUNT_ID" "$REGION" "$SOURCE_BUCKET" "$LOG_BUCKET" "$TRAIL_NAME" "$DATABASE" "$TABLE"

# --- 1. Log bucket -------------------------------------------------------------

log "1/4 Log bucket s3://$LOG_BUCKET"
if aws s3api head-bucket --bucket "$LOG_BUCKET" >/dev/null 2>&1; then
  echo "Bucket already exists in this account: keeping it."
  EXISTING_POLICY="$(aws s3api get-bucket-policy --bucket "$LOG_BUCKET" --query Policy --output text 2>/dev/null || true)"
  if [[ -n "$EXISTING_POLICY" && "$EXISTING_POLICY" != *"$POLICY_SID_PREFIX"* ]]; then
    die "Bucket '$LOG_BUCKET' already has a bucket policy not created by this script. Not overwriting it. Use a new bucket name, or add the CloudTrail statements manually."
  fi
else
  if [[ "$REGION" == "us-east-1" ]]; then
    run aws s3api create-bucket --bucket "$LOG_BUCKET"
  else
    run aws s3api create-bucket --bucket "$LOG_BUCKET" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
  $DRY_RUN || aws s3api wait bucket-exists --bucket "$LOG_BUCKET"
fi

run aws s3api put-public-access-block --bucket "$LOG_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
run aws s3api put-bucket-ownership-controls --bucket "$LOG_BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
run aws s3api put-bucket-encryption --bucket "$LOG_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

cat > "$WORKDIR/bucket-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "${POLICY_SID_PREFIX}-AclCheck",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:${PARTITION}:s3:::${LOG_BUCKET}",
      "Condition": { "StringEquals": { "aws:SourceArn": "${TRAIL_ARN}" } }
    },
    {
      "Sid": "${POLICY_SID_PREFIX}-Write",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:${PARTITION}:s3:::${LOG_BUCKET}/AWSLogs/${ACCOUNT_ID}/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control",
          "aws:SourceArn": "${TRAIL_ARN}"
        }
      }
    },
    {
      "Sid": "${POLICY_SID_PREFIX}-DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:${PARTITION}:s3:::${LOG_BUCKET}", "arn:${PARTITION}:s3:::${LOG_BUCKET}/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
EOF
run aws s3api put-bucket-policy --bucket "$LOG_BUCKET" --policy "file://$WORKDIR/bucket-policy.json"

# --- 2. Trail and data event selector ---------------------------------------------

log "2/4 Trail $TRAIL_NAME"
if aws cloudtrail get-trail --name "$TRAIL_NAME" >/dev/null 2>&1; then
  echo "Trail exists: updating it."
  run aws cloudtrail update-trail --name "$TRAIL_NAME" \
    --s3-bucket-name "$LOG_BUCKET" --enable-log-file-validation --no-is-multi-region-trail
else
  run aws cloudtrail create-trail --name "$TRAIL_NAME" \
    --s3-bucket-name "$LOG_BUCKET" --enable-log-file-validation --no-is-multi-region-trail \
    --tags-list "Key=MonitoredBucket,Value=${SOURCE_BUCKET}"
fi

# Data events only (no management events), for every object in the monitored bucket.
# To log only writes, add: {"Field":"readOnly","Equals":["false"]}
cat > "$WORKDIR/selectors.json" <<EOF
[
  {
    "Name": "S3 data events for ${SOURCE_BUCKET}",
    "FieldSelectors": [
      { "Field": "eventCategory", "Equals": ["Data"] },
      { "Field": "resources.type", "Equals": ["AWS::S3::Object"] },
      { "Field": "resources.ARN", "StartsWith": ["arn:${PARTITION}:s3:::${SOURCE_BUCKET}/"] }
    ]
  }
]
EOF
run aws cloudtrail put-event-selectors --trail-name "$TRAIL_NAME" \
  --advanced-event-selectors "file://$WORKDIR/selectors.json"

log "3/4 Start logging"
run aws cloudtrail start-logging --name "$TRAIL_NAME"

# --- 3. Glue database and table -------------------------------------------------------

log "4/4 Glue database $DATABASE and table $TABLE"
if aws glue get-database --name "$DATABASE" >/dev/null 2>&1; then
  echo "Database exists: keeping it."
else
  run aws glue create-database --database-input \
    "{\"Name\":\"${DATABASE}\",\"Description\":\"CloudTrail logs\"}"
fi

TODAY="$(date -u +%Y/%m/%d)"
LOCATION="s3://${LOG_BUCKET}/${LOG_PREFIX}/"

# Standard CloudTrail schema (as used by Athena), partitioned by date with
# partition projection: no crawler or MSCK REPAIR needed.
cat > "$WORKDIR/table.json" <<EOF
{
  "Name": "${TABLE}",
  "Description": "CloudTrail S3 data events for ${SOURCE_BUCKET} (trail ${TRAIL_NAME})",
  "TableType": "EXTERNAL_TABLE",
  "Parameters": {
    "EXTERNAL": "TRUE",
    "classification": "cloudtrail",
    "projection.enabled": "true",
    "projection.timestamp.type": "date",
    "projection.timestamp.format": "yyyy/MM/dd",
    "projection.timestamp.range": "${TODAY},NOW",
    "projection.timestamp.interval": "1",
    "projection.timestamp.interval.unit": "DAYS",
    "storage.location.template": "${LOCATION}\${timestamp}"
  },
  "PartitionKeys": [ { "Name": "timestamp", "Type": "string" } ],
  "StorageDescriptor": {
    "Location": "${LOCATION}",
    "InputFormat": "com.amazon.emr.cloudtrail.CloudTrailInputFormat",
    "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
    "SerdeInfo": { "SerializationLibrary": "org.apache.hive.hcatalog.data.JsonSerDe" },
    "Columns": [
      { "Name": "eventversion", "Type": "string" },
      { "Name": "useridentity", "Type": "struct<type:string,principalid:string,arn:string,accountid:string,invokedby:string,accesskeyid:string,username:string,onbehalfof:struct<userid:string,identitystorearn:string>,sessioncontext:struct<attributes:struct<mfaauthenticated:string,creationdate:string>,sessionissuer:struct<type:string,principalid:string,arn:string,accountid:string,username:string>,ec2roledelivery:string,webidfederationdata:struct<federatedprovider:string,attributes:map<string,string>>>>" },
      { "Name": "eventtime", "Type": "string" },
      { "Name": "eventsource", "Type": "string" },
      { "Name": "eventname", "Type": "string" },
      { "Name": "awsregion", "Type": "string" },
      { "Name": "sourceipaddress", "Type": "string" },
      { "Name": "useragent", "Type": "string" },
      { "Name": "errorcode", "Type": "string" },
      { "Name": "errormessage", "Type": "string" },
      { "Name": "requestparameters", "Type": "string" },
      { "Name": "responseelements", "Type": "string" },
      { "Name": "additionaleventdata", "Type": "string" },
      { "Name": "requestid", "Type": "string" },
      { "Name": "eventid", "Type": "string" },
      { "Name": "readonly", "Type": "string" },
      { "Name": "resources", "Type": "array<struct<arn:string,accountid:string,type:string>>" },
      { "Name": "eventtype", "Type": "string" },
      { "Name": "apiversion", "Type": "string" },
      { "Name": "recipientaccountid", "Type": "string" },
      { "Name": "serviceeventdetails", "Type": "string" },
      { "Name": "sharedeventid", "Type": "string" },
      { "Name": "vpcendpointid", "Type": "string" },
      { "Name": "vpcendpointaccountid", "Type": "string" },
      { "Name": "eventcategory", "Type": "string" },
      { "Name": "addendum", "Type": "struct<reason:string,updatedfields:string,originalrequestid:string,originaleventid:string>" },
      { "Name": "sessioncredentialfromconsole", "Type": "string" },
      { "Name": "edgedevicedetails", "Type": "string" },
      { "Name": "tlsdetails", "Type": "struct<tlsversion:string,ciphersuite:string,clientprovidedhostheader:string>" }
    ]
  }
}
EOF

if aws glue get-table --database-name "$DATABASE" --name "$TABLE" >/dev/null 2>&1; then
  echo "Table exists: updating it."
  run aws glue update-table --database-name "$DATABASE" --table-input "file://$WORKDIR/table.json"
else
  run aws glue create-table --database-name "$DATABASE" --table-input "file://$WORKDIR/table.json"
fi

# --- Done -----------------------------------------------------------------------------

log "Done"
cat <<EOF
Logs are delivered to ${LOCATION}YYYY/MM/DD/ about 5 minutes after activity.

Example Athena query:
  SELECT eventtime, eventname, useridentity.arn, sourceipaddress,
         json_extract_scalar(requestparameters, '$.key') AS object_key
  FROM ${DATABASE}.${TABLE}
  WHERE timestamp >= '${TODAY}'
  ORDER BY eventtime DESC
  LIMIT 100;

Note: S3 data events are billed per event. Stop with:
  aws cloudtrail stop-logging --name ${TRAIL_NAME} --region ${REGION}
EOF
