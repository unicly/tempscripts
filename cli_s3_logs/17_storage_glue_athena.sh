#!/usr/bin/env bash
# 17 — Storage: Athena workgroup, Glue database and the three tables
#   storage_datalake_trail : Storage CloudTrail          (bucket from 04)
#   feeder_trail           : replicated Feeder CloudTrail (bucket from 05)
#   access_grants          : grants inventory snapshots   (bucket from 15)
# CloudTrail tables use partition projection (year/month/day) and declare
# useridentity.sessioncontext.sourceidentity (otherwise Athena can't read it).
source "$(dirname "$0")/lib.sh"

if aws athena get-work-group --work-group "$ATHENA_WORKGROUP" --region "$REGION" --profile "$STORAGE_PROFILE" >/dev/null 2>&1; then
  log "workgroup ${ATHENA_WORKGROUP} exists"
else
  log "creating workgroup ${ATHENA_WORKGROUP}"
  aws athena create-work-group --name "$ATHENA_WORKGROUP" --region "$REGION" --profile "$STORAGE_PROFILE" \
    --configuration "ResultConfiguration={OutputLocation=s3://${ATHENA_RESULTS_BUCKET}/,EncryptionConfiguration={EncryptionOption=SSE_S3}},EnforceWorkGroupConfiguration=true,PublishCloudWatchMetricsEnabled=true"
fi

if aws glue get-database --name "$GLUE_DATABASE" --region "$REGION" --profile "$STORAGE_PROFILE" >/dev/null 2>&1; then
  log "database ${GLUE_DATABASE} exists"
else
  log "creating database ${GLUE_DATABASE}"
  aws glue create-database --database-input "Name=${GLUE_DATABASE}" --region "$REGION" --profile "$STORAGE_PROFILE"
fi

# cloudtrail_ddl <table> <bucket> <account>
cloudtrail_ddl() {
cat > "ddl_$1.sql" <<EOF
CREATE EXTERNAL TABLE IF NOT EXISTS ${GLUE_DATABASE}.$1 (
  eventversion string,
  useridentity struct<type:string,principalid:string,arn:string,accountid:string,invokedby:string,accesskeyid:string,username:string,
                      sessioncontext:struct<attributes:struct<mfaauthenticated:string,creationdate:string>,
                                            sessionissuer:struct<type:string,principalid:string,arn:string,accountid:string,username:string>,
                                            sourceidentity:string>>,
  eventtime string, eventsource string, eventname string, awsregion string, sourceipaddress string, useragent string,
  errorcode string, errormessage string, requestparameters string, responseelements string, additionaleventdata string,
  requestid string, eventid string, resources array<struct<arn:string,accountid:string,type:string>>,
  eventtype string, apiversion string, readonly string, recipientaccountid string, serviceeventdetails string,
  sharedeventid string, vpcendpointid string, eventcategory string,
  tlsdetails struct<tlsversion:string,ciphersuite:string,clientprovidedhostheader:string>
)
PARTITIONED BY (year string, month string, day string)
ROW FORMAT SERDE 'org.apache.hive.hcatalog.data.JsonSerDe'
STORED AS INPUTFORMAT 'com.amazon.emr.cloudtrail.CloudTrailInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION 's3://$2/AWSLogs/$3/CloudTrail/${REGION}/'
TBLPROPERTIES (
  'classification'='cloudtrail',
  'projection.enabled'='true',
  'projection.year.type'='integer',  'projection.year.range'='2026,2035',
  'projection.month.type'='integer', 'projection.month.range'='1,12', 'projection.month.digits'='2',
  'projection.day.type'='integer',   'projection.day.range'='1,31',   'projection.day.digits'='2',
  'storage.location.template'='s3://$2/AWSLogs/$3/CloudTrail/${REGION}/\${year}/\${month}/\${day}'
)
EOF
athena_run "ddl_$1.sql"
}

cloudtrail_ddl storage_datalake_trail "$STORAGE_CT_BUCKET"        "$STORAGE_ACCOUNT_ID"
cloudtrail_ddl feeder_trail           "$FEEDER_CT_REPLICA_BUCKET" "$FEEDER_ACCOUNT_ID"

cat > ddl_access_grants.sql <<EOF
CREATE EXTERNAL TABLE IF NOT EXISTS ${GLUE_DATABASE}.access_grants (
  grant_id string, grant_arn string, grantee_type string, grantee_identifier string,
  permission string, grant_scope string, location_id string, created_at string, exported_at string
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
LOCATION 's3://${INVENTORY_BUCKET}/access-grants/'
EOF
athena_run ddl_access_grants.sql

log "done: ${GLUE_DATABASE}.{storage_datalake_trail,feeder_trail,access_grants}"
