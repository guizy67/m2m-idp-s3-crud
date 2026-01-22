# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-code project for credential-free S3 uploads from on-premises servers using OIDC federation with Auth0. Terraform manages both Auth0 M2M applications and AWS IAM roles automatically.

## Architecture

```
On-Prem Server → Auth0 (OIDC token) → AWS STS (AssumeRoleWithWebIdentity) → S3
```

**Terraform Layers**:
- **Foundation** (rare changes): Auth0 API, AWS OIDC provider, S3 bucket
- **Servers** (frequent changes): Per-server Auth0 M2M app + AWS IAM role

Adding a server = one entry in `servers.tfvars` → Terraform creates both Auth0 app and AWS role.

## Key Files

- `SPEC.md` - Complete technical specification
- `INSTALL.md` - Installation and usage guide
- `scripts/oidc_credential_provider.py` - OIDC credential provider (token/credential management)
- `scripts/s3_ops.py` - S3 operations CLI (upload, download, list, delete)
- `terraform/foundation/` - Foundation layer (Auth0 API, OIDC provider, S3)
- `terraform/servers/` - Server onboarding layer
- `terraform/modules/server-access/` - Reusable module per server
- `terraform-cognito/` - Alternative Cognito-based infrastructure

## Commands

```bash
# Deploy foundation (once per environment)
cd terraform/foundation
terraform init -backend-config=../environments/dev/backend.hcl
terraform apply -var-file=../environments/dev/foundation.tfvars

# Deploy/update servers
cd terraform/servers
terraform init -backend-config=../environments/dev/backend.hcl
terraform apply -var-file=../environments/dev/servers.tfvars

# Get server credentials
terraform output -json server_configurations
terraform output -json server_secrets

# Python client
pip install boto3 requests

# S3 operations (uses standard AWS credential chain)
python scripts/s3_ops.py upload /path/to/file.txt
python scripts/s3_ops.py list
python scripts/s3_ops.py download path/file.txt /tmp/file.txt

# Credential provider modes
python scripts/oidc_credential_provider.py get-credentials          # For credential_process
python scripts/oidc_credential_provider.py credential-daemon        # Write credentials to files
python scripts/oidc_credential_provider.py token-daemon             # Auth0 only: write OIDC token
```

## Environment Variables (Python Client)

```bash
AUTH0_DOMAIN=your-tenant.auth0.com
AUTH0_CLIENT_ID=xxx
AUTH0_CLIENT_SECRET=xxx
AUTH0_AUDIENCE=https://s3-uploader.dev.example.com
AWS_ROLE_ARN=arn:aws:iam::123456789012:role/oidc-s3-dev-server-name
AWS_REGION=eu-west-1
S3_BUCKET=oidc-s3-dev-uploads
S3_PATH_PREFIX=backups/server-01/
```

## Auth0 Configuration

- Auth0 `sub` claim format: `{client_id}@clients`
- Auth0 issuer URL has trailing slash: `https://domain.auth0.com/`
- AWS OIDC provider `client-id-list` = Auth0 API Identifier (audience)

## S3 Permission Levels

- `write`: PutObject only
- `read-write`: PutObject + GetObject
- `full`: PutObject + GetObject + DeleteObject + ListBucket

## Log Shipper Integration

Recommended: Use `credential_process` for automatic credential refresh.

1. Create AWS config file with `credential_process` pointing to `oidc_credential_provider.py get-credentials`
2. Set `AWS_CONFIG_FILE` and `AWS_PROFILE=oidc-s3` for the log shipper
3. AWS SDK calls the script automatically when credentials expire

Alternative for Auth0: Use `token-daemon` with `AWS_WEB_IDENTITY_TOKEN_FILE`.
