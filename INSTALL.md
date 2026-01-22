# Installation and Usage Guide

This guide covers deploying the OIDC AWS S3 Uploader infrastructure and configuring clients to upload files.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Choose Your Identity Provider](#choose-your-identity-provider)
- [Admin: Deploy Infrastructure](#admin-deploy-infrastructure)
- [Admin: Onboard a Server](#admin-onboard-a-server)
- [User: Configure the Python Client](#user-configure-the-python-client)
- [User: Upload Files](#user-upload-files)
- [Log Shipper Integration](#log-shipper-integration)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### For Administrators

- **AWS Account** with permissions for:
  - IAM (roles, policies, OIDC providers)
  - S3 (bucket management)
  - Cognito (if using Cognito)
  - Lambda, API Gateway, DynamoDB (if using Cognito)

- **Terraform** >= 1.5.0

- **AWS CLI** configured with appropriate credentials

- **Auth0 Account** (if using Auth0):
  - Admin access to create applications and APIs

### For Users (On-Premises Servers)

- **Python 3.8+**
- **pip** for installing dependencies
- Network access to:
  - Auth0 or Cognito endpoints (HTTPS)
  - AWS S3 (HTTPS)
  - AWS STS or Credential Vending API (HTTPS)

---

## Choose Your Identity Provider

| Feature | Auth0 | AWS Cognito |
|---------|-------|-------------|
| External Account Needed | Yes | No |
| Terraform Providers | AWS + Auth0 | AWS only |
| Token Daemon Support | Yes | No (use credential-daemon) |
| Setup Complexity | Moderate | Simple |
| Cost | Auth0 pricing | Free tier available |

**Recommendation:**
- Choose **Cognito** for AWS-only environments or simpler operations
- Choose **Auth0** if you already use Auth0 or need the token daemon mode

---

## Admin: Deploy Infrastructure

### Step 1: Create Terraform State Backend

Create the S3 bucket and DynamoDB table for Terraform state (do this once):

```bash
# Create state bucket
aws s3api create-bucket \
  --bucket oidc-s3-uploader-tfstate \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

aws s3api put-bucket-versioning \
  --bucket oidc-s3-uploader-tfstate \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket oidc-s3-uploader-tfstate \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name oidc-s3-uploader-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-1
```

### Step 2a: Deploy Auth0 Infrastructure

#### Create Auth0 Management API App (Manual)

1. Go to Auth0 Dashboard → Applications → APIs → Auth0 Management API
2. Click "Machine to Machine Applications" tab
3. Create & Authorize a new application
4. Grant these scopes:
   - `create:clients`, `read:clients`, `update:clients`, `delete:clients`
   - `create:client_grants`, `read:client_grants`, `delete:client_grants`
   - `create:resource_servers`, `read:resource_servers`, `update:resource_servers`, `delete:resource_servers`
5. Note the Client ID and Client Secret

#### Deploy Foundation Layer

```bash
cd terraform/foundation

# Edit environment config
cp ../environments/dev/foundation.tfvars.example ../environments/dev/foundation.tfvars
# Edit foundation.tfvars with your Auth0 domain and settings

# Set Auth0 Management API credentials (don't commit these!)
export TF_VAR_auth0_client_id="your-management-api-client-id"
export TF_VAR_auth0_client_secret="your-management-api-client-secret"

# Deploy
terraform init -backend-config=../environments/dev/backend.hcl
terraform plan -var-file=../environments/dev/foundation.tfvars
terraform apply -var-file=../environments/dev/foundation.tfvars
```

### Step 2b: Deploy Cognito Infrastructure

No manual setup needed - Terraform manages everything.

#### Deploy Foundation Layer

```bash
cd terraform-cognito/foundation

# Edit environment config
cp ../environments/dev/foundation.tfvars.example ../environments/dev/foundation.tfvars
# Edit foundation.tfvars with your settings

# Deploy
terraform init -backend-config=../environments/dev/backend.hcl
terraform plan -var-file=../environments/dev/foundation.tfvars
terraform apply -var-file=../environments/dev/foundation.tfvars
```

---

## Admin: Onboard a Server

### Step 1: Add Server to Configuration

Edit the servers configuration file:

**For Auth0:** `terraform/environments/dev/servers.tfvars`
**For Cognito:** `terraform-cognito/environments/dev/servers.tfvars`

```hcl
servers = {
  "backup-server-01" = {
    s3_path_prefix = "backups/server-01/"
    s3_permissions = "write"  # or "read-write" or "full"
  }

  "log-shipper-01" = {
    s3_path_prefix = "logs/app-01/"
    s3_permissions = "write"
  }
}
```

### Step 2: Deploy Server Configuration

**For Auth0:**
```bash
cd terraform/servers
terraform init -backend-config=../environments/dev/servers-backend.hcl
terraform apply -var-file=../environments/dev/servers.tfvars
```

**For Cognito:**
```bash
cd terraform-cognito/servers
terraform init -backend-config=../environments/dev/servers-backend.hcl
terraform apply -var-file=../environments/dev/servers.tfvars
```

### Step 3: Get Server Credentials

```bash
# Get full configuration (non-sensitive)
terraform output -json server_configurations

# Get client secrets (sensitive - store securely!)
terraform output -json server_secrets
```

### Step 4: Provide Configuration to Server Admin

Create a configuration file for the server (example for Auth0):

```bash
# /etc/oidc-s3/config.env
IDP_TYPE=auth0

# Auth0 credentials
AUTH0_DOMAIN=your-tenant.auth0.com
AUTH0_CLIENT_ID=abc123...
AUTH0_CLIENT_SECRET=secret...
AUTH0_AUDIENCE=https://s3-uploader.dev.oidc-s3

# AWS configuration
AWS_ROLE_ARN=arn:aws:iam::123456789012:role/oidc-s3-dev-backup-server-01
AWS_REGION=eu-west-1

# S3 configuration
S3_BUCKET=oidc-s3-dev-uploads
S3_PATH_PREFIX=backups/server-01/
```

Example for Cognito:

```bash
# /etc/oidc-s3/config.env
IDP_TYPE=cognito

# Cognito credentials
COGNITO_DOMAIN=oidc-s3-dev-123456789012
COGNITO_CLIENT_ID=abc123...
COGNITO_CLIENT_SECRET=secret...
COGNITO_RESOURCE_SERVER=https://s3-uploader.dev.oidc-s3
COGNITO_CREDENTIAL_API_URL=https://xxx.execute-api.eu-west-1.amazonaws.com/credentials

# AWS configuration (no role ARN needed for Cognito)
AWS_REGION=eu-west-1

# S3 configuration
S3_BUCKET=oidc-s3-cognito-dev-uploads
S3_PATH_PREFIX=backups/server-01/
```

---

## User: Configure the Python Client

The client consists of two scripts:
- **`oidc_credential_provider.py`** - Handles OIDC authentication and AWS credential management
- **`s3_ops.py`** - Performs S3 operations using standard AWS credential chain

### Step 1: Install Dependencies

```bash
pip install boto3 requests

# Or use the requirements file
pip install -r scripts/requirements.txt
```

### Step 2: Set Environment Variables

Source the configuration file provided by your administrator:

```bash
source /etc/oidc-s3/config.env
```

### Step 3: Set Up Credential Provider

The recommended approach is using AWS SDK's `credential_process`:

**Create an AWS config file** (e.g., `/etc/oidc-s3/aws-config`):

```ini
[profile oidc-s3]
credential_process = /bin/bash -c 'source /etc/oidc-s3/config.env && python3 /opt/oidc-s3/oidc_credential_provider.py get-credentials'
region = eu-west-1
```

**Add to your environment** (in `/etc/oidc-s3/config.env`):

```bash
export AWS_CONFIG_FILE=/etc/oidc-s3/aws-config
export AWS_PROFILE=oidc-s3
```

### Step 4: Verify Configuration

```bash
source /etc/oidc-s3/config.env
python scripts/s3_ops.py list
```

---

## User: Upload Files

### Basic Upload

```bash
# Upload a file (uses configured path prefix)
python scripts/s3_ops.py upload /path/to/file.txt

# Upload with custom S3 key
python scripts/s3_ops.py upload /path/to/file.txt --key custom/path/file.txt
```

### Download Files

```bash
# Download a file
python scripts/s3_ops.py download backups/server-01/file.txt /tmp/file.txt
```

### List Files

```bash
# List objects in configured prefix
python scripts/s3_ops.py list

# List objects in custom prefix
python scripts/s3_ops.py list --prefix logs/
```

### Delete Files

```bash
# Delete a file (requires "full" permission level)
python scripts/s3_ops.py delete backups/server-01/old-file.txt
```

---

## Log Shipper Integration

For log shippers like Vector, Fluent Bit, or Logstash, the recommended approach is using `credential_process` which enables automatic credential refresh.

### Option 1: credential_process (Recommended)

This is the recommended approach because the AWS SDK automatically calls the script when credentials expire, enabling seamless credential refresh without restarting the log shipper.

**Step 1: Create AWS config file** (`/etc/oidc-s3/aws-config`):

```ini
[profile oidc-s3]
credential_process = /bin/bash -c 'source /etc/oidc-s3/config.env && python3 /opt/oidc-s3/oidc_credential_provider.py get-credentials'
region = eu-west-1
```

**Step 2: Configure your log shipper environment:**

```bash
export AWS_CONFIG_FILE=/etc/oidc-s3/aws-config
export AWS_PROFILE=oidc-s3
```

**Step 3: Start your log shipper normally** - credentials refresh automatically.

### Option 2: Credential Daemon (Legacy)

The credential daemon writes credentials to files periodically. However, most applications cache credentials in memory and won't detect file changes, requiring a restart when credentials expire.

**Start the daemon:**

```bash
python scripts/oidc_credential_provider.py credential-daemon --creds-dir /var/run/aws-creds
```

**Configure your log shipper:**

```bash
export AWS_SHARED_CREDENTIALS_FILE=/var/run/aws-creds/credentials
```

**Systemd service example:**

```ini
# /etc/systemd/system/oidc-credential-daemon.service
[Unit]
Description=OIDC Credential Daemon for AWS S3
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/oidc-s3/config.env
ExecStart=/usr/bin/python3 /opt/oidc-s3/oidc_credential_provider.py credential-daemon --creds-dir /var/run/aws-creds
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### Option 3: Token Daemon (Auth0 only)

For log shippers that support `AWS_WEB_IDENTITY_TOKEN_FILE`:

```bash
python scripts/oidc_credential_provider.py token-daemon --token-file /var/run/oidc/token
```

**Configure your log shipper:**

```bash
export AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/oidc/token
export AWS_ROLE_ARN=arn:aws:iam::123456789012:role/oidc-s3-dev-server
```

**Note:** This does NOT work with Cognito. Use `credential_process` instead.

### Vector Configuration Example

```toml
# vector.toml
[sinks.s3]
type = "aws_s3"
region = "eu-west-1"
bucket = "oidc-s3-dev-uploads"
key_prefix = "logs/app-01/"
encoding.codec = "json"

# No explicit credentials config needed
# Vector uses AWS_CONFIG_FILE + AWS_PROFILE from environment
```

**Start Vector:**

```bash
source /etc/oidc-s3/config.env  # Sets AWS_CONFIG_FILE and AWS_PROFILE
vector -c vector.toml
```

### Logstash Configuration Example

```ruby
# logstash.conf
output {
  s3 {
    region => "eu-west-1"
    bucket => "oidc-s3-dev-uploads"
    prefix => "logs/app-01/"
    # Logstash uses standard AWS credential chain
  }
}
```

---

## Troubleshooting

### "Missing required environment variables"

Ensure all required variables are set. Check `IDP_TYPE` to see which variables are needed:

```bash
# For Auth0
export IDP_TYPE=auth0
# Requires: AUTH0_DOMAIN, AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET, AUTH0_AUDIENCE, AWS_ROLE_ARN

# For Cognito
export IDP_TYPE=cognito
# Requires: COGNITO_DOMAIN, COGNITO_CLIENT_ID, COGNITO_CLIENT_SECRET, COGNITO_RESOURCE_SERVER, COGNITO_CREDENTIAL_API_URL
```

### "Invalid audience" or "Invalid subject" (Auth0)

Check that:
1. `AUTH0_AUDIENCE` matches the Auth0 API identifier
2. `AWS_ROLE_ARN` matches the role created for this server
3. The Auth0 client ID in the IAM role trust policy matches your client

### "Missing a required claim: aud" (Cognito)

This error occurs when trying to use Cognito tokens with STS directly. Ensure:
1. `IDP_TYPE=cognito` is set
2. `COGNITO_CREDENTIAL_API_URL` is set to the credential vending API URL

### "Access Denied" from S3

Check:
1. The S3 path matches the configured `S3_PATH_PREFIX`
2. The operation matches the permission level (write/read-write/full)
3. Credentials are not expired

### "Credentials expired"

The credential daemon may have stopped. Check:
```bash
systemctl status oidc-credential-daemon
```

Restart if needed:
```bash
systemctl restart oidc-credential-daemon
```

### Testing Connectivity

```bash
# Test Auth0 token endpoint
curl -X POST https://your-tenant.auth0.com/oauth/token \
  -H "Content-Type: application/json" \
  -d '{"grant_type":"client_credentials","client_id":"xxx","client_secret":"xxx","audience":"https://..."}'

# Test Cognito token endpoint
curl -X POST "https://domain.auth.eu-west-1.amazoncognito.com/oauth2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "client_id:client_secret" \
  -d "grant_type=client_credentials&scope=https://resource-server/write"
```

---

## Security Best Practices

1. **Store secrets securely**: Use secrets managers, encrypted files, or environment variables. Never commit secrets to version control.

2. **Use least privilege**: Only grant the minimum S3 permissions needed (prefer `write` over `full`).

3. **Rotate credentials**: Periodically rotate Auth0/Cognito client secrets and update server configurations.

4. **Monitor access**: Enable S3 access logging and CloudTrail to track who accesses what.

5. **Network security**: Restrict outbound network access to only required endpoints (Auth0/Cognito, AWS).

6. **Credential file permissions**: Set restrictive permissions on credential files:
   ```bash
   chmod 600 /etc/oidc-s3/config.env
   chmod 700 /var/run/aws-creds
   ```
