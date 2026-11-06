# Run AWS CLI commands with an existing role, as a federated user

You log in to AWS as a **federated user** (IAM Identity Center / SSO, or SAML) and want to run AWS CLI
commands with an **existing IAM role** that has the permissions you need.

## Short answer

Make a **profile that assumes the role**, built on top of the profile you already use to log in as a federated
user. The AWS CLI then assumes the role for you and refreshes the credentials automatically.

## 1. Find the profile you log in with

| How you're federated | Your "source" profile |
|---|---|
| **IAM Identity Center (SSO)**, `aws sso login --profile X` | That profile, `X` |
| **SAML tool** (saml2aws, gimme-aws-creds, aws-adfs…) writing to `~/.aws/credentials` | The profile the tool writes, often `saml` or `default` |
| **Temporary keys copied into environment variables** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) | No profile: use `credential_source = Environment` (see below) |

## 2. Add a role profile to `~/.aws/config`

```ini
# Existing profile, example with IAM Identity Center (keep yours as it is)
[profile federated]
sso_session = my-sso
sso_account_id = 111111111111
sso_role_name = MyPermissionSet
region = eu-west-1

# New profile: assumes the role using the federated profile's credentials
[profile my-role]
role_arn = arn:aws:iam::111111111111:role/MyExistingRole
source_profile = federated
role_session_name = my-name
duration_seconds = 3600
region = eu-west-1
```

If your credentials are in environment variables, replace `source_profile = federated` with:

```ini
credential_source = Environment
```

## 3. Log in, check, use

```bash
aws sso login --profile federated            # or your SAML tool's login

aws sts get-caller-identity --profile my-role
# → "Arn": "arn:aws:sts::111111111111:assumed-role/MyExistingRole/my-name"

aws s3 ls --profile my-role                  # any command, with --profile my-role
```

For the Access Grants scripts in
[`../../scripts/s3-access-grants-cross-account/`](../../scripts/s3-access-grants-cross-account/), set
`PROFILE="my-role"` in each script, or use `PROFILE_A=my-role` / `PROFILE_B=...` in `COMMANDS.md`. For two
accounts, create one role profile per account.

## Alternative: assume the role by hand

```bash
read -r AK SK ST < <(aws sts assume-role --profile federated \
  --role-arn arn:aws:iam::111111111111:role/MyExistingRole \
  --role-session-name my-name \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
export AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST
aws sts get-caller-identity
```

These credentials expire after the session duration and aren't refreshed. The profile approach above is
easier to maintain.

## If it fails with `AccessDenied` on `sts:AssumeRole`

| Check | What it needs |
|---|---|
| **Role's trust policy** | Must allow **your federated identity** as principal: the role your federated login gives you, e.g. `arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_MyPermissionSet_…` for Identity Center, or your SAML role |
| **Your federated role's permissions** | Must allow `sts:AssumeRole` on the target role ARN (unless both are in the same account and the trust policy names your role directly) |
| **Session duration** | Your federated login is already a role session, so assuming another role is **role chaining**, limited to **1 hour**. Keep `duration_seconds` at 3600 or less |
| **Cross-account** | Works the same way. The trust policy in the role's account must name your principal in the other account |
