# IMPLEMENTATION.md - Technical Implementation Details

This document describes the final implementations for the OIDC AWS S3 Uploader, covering both Auth0 and AWS Cognito as identity providers.

## Overview

This project enables credential-free S3 uploads from on-premises servers using OIDC (OpenID Connect) federation. Two identity provider options are supported:

| Feature | Auth0 | AWS Cognito |
|---------|-------|-------------|
| AWS Credential Exchange | Direct STS `AssumeRoleWithWebIdentity` | Credential Vending API (Lambda) |
| External Account | Required (Auth0 tenant) | None (AWS-native) |
| Terraform Providers | AWS + Auth0 | AWS only |
| Token Daemon | Supported | Not supported |
| Credential Daemon | Supported | Supported (required) |

## Architecture Comparison

### Auth0 Architecture (Direct STS)

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│                 │     │                 │     │                 │
│   On-Prem       │────▶│     Auth0       │     │   AWS STS       │
│   Server        │  1  │   (get token)   │     │                 │
│                 │     │                 │     │                 │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                                               │
        │                       2                       │
        └──────────────────────────────────────────────▶│
        │                                               │
        │◀──────────────────────────────────────────────┘
        │                       3
        │               ┌─────────────────┐
        │               │                 │
        └──────────────▶│      S3         │
                    4   │                 │
                        └─────────────────┘
```

1. Server requests OIDC token from Auth0 (client_credentials grant)
2. Server calls STS `AssumeRoleWithWebIdentity` with the token
3. STS validates token, returns temporary AWS credentials
4. Server uses credentials to upload to S3

**Why this works with Auth0:** Auth0 access tokens include an `aud` (audience) claim that AWS STS requires for OIDC federation.

### AWS Cognito Architecture (Credential Vending)

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│                 │     │                 │     │  API Gateway    │
│   On-Prem       │────▶│    Cognito      │────▶│  + Lambda       │
│   Server        │  1  │   (get token)   │  2  │  (validate +    │
│                 │     │                 │     │   vend creds)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                                               │
        │◀──────────────────────────────────────────────┘
        │                       3
        │               ┌─────────────────┐
        │               │                 │
        └──────────────▶│      S3         │
                    4   │                 │
                        └─────────────────┘
```

1. Server requests OIDC token from Cognito (client_credentials grant)
2. Server sends token to credential vending API
3. Lambda validates token, looks up role in DynamoDB, calls STS AssumeRole, returns credentials
4. Server uses credentials to upload to S3

## Why Cognito Requires Credential Vending

AWS Cognito M2M (Machine-to-Machine) tokens **cannot** be used directly with STS `AssumeRoleWithWebIdentity`. This is a known limitation:

### The `aud` Claim Problem

AWS STS requires the `aud` (audience) claim to validate OIDC tokens. Here's what each IdP provides:

**Auth0 Access Token:**
```json
{
  "iss": "https://your-tenant.auth0.com/",
  "sub": "abc123@clients",
  "aud": "https://s3-uploader.dev.example.com",  // ← Present
  "iat": 1697231443,
  "exp": 1697317843,
  "scope": "upload"
}
```

**Cognito M2M Access Token:**
```json
{
  "iss": "https://cognito-idp.eu-west-1.amazonaws.com/eu-west-1_abc123",
  "sub": "1abc2defg3hij4klmno5pqrs6",
  "client_id": "1abc2defg3hij4klmno5pqrs6",
  "token_use": "access",
  "scope": "https://s3-uploader.dev.oidc-s3/write",
  "iat": 1697231443,
  "exp": 1697235043
  // ← NO "aud" claim!
}
```

### Why Cognito Tokens Lack `aud`

1. **By Design:** Cognito M2M tokens for the `client_credentials` grant use `scope` instead of `aud`
2. **Pre-token Lambda Limitation:** Lambda triggers don't reliably fire for `client_credentials` flows
3. **No API Feature:** AWS hasn't exposed the M2M "quick-start" feature (which adds `aud`) via Terraform/CLI

### The Credential Vending Solution

Instead of relying on STS OIDC federation, we:

1. **Validate tokens ourselves** in a Lambda function:
   - Verify issuer matches Cognito User Pool
   - Check `token_use` is "access"
   - Check token is not expired

2. **Map clients to roles** using DynamoDB:
   - Key: Cognito `client_id`
   - Value: IAM role ARN for that client

3. **Use STS AssumeRole** (not AssumeRoleWithWebIdentity):
   - Lambda has permission to assume server roles
   - Server roles trust the Lambda execution role

This pattern is the **recommended approach** for Cognito M2M authentication with AWS services.

---

## Terraform Implementation

### Directory Structure

