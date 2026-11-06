# Run AWS CLI commands as the role IAM_FULL_PERM, from a federated user

You log in to AWS as a **federated user** and want to run AWS CLI commands with the existing role
**`IAM_FULL_PERM`**, which has the permissions you need.

You only need two things:

1. The AWS CLI already works with your federated user.
2. One profile that switches to `IAM_FULL_PERM`.

## Step 1: check that the CLI works as your federated user

```bash
aws sts get-caller-identity
```

- **It shows your identity:** go to step 2. Note the account number (`"Account"`).
- **It fails:** the CLI doesn't have your credentials yet. Open the AWS login page you normally use. Most
  federated logins have a **"Command line or programmatic access"** or **"Access keys"** link. Copy the three
  `export AWS_...` lines it shows, paste them into your terminal, then run the command again.

## Step 2: add a profile for the role (one time)

Add this to the file `~/.aws/config`. Replace `111111111111` with the account number where `IAM_FULL_PERM`
lives:

```ini
[profile iam-full-perm]
role_arn = arn:aws:iam::111111111111:role/IAM_FULL_PERM
credential_source = Environment
role_session_name = my-name
duration_seconds = 3600
region = eu-west-1
```

`credential_source = Environment` means: use the federated credentials from step 1 to assume `IAM_FULL_PERM`.

If your credentials aren't in environment variables but in a profile (step 1 only works with
`--profile something`), replace that line with `source_profile = something`.

## Step 3: run commands as `IAM_FULL_PERM`

Add `--profile iam-full-perm` to any command:

```bash
aws sts get-caller-identity --profile iam-full-perm
# "Arn": "arn:aws:sts::111111111111:assumed-role/IAM_FULL_PERM/my-name"   ← it worked

aws s3 ls --profile iam-full-perm
```

For the scripts in [`../../scripts/s3-access-grants-cross-account/`](../../scripts/s3-access-grants-cross-account/),
set `PROFILE="iam-full-perm"`.

## If step 3 says `AccessDenied ... sts:AssumeRole`

Your federated user isn't allowed to switch to `IAM_FULL_PERM` yet. An administrator must change two things:

1. **Trust policy of `IAM_FULL_PERM`:** allow the role your federated login uses. Its ARN appears in step 1's
   output, like `arn:aws:sts::111111111111:assumed-role/<FederatedRole>/you`. The trust policy needs
   `arn:aws:iam::111111111111:role/<FederatedRole>`.
2. **Your federated role:** allow `sts:AssumeRole` on `arn:aws:iam::111111111111:role/IAM_FULL_PERM`.

## Limit

Credentials from switching role this way last at most **1 hour**. After that, the CLI asks again automatically,
as long as your federated credentials from step 1 are still valid.
