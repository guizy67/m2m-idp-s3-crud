# DESIGN.md - Implementation Design & Task List

This document provides detailed implementation guidance and a comprehensive task list for building the OIDC AWS S3 Uploader infrastructure.

## 1. Prerequisites

### 1.1 Required Accounts & Access

- [x] AWS account with admin access (or permissions to create IAM, S3, OIDC providers)
- [x] Auth0 tenant with admin access
- [x] Terraform >= 1.5.0 installed locally
- [x] AWS CLI configured with appropriate credentials
- [x] Python 3.8+ for the uploader script

### 1.2 Auth0 Management API Application

Before Terraform can manage Auth0 resources, create a Management API application manually:

1. Auth0 Dashboard → Applications → APIs → Auth0 Management API
2. Machine to Machine Applications tab → Create & Authorize
3. Grant these scopes:
   - `create:clients`
   - `read:clients`
   - `update:clients`
   - `delete:clients`
   - `create:client_grants`
   - `read:client_grants`
   - `delete:client_grants`
   - `create:resource_servers`
   - `read:resource_servers`
   - `update:resource_servers`
   - `delete:resource_servers`

4. Note the Client ID and Client Secret for Terraform

### 1.2b AWS Cognito Setup (Alternative to Auth0)

If using AWS Cognito instead of Auth0, no manual IdP setup is required - Terraform manages everything via the AWS provider. Ensure your AWS credentials have permissions to:

- `cognito-idp:*` (Cognito User Pool management)
- `iam:*` (IAM role and OIDC provider management)
- `s3:*` (S3 bucket management)

**Advantages of Cognito:**

- No additional IdP account needed
- Single Terraform provider (AWS only)
- Native AWS integration (simpler OIDC trust)
- Free tier available (50,000 MAUs)

**When to choose Cognito over Auth0:**

- AWS-only infrastructure
- Simpler operational model (one less vendor)
- Cost optimization for high-volume M2M tokens
- Already using AWS Organizations/SSO

### 1.3 Terraform State Backend

Create the S3 bucket and DynamoDB table for Terraform state before running any Terraform:

```bash
# Create state bucket (do this once, manually or via bootstrap script)
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

---

## 2. Implementation Tasks

### Phase 1: Project Setup

#### 1.1 Directory Structure
- [x] Create `terraform/` directory
- [x] Create `terraform/foundation/` directory
- [x] Create `terraform/servers/` directory
- [x] Create `terraform/modules/server-access/` directory
- [x] Create `terraform/environments/dev/` directory
- [x] Create `terraform/environments/prod/` directory
- [x] Create `scripts/` directory

#### 1.2 Environment Configuration Files
- [x] Create `terraform/environments/dev/backend.hcl`
- [x] Create `terraform/environments/dev/foundation.tfvars`
- [x] Create `terraform/environments/dev/servers.tfvars`
- [x] Create `terraform/environments/prod/backend.hcl`
- [x] Create `terraform/environments/prod/foundation.tfvars`
- [x] Create `terraform/environments/prod/servers.tfvars`

---

### Phase 2: Foundation Layer

#### 2.1 Main Configuration
- [x] Create `terraform/foundation/main.tf`
  - [x] Terraform version constraint (>= 1.5.0)
  - [x] Required providers (aws ~> 5.0, auth0 ~> 1.0)
  - [x] Backend configuration (S3)
  - [x] AWS provider with default tags
  - [x] Auth0 provider configuration

#### 2.2 Variables
- [x] Create `terraform/foundation/variables.tf`
  - [x] `environment` (string, "dev" or "prod")
  - [x] `aws_region` (string)
  - [x] `auth0_domain` (string)
  - [x] `auth0_client_id` (string, sensitive)
  - [x] `auth0_client_secret` (string, sensitive)
  - [x] `project_name` (string, default "oidc-s3")

#### 2.3 Auth0 API Resource
- [x] Create `terraform/foundation/auth0.tf`
  - [x] `auth0_resource_server` resource for the S3 uploader API
  - [x] Set identifier (audience) to `https://s3-uploader.{env}.{domain}`
  - [x] Set token_lifetime to 86400 (24 hours)