```
terraform/                    # Auth0 implementation
├── foundation/              # Auth0 API, OIDC provider, S3
├── servers/                 # Per-server Auth0 app + IAM role
├── modules/server-access/   # Reusable module
└── environments/            # dev/prod tfvars

terraform-cognito/           # Cognito implementation
├── foundation/              # Cognito User Pool, credential vending, S3
├── servers/                 # Per-server Cognito client + IAM role
├── modules/server-access/   # Reusable module
└── environments/            # dev/prod tfvars
```

### Auth0 Foundation Layer

Key resources in `terraform/foundation/`:

- **auth0.tf**: Auth0 Resource Server (API) with audience identifier
- **aws-oidc-provider.tf**: AWS IAM OIDC Provider trusting Auth0
- **s3.tf**: S3 bucket with encryption, versioning, lifecycle policies

### Auth0 Server Module

Key resources in `terraform/modules/server-access/`:

```hcl
# Auth0 M2M Application
resource "auth0_client" "server" {
  name     = "${var.server_name}-${var.environment}"
  app_type = "non_interactive"  # M2M
}

# Grant to API
resource "auth0_client_grant" "server" {
  client_id = auth0_client.server.id
  audience  = var.audience
  scopes    = ["upload"]
}

# IAM Role with OIDC Trust
resource "aws_iam_role" "server" {
  assume_role_policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:aud" = var.audience
          "${var.oidc_provider_url}:sub" = "${auth0_client.server.client_id}@clients"
        }
      }
    }]
  })
}
```

### Cognito Foundation Layer

Key resources in `terraform-cognito/foundation/`:

- **cognito.tf**: User Pool, Domain, Resource Server with scopes
- **credential-vending.tf**: API Gateway + Lambda + DynamoDB
- **s3.tf**: S3 bucket (can share with Auth0 deployment)

The credential vending Lambda validates tokens and vends credentials:

```python
# Lambda pseudocode
def handler(event):
    token = event["body"]["access_token"]

    # Validate token (issuer, expiration, token_use)
    claims = validate_token(token)

    # Look up role for this client
    role_arn = dynamodb.get_item(client_id=claims["client_id"])

    # Assume role and return credentials
    creds = sts.assume_role(RoleArn=role_arn)
    return {"credentials": creds}
```

### Cognito Server Module

Key resources in `terraform-cognito/modules/server-access/`:

```hcl
# Cognito App Client
resource "aws_cognito_user_pool_client" "server" {
  name                         = "${var.server_name}-${var.environment}"
  user_pool_id                 = var.cognito_user_pool_id
  generate_secret              = true
  allowed_oauth_flows          = ["client_credentials"]
  allowed_oauth_scopes         = ["${var.resource_server_identifier}/write"]
  allowed_oauth_flows_user_pool_client = true
}

# IAM Role trusting Lambda (not OIDC provider)
resource "aws_iam_role" "server" {
  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.credential_vending_lambda_role_arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Register client-role mapping in DynamoDB
resource "aws_dynamodb_table_item" "client_role_mapping" {
  table_name = var.client_roles_table_name
  hash_key   = "client_id"
  item = jsonencode({
    client_id      = { S = aws_cognito_user_pool_client.server.id }
    role_arn       = { S = aws_iam_role.server.arn }
    server_name    = { S = var.server_name }
    s3_path_prefix = { S = var.s3_path_prefix }
  })
}
```

---

## Python Client Implementation

The Python client is split into two focused scripts:

| Script | Purpose |
|--------|---------|
| `scripts/oidc_credential_provider.py` | OIDC authentication and AWS credential management |
| `scripts/s3_ops.py` | S3 operations using standard AWS credential chain |

### Design Principles

1. **Separation of Concerns**: Credential management is separate from S3 operations
2. **Standard AWS Integration**: S3 operations use the standard AWS SDK credential chain
3. **Automatic Caching**: Tokens and credentials are cached and refreshed 5 minutes before expiry
4. **Atomic File Writes**: Credential files are written atomically to prevent partial reads
5. **credential_process Support**: Recommended approach for log shippers with automatic refresh

### Configuration

Set `IDP_TYPE` environment variable to select the identity provider:

| Variable | Auth0 | Cognito |
|----------|-------|---------|
| `IDP_TYPE` | `auth0` (default) | `cognito` |
| Domain | `AUTH0_DOMAIN` | `COGNITO_DOMAIN` |
| Client ID | `AUTH0_CLIENT_ID` | `COGNITO_CLIENT_ID` |
| Client Secret | `AUTH0_CLIENT_SECRET` | `COGNITO_CLIENT_SECRET` |
| Audience/Resource | `AUTH0_AUDIENCE` | `COGNITO_RESOURCE_SERVER` |
| Role ARN | `AWS_ROLE_ARN` | Not needed |
| Credential API | Not needed | `COGNITO_CREDENTIAL_API_URL` |

### Credential Provider Commands

