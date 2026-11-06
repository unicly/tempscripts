# Cross-account S3 Access Grants for a Lambda function

A Lambda function in **account B** reads and writes a bucket in **account A** through **S3 Access Grants** in
account A. The function lists the objects under a prefix, creates a test file there, then deletes it.

```
Account B                                            Account A
┌─────────────────────────────┐   s3:GetDataAccess   ┌──────────────────────────────────────┐
│ Lambda  (role: s3-access-   │ ───────────────────► │ S3 Access Grants instance            │
│          grants-lambda-role)│ ◄─────────────────── │  resource policy: allows account B   │
│                             │  temporary creds     │  grant: role → READWRITE s3://b/p*   │
│   list / put / delete  ─────┼─────────────────────►│  location role → bucket              │
└─────────────────────────────┘   (vended creds)     └──────────────────────────────────────┘
```

The role in account B has **no direct S3 permissions**. It may only call `s3:GetDataAccess` on the
Access Grants instance in account A. S3 access comes from the temporary credentials that Access
Grants returns, which act as the **location's IAM role in account A**. So no bucket policy change is needed.

## Files

| File | Account | What it does |
|---|---|---|
| [`account_b_setup.sh`](account_b_setup.sh) | B | `role`: IAM role (Lambda trust, logs, `s3:GetDataAccess` on account A's instance). `lambda`: package and create/update the function. `invoke`: run it and show logs |
| [`account_a_grant.sh`](account_a_grant.sh) | A | Resource policy on the Access Grants instance for account B, and a READWRITE grant for the role |
| [`lambda/lambda_function.py`](lambda/lambda_function.py) | B | The function code |

## Steps

Edit the variables at the top of both scripts (region, account IDs, bucket, prefix). Then:

```bash
# 1. Account B: create the role
./account_b_setup.sh role

# 2. Account A: allow account B and grant the role
./account_a_grant.sh

# 3. Account B: create the function and run it
./account_b_setup.sh lambda
./account_b_setup.sh invoke
```

The role must exist before the grant is created in account A, which is why the steps alternate between
the accounts.

## Prerequisites and checks

| Point | Detail |
|---|---|
| Access Grants in account A | An instance and a **registered location** covering the bucket, with its IAM role allowed on the bucket (and on the KMS key if the bucket uses SSE-KMS) |
| Region | The Lambda must call `GetDataAccess` in the **region of the Access Grants instance**. The scripts use the same `REGION` for both |
| Resource policy | `put-access-grants-instance-resource-policy` **replaces** the current policy. The script prints the existing one first: merge it by hand if there is one |
| Prefix | `PREFIX` must match the grant. With the default location `s3://`, the script builds the sub-prefix as `bucket/prefix*` |
| Credential lifetime | `DURATION_SECONDS` (default 900, the minimum) |
| Runtime | Python 3.13 on arm64, boto3 from the Lambda runtime |

## Troubleshooting

| Error | Likely cause |
|---|---|
| `GetDataAccess` → `AccessDenied` | No grant for this role on that prefix, missing resource policy in account A, missing `s3:GetDataAccess` in the role policy, or wrong region |
| `put_object` / `list_objects_v2` → `AccessDenied` | The location role in account A has no permission on the bucket or the KMS key, or the grant is `READ` only |
| `create-function` → role cannot be assumed | New role not propagated yet. The script retries for about a minute |

Not tested against real AWS accounts. The Lambda code was tested with botocore's `Stubber`, and both scripts
with a stub `aws` command.