#### 2.4 AWS OIDC Provider
- [x] Create `terraform/foundation/aws-oidc-provider.tf`
  - [x] `aws_iam_openid_connect_provider` resource
  - [x] URL: `https://{auth0_domain}/`
  - [x] client_id_list: Auth0 API identifier
  - [x] Thumbprint handling (use data source or placeholder)

#### 2.5 S3 Bucket
- [x] Create `terraform/foundation/s3.tf`
  - [x] `aws_s3_bucket` resource with naming convention
  - [x] `aws_s3_bucket_versioning` (enabled for prod, disabled for dev)
  - [x] `aws_s3_bucket_lifecycle_configuration` (10-day expiry for dev only)
  - [x] `aws_s3_bucket_server_side_encryption_configuration` (AES256)
  - [x] `aws_s3_bucket_public_access_block` (all blocked)

#### 2.6 Outputs
- [x] Create `terraform/foundation/outputs.tf`
  - [x] `oidc_provider_arn`
  - [x] `oidc_provider_url` (without https://, with trailing slash)
  - [x] `audience` (Auth0 API identifier)
  - [x] `auth0_api_id`
  - [x] `bucket_arn`
  - [x] `bucket_name`
  - [x] `aws_region`

#### 2.7 AWS Cognito Foundation (Alternative to Auth0)

**Note:** Cognito uses a **credential vending API** instead of direct STS federation because Cognito M2M tokens lack the `aud` claim required by `AssumeRoleWithWebIdentity`. See [IMPLEMENTATION.md](IMPLEMENTATION.md) for details.

- [x] Create `terraform-cognito/foundation/cognito.tf`
  - [x] `aws_cognito_user_pool` resource
  - [x] `aws_cognito_user_pool_domain` resource
  - [x] `aws_cognito_resource_server` resource with scopes (write, read, delete, list)
- [x] Create `terraform-cognito/foundation/credential-vending.tf`
  - [x] API Gateway HTTP API for credential vending
  - [x] Lambda function to validate tokens and vend credentials
  - [x] DynamoDB table for client-to-role mappings
  - [x] IAM role for Lambda with STS AssumeRole permissions
- [x] Update outputs for Cognito:
  - [x] `cognito_user_pool_id`
  - [x] `cognito_domain`
  - [x] `cognito_token_endpoint`
  - [x] `resource_server_identifier`
  - [x] `credential_vending_api_url`
  - [x] `credential_vending_lambda_role_arn`
  - [x] `client_roles_table_name`

---

### Phase 3: Server Access Module

#### 3.1 Module Variables
- [x] Create `terraform/modules/server-access/variables.tf`
  - [x] `server_name` (string)
  - [x] `environment` (string)
  - [x] `auth0_api_id` (string)
  - [x] `oidc_provider_arn` (string)
  - [x] `oidc_provider_url` (string)
  - [x] `audience` (string)
  - [x] `bucket_arn` (string)
  - [x] `bucket_name` (string)
  - [x] `s3_path_prefix` (string)
  - [x] `s3_permissions` (string, validation for write/read-write/full)
  - [x] `max_session_duration` (number, default 3600)
  - [x] `tags` (map(string))

#### 3.2 Module Resources
- [x] Create `terraform/modules/server-access/main.tf`
  - [x] Local variables for S3 action mapping
  - [x] `auth0_client` resource (M2M application)
  - [x] `auth0_client_grant` resource (grant to API)
  - [x] `aws_iam_role` resource with trust policy
    - [x] Federated principal (OIDC provider)
    - [x] Condition: aud = audience
    - [x] Condition: sub = {client_id}@clients
  - [x] `aws_iam_role_policy` for S3 object operations
  - [x] `aws_iam_role_policy` for S3 ListBucket (conditional on "full" permission)

#### 3.3 Module Outputs
- [x] Create `terraform/modules/server-access/outputs.tf`
  - [x] `role_arn`
  - [x] `role_name`
  - [x] `auth0_client_id`
  - [x] `auth0_client_secret` (sensitive)

#### 3.4 AWS Cognito Server Access Module (Alternative)

**Note:** Unlike Auth0, Cognito IAM roles trust the credential vending Lambda (not an OIDC provider) because Cognito M2M tokens lack the `aud` claim.

- [x] Create `terraform-cognito/modules/server-access/variables.tf`
  - [x] `server_name` (string)
  - [x] `cognito_user_pool_id` (string)
  - [x] `resource_server_identifier` (string)
  - [x] `credential_vending_lambda_role_arn` (string) - Lambda role to trust
  - [x] `client_roles_table_name` (string) - DynamoDB table for mappings
  - [x] Other variables same as Auth0 module
- [x] Create `terraform-cognito/modules/server-access/main.tf`
  - [x] `aws_cognito_user_pool_client` with:
    - [x] `generate_secret = true`
    - [x] `allowed_oauth_flows = ["client_credentials"]`
    - [x] `allowed_oauth_scopes` with resource server scopes
  - [x] `aws_iam_role` with trust policy:
    - [x] Trust: credential vending Lambda role ARN (not OIDC provider)
    - [x] Action: `sts:AssumeRole` (not AssumeRoleWithWebIdentity)
  - [x] `aws_dynamodb_table_item` for client-role mapping
  - [x] S3 policies same as Auth0 module
- [x] Create `terraform-cognito/modules/server-access/outputs.tf`
  - [x] `role_arn`
  - [x] `cognito_client_id`
  - [x] `cognito_client_secret` (sensitive)
  - [x] `allowed_scopes`

---

### Phase 4: Servers Layer

#### 4.1 Main Configuration
- [x] Create `terraform/servers/main.tf`
  - [x] Terraform version and provider requirements
  - [x] Backend configuration (S3, different key than foundation)
  - [x] AWS provider
  - [x] Auth0 provider
  - [x] `terraform_remote_state` data source for foundation outputs

#### 4.2 Variables
- [x] Create `terraform/servers/variables.tf`
  - [x] `environment` (string)
  - [x] `aws_region` (string)
  - [x] `auth0_domain` (string)
  - [x] `auth0_client_id` (string, sensitive)
  - [x] `auth0_client_secret` (string, sensitive)
  - [x] `servers` (map of server configurations)
  - [x] `common_tags` (map(string))

#### 4.3 Server Definitions
- [x] Create `terraform/servers/servers.tf`
  - [x] Module invocation with `for_each = var.servers`
  - [x] Pass all required variables from remote state
  - [x] Tag merging

#### 4.4 Outputs
- [x] Create `terraform/servers/outputs.tf`
  - [x] `server_configurations` (map with all config per server)
  - [x] `server_secrets` (map of client secrets, sensitive)

---

### Phase 5: Environment Files

#### 5.1 Dev Environment
- [x] `terraform/environments/dev/backend.hcl`
  ```hcl
  bucket         = "oidc-s3-uploader-tfstate"
  key            = "dev/foundation/terraform.tfstate"  # or servers/
  region         = "eu-west-1"
  dynamodb_table = "oidc-s3-uploader-tflock"
  encrypt        = true
  ```

- [x] `terraform/environments/dev/foundation.tfvars`
  ```hcl
  environment   = "dev"
  aws_region    = "eu-west-1"
  auth0_domain  = "your-tenant.auth0.com"
  project_name  = "oidc-s3"
  ```

- [x] `terraform/environments/dev/servers.tfvars`
  ```hcl
  environment = "dev"
  aws_region  = "eu-west-1"
  auth0_domain = "your-tenant.auth0.com"

  servers = {
    "test-server" = {
      s3_path_prefix = "test/"
      s3_permissions = "full"
    }
  }

  common_tags = {
    Environment = "dev"
    Project     = "oidc-s3-uploader"
  }
  ```

#### 5.2 Prod Environment
- [x] `terraform/environments/prod/backend.hcl`
- [x] `terraform/environments/prod/foundation.tfvars`
- [x] `terraform/environments/prod/servers.tfvars`

---

### Phase 6: Python Client

The client is split into two focused scripts:
- **`oidc_credential_provider.py`** - Handles OIDC authentication and AWS credential management
- **`s3_ops.py`** - Performs S3 operations using standard AWS credential chain

#### 6.1 Credential Provider Script
- [x] Create `scripts/oidc_credential_provider.py`
  - [x] Config class loading from environment
  - [x] OidcCredentialProvider class with token/credential caching
  - [x] `get-credentials` command for AWS SDK credential_process (recommended)
  - [x] `credential-daemon` mode for writing credential files
  - [x] `token-daemon` mode for Auth0 web identity (Auth0 only)

#### 6.2 S3 Operations Script
- [x] Create `scripts/s3_ops.py`
  - [x] Uses standard AWS credential chain (environment, config files, etc.)
  - [x] Upload, download, list, delete commands
  - [x] CLI interface with argparse

#### 6.3 Additional Files
- [x] Create `scripts/requirements.txt`
  ```
  boto3>=1.28.0
  requests>=2.28.0
  ```

- [x] Create `scripts/example.env` (Auth0 example)
- [x] Create `scripts/example-cognito.env` (Cognito example)

#### 6.4 Systemd Service (for token daemon)
- [x] Create `scripts/oidc-token-refresh.service`
  ```ini
  [Unit]
  Description=OIDC Token Refresh Daemon for AWS S3
  After=network.target

  [Service]
  Type=simple
  EnvironmentFile=/etc/oidc-s3/config.env
  ExecStart=/usr/bin/python3 /opt/oidc-s3/oidc_credential_provider.py token-daemon --token-file /var/run/oidc/token
  Restart=always
  RestartSec=10

  [Install]
  WantedBy=multi-user.target
  ```

#### 6.5 Log Shipper Integration (credential_process - Recommended)

For log shippers (Vector, Fluent Bit, etc.), the recommended approach is using AWS SDK's `credential_process`:

1. Create AWS config file (`/etc/oidc-s3/aws-config`):
   ```ini
   [profile oidc-s3]
   credential_process = /bin/bash -c 'source /etc/oidc-s3/config.env && python3 /opt/oidc-s3/oidc_credential_provider.py get-credentials'
   region = eu-west-1
   ```

2. Set environment variables:
   ```bash
   export AWS_CONFIG_FILE=/etc/oidc-s3/aws-config
   export AWS_PROFILE=oidc-s3
   ```

This enables automatic credential refresh without restarting the log shipper.

---

### Phase 7: Testing & Validation

#### 7.1 Foundation Layer
- [x] Run `terraform init` with dev backend config
- [x] Run `terraform plan` and review
- [x] Run `terraform apply`
- [x] Verify Auth0 API created in dashboard
- [x] Verify AWS OIDC provider created
- [x] Verify S3 bucket created with correct settings

#### 7.2 Servers Layer
- [x] Run `terraform init` with dev backend config
- [x] Run `terraform plan` and review (requires foundation to be applied first)
- [x] Run `terraform apply`
- [x] Verify Auth0 M2M application created
- [x] Verify AWS IAM role created with correct trust policy
- [x] Get credentials from `terraform output`

#### 7.3 End-to-End Test
- [x] Configure Python script with credentials
- [x] Test OIDC token acquisition from Auth0
- [x] Test AWS credential exchange via STS
- [x] Test S3 upload
- [x] Test S3 download (if read-write permission)
- [x] Test S3 list (if full permission)
- [x] Test S3 delete (if full permission)
- [x] Test token daemon mode

#### 7.4 Log Shipper Integration Test
- [x] Start token daemon
- [x] Verify token file is created
- [ ] Configure Logstash/Vector/Fluent Bit (optional - depends on log shipper setup)
- [ ] Verify logs are shipped to S3 (optional - depends on log shipper setup)

---

### Phase 8: Documentation

- [x] Update CLAUDE.md with final commands
- [x] Create IMPLEMENTATION.md with:
  - [x] Auth0 and Cognito architecture comparison
  - [x] Explanation of Cognito `aud` claim limitation
  - [x] Credential vending pattern documentation
  - [x] Python client implementation details
- [x] Create INSTALL.md with:
  - [x] Prerequisites and setup instructions
  - [x] Deployment guides for both IdPs
  - [x] Client configuration examples
  - [x] Log shipper integration guide
- [x] Create terraform-cognito/README.md with Cognito-specific docs
- [x] Add inline comments to Terraform code
- [x] Add docstrings to Python code

---

## 3. File Inventory

### Terraform Files

| File | Purpose | Status |
|------|---------|--------|
| `terraform/foundation/main.tf` | Providers, backend | Done |
| `terraform/foundation/variables.tf` | Input variables | Done |
| `terraform/foundation/outputs.tf` | Output values | Done |
| `terraform/foundation/auth0.tf` | Auth0 API resource | Done |
| `terraform/foundation/aws-oidc-provider.tf` | AWS OIDC provider | Done |
| `terraform/foundation/s3.tf` | S3 bucket config | Done |
| `terraform/servers/main.tf` | Providers, backend, remote state | Done |
| `terraform/servers/variables.tf` | Input variables | Done |
| `terraform/servers/outputs.tf` | Output values | Done |
| `terraform/servers/servers.tf` | Server module calls | Done |
| `terraform/modules/server-access/main.tf` | Auth0 + IAM resources | Done |
| `terraform/modules/server-access/variables.tf` | Module inputs | Done |
| `terraform/modules/server-access/outputs.tf` | Module outputs | Done |
| `terraform-cognito/foundation/main.tf` | Cognito foundation providers | Done |
| `terraform-cognito/foundation/cognito.tf` | Cognito User Pool + Resource Server | Done |
| `terraform-cognito/foundation/credential-vending.tf` | API Gateway + Lambda + DynamoDB | Done |
| `terraform-cognito/foundation/s3.tf` | S3 bucket (can share with Auth0) | Done |
| `terraform-cognito/foundation/outputs.tf` | Foundation outputs | Done |
| `terraform-cognito/servers/main.tf` | Servers layer providers | Done |
| `terraform-cognito/servers/servers.tf` | Server module calls | Done |
| `terraform-cognito/servers/outputs.tf` | Server outputs | Done |
| `terraform-cognito/modules/server-access/main.tf` | Cognito client + IAM role + DynamoDB mapping | Done |
| `terraform-cognito/modules/server-access/variables.tf` | Module inputs | Done |
| `terraform-cognito/modules/server-access/outputs.tf` | Module outputs | Done |
| `terraform/environments/dev/backend.hcl` | Dev backend config | Done |
| `terraform/environments/dev/foundation.tfvars` | Dev foundation vars | Done |
| `terraform/environments/dev/servers.tfvars` | Dev servers vars | Done |
| `terraform/environments/prod/backend.hcl` | Prod backend config | Done |
| `terraform/environments/prod/foundation.tfvars` | Prod foundation vars | Done |
| `terraform/environments/prod/servers.tfvars` | Prod servers vars | Done |

### Script Files

| File | Purpose | Status |
|------|---------|--------|
| `scripts/oidc_credential_provider.py` | OIDC credential provider (get-credentials, daemons) | Done |
| `scripts/s3_ops.py` | S3 operations CLI (upload, download, list, delete) | Done |
| `scripts/requirements.txt` | Python dependencies | Done |
| `scripts/example.env` | Example Auth0 config | Done |
| `scripts/example-cognito.env` | Example Cognito config | Done |
| `scripts/oidc-token-refresh.service` | Systemd unit for token daemon | Done |

### Documentation Files

| File | Purpose | Status |
|------|---------|--------|
| `CLAUDE.md` | Claude Code guidance | Done |
| `SPEC.md` | Technical specification | Done |
| `DESIGN.md` | Implementation design | Done |
| `PROJECT.md` | Original notes | Done |
| `IMPLEMENTATION.md` | Technical implementation details | Done |
| `INSTALL.md` | Installation and usage guide | Done |
| `terraform-cognito/README.md` | Cognito-specific documentation | Done |

---

## 4. Dependency Order

### 4.1 Auth0 Path

```
1. Prerequisites (manual)
   ├── AWS account setup
   ├── Auth0 tenant setup
   ├── Auth0 Management API app (manual)
   └── Terraform state backend (manual/bootstrap)

2. Foundation Layer
   ├── Auth0 API resource
   ├── AWS OIDC provider (depends on Auth0 API)
   └── S3 bucket

3. Servers Layer (depends on Foundation)
   ├── Auth0 M2M applications
   └── AWS IAM roles

4. Client Configuration (depends on Servers)
   ├── Python script with credentials
   └── Log shipper configuration

5. Testing
   └── End-to-end validation
```

### 4.2 AWS Cognito Path (Alternative)

**Note:** Cognito uses a credential vending API because M2M tokens lack the `aud` claim required by STS.

```
1. Prerequisites (manual)
   ├── AWS account setup
   └── Terraform state backend (manual/bootstrap)
   (No IdP setup needed - Cognito is managed by Terraform)

2. Foundation Layer (terraform-cognito/foundation/)
   ├── Cognito User Pool + Domain + Resource Server
   ├── Credential Vending API (API Gateway + Lambda)
   ├── DynamoDB table for client-role mappings
   └── S3 bucket (can share with Auth0)

3. Servers Layer (terraform-cognito/servers/)
   ├── Cognito App Clients (M2M)
   ├── AWS IAM roles (trust Lambda, not OIDC provider)
   └── DynamoDB items (client-role mappings)

4. Client Configuration (depends on Servers)
   ├── Python script with IDP_TYPE=cognito
   └── Log shipper with credential-daemon sidecar

5. Testing
   └── End-to-end validation
```

---

## 5. Sensitive Data Handling

### Terraform Variables

- Auth0 Management API credentials: Pass via `TF_VAR_` environment variables or `-var` flags, never commit to tfvars files
- Server client secrets: Marked as `sensitive = true` in outputs
- Cognito client secrets: Also marked as `sensitive = true`, managed by AWS

### Server Configuration

- Auth0/Cognito client secrets: Store in secure secrets manager or encrypted files
- Never commit secrets to version control

### Example secure workflow (Auth0)

```bash
# Set sensitive vars via environment
export TF_VAR_auth0_client_id="xxx"
export TF_VAR_auth0_client_secret="xxx"

# Run terraform
terraform apply -var-file=../environments/dev/foundation.tfvars

# Get server secrets securely
terraform output -json server_secrets | jq -r '.["server-name"]' > /secure/location/secret
```

### Example secure workflow (Cognito)

```bash
# No IdP credentials needed - uses AWS credentials
# Run terraform
terraform apply -var-file=../environments/dev/foundation.tfvars

# Get Cognito client secrets
terraform output -json cognito_server_secrets | jq -r '.["server-name"]' > /secure/location/secret
```

---

## 6. Rollback Procedures

### Foundation Layer Rollback
```bash
cd terraform/foundation
terraform destroy -var-file=../environments/dev/foundation.tfvars
```
**Warning**: This will delete the S3 bucket (data loss if not empty) and break all servers.

### Single Server Removal
```bash
# Edit servers.tfvars to remove the server
cd terraform/servers
terraform apply -var-file=../environments/dev/servers.tfvars
```

### Complete Environment Teardown
```bash
# 1. Destroy servers first
cd terraform/servers
terraform destroy -var-file=../environments/dev/servers.tfvars

# 2. Empty S3 bucket (if needed)
aws s3 rm s3://oidc-s3-dev-uploads --recursive

# 3. Destroy foundation
cd terraform/foundation
terraform destroy -var-file=../environments/dev/foundation.tfvars
```
