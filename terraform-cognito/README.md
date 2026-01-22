# AWS Cognito-based OIDC S3 Uploader

This directory contains Terraform configuration for deploying the OIDC S3 Uploader using **AWS Cognito** as the identity provider instead of Auth0.

## Architecture

```
On-Prem Server → Cognito (access token) → Credential Vending API → AWS Creds → S3
```

**Key difference from Auth0:** Cognito M2M tokens cannot be used directly with `AssumeRoleWithWebIdentity`. Instead, we use a credential vending API (API Gateway + Lambda) that validates tokens and returns short-lived AWS credentials.

### Why Credential Vending?

AWS Cognito M2M access tokens:
- Do NOT include an `aud` claim by default (required by STS)
- Pre-token-generation Lambda triggers don't reliably work for `client_credentials` flows
- AWS has not yet exposed the M2M "quick-start" API feature via Terraform/CLI

The credential vending pattern is the recommended approach for Cognito M2M:
1. Client authenticates with Cognito to get an access token
2. Client sends the token to the credential vending API
3. Lambda validates the token (issuer, expiration, client_id)
4. Lambda looks up the client's IAM role from DynamoDB
5. Lambda calls STS AssumeRole and returns credentials to the client

## Key Differences from Auth0

| Aspect | Auth0 | AWS Cognito |
|--------|-------|-------------|
| Terraform providers | AWS + Auth0 | AWS only |
| Manual setup | Auth0 Management API app | None |
| Token endpoint | `https://{domain}/oauth/token` | `https://{domain}.auth.{region}.amazoncognito.com/oauth2/token` |
| Auth method | JSON body | Basic auth header |
| `sub` claim format | `{client_id}@clients` | App client ID directly |
| AWS credential exchange | `AssumeRoleWithWebIdentity` | Credential vending API |
| Token refresh daemon | Supported | Not supported (use API directly) |

## Cognito M2M Access Token Structure

When using the client_credentials grant, Cognito issues access tokens with these claims:

```json
{
  "sub": "1abc2defg3hij4klmno5pqrs6",      // App client ID
  "iss": "https://cognito-idp.{region}.amazonaws.com/{pool_id}",
  "client_id": "1abc2defg3hij4klmno5pqrs6", // Same as sub
  "token_use": "access",
  "scope": "https://s3-uploader.dev.oidc-s3/write https://s3-uploader.dev.oidc-s3/read",
  "exp": 1697235043,
  "iat": 1697231443
}
```

**Note:** The `aud` claim is NOT present in Cognito M2M tokens by default, which is why we cannot use `AssumeRoleWithWebIdentity` directly.

## Directory Structure

```
terraform-cognito/
├── foundation/              # Cognito User Pool, Resource Server, Credential Vending API, S3
│   ├── main.tf
│   ├── variables.tf
│   ├── cognito.tf
│   ├── credential-vending.tf  # API Gateway + Lambda for credential vending
│   ├── s3.tf
│   └── outputs.tf
├── servers/                 # Server onboarding (Cognito app clients + IAM roles)
│   ├── main.tf
│   ├── variables.tf
│   ├── servers.tf
│   └── outputs.tf
├── modules/
│   └── server-access/       # Reusable module per server
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── environments/
    ├── dev/
    │   ├── backend.hcl
    │   ├── servers-backend.hcl
    │   ├── foundation.tfvars
    │   └── servers.tfvars
    └── prod/
        └── ...
```

## Deployment

### Prerequisites

1. AWS credentials configured with permissions for:
   - `cognito-idp:*` (Cognito User Pool management)
   - `iam:*` (IAM role management)
   - `s3:*` (S3 bucket management)
   - `lambda:*` (Lambda function management)
   - `apigateway:*` (API Gateway management)
   - `dynamodb:*` (DynamoDB table management)

2. Terraform state backend (S3 + DynamoDB) - shared with Auth0 deployment

### Deploy Foundation Layer

```bash
cd terraform-cognito/foundation
terraform init -backend-config=../environments/dev/backend.hcl
terraform plan -var-file=../environments/dev/foundation.tfvars
terraform apply -var-file=../environments/dev/foundation.tfvars
```

### Deploy Servers Layer

```bash
cd terraform-cognito/servers
terraform init -backend-config=../environments/dev/servers-backend.hcl
terraform plan -var-file=../environments/dev/servers.tfvars
terraform apply -var-file=../environments/dev/servers.tfvars
```

### Get Server Credentials

```bash
# Get all configuration (non-sensitive)
terraform output -json server_configurations

# Get client secrets
terraform output -json server_secrets
```

## Adding a New Server

1. Edit `environments/dev/servers.tfvars`:

```hcl
servers = {
  "my-new-server" = {
    s3_path_prefix = "my-data/"
    s3_permissions = "write"  # or "read-write" or "full"
  }
}
```

2. Apply:

```bash
terraform apply -var-file=../environments/dev/servers.tfvars
```

## Using with Python Client

Set these environment variables:

```bash
# Identity provider
export IDP_TYPE="cognito"

# Cognito configuration
export COGNITO_DOMAIN="oidc-s3-dev-123456789012"
export COGNITO_CLIENT_ID="xxx"
export COGNITO_CLIENT_SECRET="xxx"
export COGNITO_RESOURCE_SERVER="https://s3-uploader.dev.oidc-s3"
export COGNITO_CREDENTIAL_API_URL="https://xxx.execute-api.eu-west-1.amazonaws.com/credentials"

# S3 configuration
export AWS_REGION="eu-west-1"
export S3_BUCKET="oidc-s3-cognito-dev-uploads"
export S3_PATH_PREFIX="my-data/"

# Run the uploader
python scripts/s3_uploader.py upload /path/to/file.txt
```

**Note:** The `AWS_ROLE_ARN` environment variable is NOT needed for Cognito - the credential vending API handles role assumption based on the client ID.

## How It Works

1. **Token Request**: Client sends credentials to Cognito token endpoint
2. **Token Validation**: Credential vending Lambda validates the token:
   - Checks issuer matches Cognito User Pool
   - Checks `token_use` is "access"
   - Checks token is not expired
3. **Role Lookup**: Lambda looks up the client's IAM role from DynamoDB
4. **Credential Vending**: Lambda calls STS AssumeRole and returns credentials
5. **S3 Access**: Client uses credentials to access S3

## Sharing S3 Bucket with Auth0 Deployment

To use the same S3 bucket as the Auth0-based deployment:

```hcl
# In foundation.tfvars
create_s3_bucket     = false
existing_bucket_name = "oidc-s3-dev-uploads"
```

## Cleanup

```bash
# Destroy servers first
cd terraform-cognito/servers
terraform destroy -var-file=../environments/dev/servers.tfvars

# Empty S3 bucket if needed
aws s3 rm s3://oidc-s3-cognito-dev-uploads --recursive

# Destroy foundation
cd terraform-cognito/foundation
terraform destroy -var-file=../environments/dev/foundation.tfvars
```
