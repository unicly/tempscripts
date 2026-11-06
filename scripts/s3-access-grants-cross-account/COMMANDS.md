# Plain AWS CLI commands (copy and paste)

The same steps as [`account_b_setup.sh`](account_b_setup.sh) and [`account_a_grant.sh`](account_a_grant.sh),
without the checks and retries. Set the variables first:

```bash
REGION=eu-west-1
ACCOUNT_A_ID=111111111111      # S3 Access Grants + bucket
ACCOUNT_B_ID=222222222222      # Lambda
ROLE_NAME=s3-access-grants-lambda-role
FUNCTION_NAME=s3-access-grants-test
BUCKET=my-bucket
PREFIX=data/
```

## 1. Account B: create the IAM role

```bash
aws iam create-role --role-name $ROLE_NAME \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam attach-role-policy --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

aws iam put-role-policy --role-name $ROLE_NAME --policy-name s3-access-grants \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetDataAccess\",\"s3:GetAccessGrantsInstanceForPrefix\",\"s3:ListCallerAccessGrants\"],\"Resource\":\"arn:aws:s3:${REGION}:${ACCOUNT_A_ID}:access-grants/default\"}]}"
```

## 2. Account A: allow account B and grant the role

```bash
# Find the location ID that covers the bucket ("default" = s3://)
aws s3control list-access-grants-locations --account-id $ACCOUNT_A_ID --region $REGION

# Replaces any existing resource policy on the instance
aws s3control put-access-grants-instance-resource-policy --account-id $ACCOUNT_A_ID --region $REGION \
  --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"${ACCOUNT_B_ID}\"},\"Action\":[\"s3:GetDataAccess\",\"s3:GetAccessGrantsInstanceForPrefix\",\"s3:ListCallerAccessGrants\"],\"Resource\":\"arn:aws:s3:${REGION}:${ACCOUNT_A_ID}:access-grants/default\"}]}"

# With the default location (s3://) the sub-prefix includes the bucket name
aws s3control create-access-grant --account-id $ACCOUNT_A_ID --region $REGION \
  --access-grants-location-id default \
  --access-grants-location-configuration S3SubPrefix=${BUCKET}/${PREFIX}* \
  --permission READWRITE \
  --grantee GranteeType=IAM,GranteeIdentifier=arn:aws:iam::${ACCOUNT_B_ID}:role/${ROLE_NAME}
```

If your location is registered as `s3://my-bucket/` instead of the default, use its location ID and
`S3SubPrefix=${PREFIX}*`.

## 3. Account B: create and run the Lambda function

```bash
cd scripts/s3-access-grants-cross-account/lambda
zip function.zip lambda_function.py

aws lambda create-function --function-name $FUNCTION_NAME --region $REGION \
  --runtime python3.13 --architectures arm64 \
  --handler lambda_function.lambda_handler \
  --role arn:aws:iam::${ACCOUNT_B_ID}:role/${ROLE_NAME} \
  --zip-file fileb://function.zip --timeout 60 --memory-size 256 \
  --environment "Variables={ACCESS_GRANTS_ACCOUNT_ID=${ACCOUNT_A_ID},BUCKET=${BUCKET},PREFIX=${PREFIX}}"

aws lambda wait function-active-v2 --function-name $FUNCTION_NAME --region $REGION

aws lambda invoke --function-name $FUNCTION_NAME --region $REGION \
  --cli-binary-format raw-in-base64-out --payload '{}' \
  --log-type Tail --query LogResult --output text response.json | base64 -d
cat response.json
```

If `create-function` fails with "role cannot be assumed", the new role hasn't propagated yet. Wait about
10 seconds and run it again.
