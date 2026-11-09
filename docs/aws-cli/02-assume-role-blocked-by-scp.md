# Switching to IAM_FULL_PERM is blocked by an SCP

Follow-up to [`01-assume-role-from-federated-user.md`](01-assume-role-from-federated-user.md): switching from
the SSO (IAM Identity Center) role to `IAM_FULL_PERM` fails with `AccessDenied`, and the cause is a
**service control policy (SCP)**.

If an SCP blocks it, **you can't fix it yourself**. Changing the trust policy or your permissions won't help.

## What an SCP is

- SCPs are rules set centrally in **AWS Organizations**, by the team that manages all your company's AWS accounts.
- They **override everything** in the account: an SCP "deny" wins over any IAM policy, trust policy or admin
  permission in that account.
- Companies often use them to stop people switching from their SSO role to more powerful roles. That's exactly
  what's happening here.

## Confirm it's the SCP

The error message says so explicitly:

```
... is not authorized to perform: sts:AssumeRole on resource: arn:aws:iam::123456789012:role/IAM_FULL_PERM
with an explicit deny in a service control policy: arn:aws:organizations::999999999999:policy/o-abc123/service_control_policy/p-xyz789
```

If you see `with an explicit deny in a service control policy`, it's the SCP. The ARN at the end, if shown,
identifies which SCP blocks you. It's useful for the request below.

## What you can do

| Option | Who does it | Comment |
|---|---|---|
| **1. A permission set with the permissions you need** | IAM Identity Center admins | **Usually the preferred way** in companies that use SSO: you pick it in the portal, with no role switch, so the SCP doesn't apply |
| **2. An exception in the SCP** for your SSO role → `IAM_FULL_PERM` | AWS Organizations / cloud platform team | They add a `Condition` exempting your role or `IAM_FULL_PERM`. Security teams are often reluctant |
| **3. Use the intended way to use `IAM_FULL_PERM`** | You | The role may be meant only for CI/CD pipelines or automation, not for people. Ask what it's for |

## What to send your cloud or security team

```
Request: switch from my SSO role to IAM_FULL_PERM is blocked by an SCP.

My session:   arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_<PermissionSet>_<code>/<me>
My role:      arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_<PermissionSet>_<code>
Target role:  arn:aws:iam::123456789012:role/IAM_FULL_PERM
Action:       sts:AssumeRole
Error:        <full error message, including the SCP ARN>
Purpose:      <what you need to do: e.g. create IAM roles and Lambda functions for the S3 Access Grants test>

Options: a permission set with the needed permissions, or an SCP exception for this role.
```

Until then, the Access Grants setup
([`../../scripts/s3-access-grants-cross-account/`](../../scripts/s3-access-grants-cross-account/)) can be done by
someone who already has the permissions. Or wait for the new permission set, then use your SSO profile directly
as `PROFILE` in the scripts, with no role switch.
