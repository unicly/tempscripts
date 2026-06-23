# AWS Profile Switcher (`awsp.sh`)

This script (`awsp.sh`) provides an interactive, vertical menu in your terminal to easily switch between your different AWS accounts.

When you select a profile, it dynamically exports the correct temporary credentials to your active terminal session and validates them with AWS.

---

## Prerequisites

1. **AWS CLI v2** must be installed.
2. The script **must be sourced** (not executed directly) so that it can export environment variables to your current shell.

---

## Step-by-Step Setup

### Step 1: Configure your AWS Profiles

Profiles are configured in your global AWS config file `~/.aws/config`

#### A. For AWS SSO
Add an `sso-session` block and configure your profiles to use it:

```ini
[sso-session my-session]
sso_start_url = https://d-xxxxxxxxxx.awsapps.com/start
sso_region = eu-west-1
sso_registration_scopes = sso:account:access

[profile CORE]
sso_session = my-session
sso_account_id = 123456789012  # Replace with your actual AWS Account ID
sso_role_name = PowerUserAccess # Replace with your assigned IAM Role Name
region = eu-west-1
output = json
```

*Note: SSO profiles do **not** require any access keys in `~/.aws/credentials`.

---

### Step 2: Retrieve your SSO Account ID & Role Name (SSO only)

If you do not know your actual AWS Account ID or Role Name for the SSO config, follow these steps:

1. **Authenticate to the SSO session**:
   ```bash
   aws sso login --sso-session my-session
   ```
2. **List all your accessible Account IDs**:
   ```bash
   aws sso list-accounts --sso-session my-session
   ```
3. **List available IAM Roles for a specific Account**:
   ```bash
   aws sso list-account-roles --account-id <ACCOUNT_ID> --sso-session my-session
   ```
4. Copy these values and update them in `~/.aws/credentials`.

---

### Step 3: Run the Script

Run the script by **sourcing** it from your terminal:

```bash
source ./awsp.sh
```
or:
```bash
. ./awsp.sh
```

#### How it works when run:
1. **Lists Profiles**: Shows a vertical, alphabetically sorted list of all profiles available in `~/.aws/config`.
2. **Selects Account**: Enter the number corresponding to the profile you want to log in to.
3. **Unsets Stale Credentials**: Cleans up any existing `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, and `AWS_PROFILE` to prevent terminal state pollution.
4. **Obtains & Loads Credentials**:
   - **For Static/Role Assumption**: Natively exports active keys. If MFA is configured, it prompts you for your MFA token code automatically.
   - **For SSO**: Checks for an active token. If expired, it automatically triggers `aws sso login` to open your browser, generates a new token, and retrieves the keys.
5. **Verifies Session**: Performs an `aws sts get-caller-identity` verification call.
   - If successful: You are logged in!
   - If it fails (e.g. keys are deactivated or expired): It prints the AWS error, automatically unsets the variables to keep your terminal clean, and exits.