```bash
# Get credentials for AWS SDK credential_process (RECOMMENDED)
python oidc_credential_provider.py get-credentials

# Token daemon (Auth0 only) - writes OIDC token file
python oidc_credential_provider.py token-daemon --token-file /var/run/oidc/token

# Credential daemon (both) - writes AWS credential files
python oidc_credential_provider.py credential-daemon --creds-dir /var/run/aws-creds
```

### S3 Operations Commands

```bash
# Upload a file
python s3_ops.py upload /path/to/file.txt

# Upload with custom S3 key
python s3_ops.py upload /path/to/file.txt --key custom/path/file.txt

# Download a file
python s3_ops.py download backups/file.txt /tmp/file.txt

# List objects
python s3_ops.py list
python s3_ops.py list --prefix custom/path/

# Delete an object
python s3_ops.py delete backups/file.txt
```

### Log Shipper Integration

#### credential_process (Recommended)

The recommended approach for log shippers (Vector, Fluent Bit, etc.) is using AWS SDK's `credential_process`. This enables automatic credential refresh without restarting the log shipper.

1. Create AWS config file (`/etc/oidc-s3/aws-config`):

```ini
[profile oidc-s3]
credential_process = /bin/bash -c 'source /etc/oidc-s3/config.env && python3 /opt/oidc-s3/oidc_credential_provider.py get-credentials'
region = eu-west-1
```

2. Set environment variables for your log shipper:

```bash
export AWS_CONFIG_FILE=/etc/oidc-s3/aws-config
export AWS_PROFILE=oidc-s3
```

The AWS SDK calls `get-credentials` automatically when credentials expire.

#### Token Daemon (Auth0 Only)

Writes the OIDC token to a file for log shippers that support `AWS_WEB_IDENTITY_TOKEN_FILE`:

```bash
python oidc_credential_provider.py token-daemon --token-file /var/run/oidc/token
```

Log shipper configuration:

```bash
export AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/oidc/token
export AWS_ROLE_ARN=arn:aws:iam::123456789012:role/oidc-s3-dev-server
```

#### Credential Daemon (Legacy)

Writes AWS credentials to files periodically. Note: Most applications cache credentials in memory and won't detect file changes, requiring a restart when credentials expire. **Use credential_process instead.**

```bash
python oidc_credential_provider.py credential-daemon --creds-dir /var/run/aws-creds
```

Creates three files:

- `aws-credentials.env` - Shell-sourceable environment variables
- `aws-credentials.json` - JSON format for programmatic access
- `credentials` - AWS SDK credentials file format

Log shipper configuration:

```bash
export AWS_SHARED_CREDENTIALS_FILE=/var/run/aws-creds/credentials
```

---

## S3 Permission Levels

Both implementations support the same permission levels:

| Level | S3 Actions | Use Case |
|-------|------------|----------|
| `write` | `s3:PutObject` | Upload-only (logs, backups) |
| `read-write` | `s3:PutObject`, `s3:GetObject` | Upload and retrieve |
| `full` | `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:ListBucket` | Full management |

Permissions are enforced at the IAM level with path prefix restrictions:

```hcl
# Example: write permission to backups/server-01/*
resource "aws_iam_role_policy" "s3_access" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "arn:aws:s3:::bucket-name/backups/server-01/*"
    }]
  })
}
```

---

## Security Considerations

### Token Validation

- **Auth0**: AWS STS validates token signature, issuer, audience, and expiration
- **Cognito**: Credential vending Lambda validates issuer, `token_use`, and expiration

### Credential Lifetime

| Credential Type | Default Lifetime | Refresh Buffer |
|-----------------|------------------|----------------|
| Auth0 OIDC Token | 24 hours | 5 minutes |
| Cognito OIDC Token | 1 hour | 5 minutes |
| AWS STS Credentials | 1 hour | 5 minutes |

### IAM Trust Policies

- **Auth0**: Role trusts OIDC provider with `aud` and `sub` conditions
- **Cognito**: Role trusts credential vending Lambda (not OIDC provider)

### Secrets Management

- Client secrets should be stored in secure secrets managers
- Never commit secrets to version control
- Terraform outputs are marked as `sensitive = true`

---

## Troubleshooting

### Auth0: "Invalid audience" error

Ensure the Auth0 API identifier matches `AWS_ROLE_ARN`'s trust policy conditions.

### Auth0: "Invalid subject" error

Check that the Auth0 M2M app client ID matches the expected format: `{client_id}@clients`

### Cognito: "Missing a required claim: aud"

This error occurs when trying to use Cognito tokens directly with STS. Use the credential vending API instead (set `IDP_TYPE=cognito`).

### Cognito: "Access Denied" from credential vending API

1. Check the client is registered in DynamoDB
2. Verify token is not expired
3. Check Lambda has permission to assume the target role

### Both: "Credentials expired" during upload

The credential daemon may have stopped. Restart it and ensure the refresh interval is shorter than the credential lifetime.
