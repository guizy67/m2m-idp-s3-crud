# OIDC S3 Uploader

Credential-free S3 uploads from on-premises servers using OIDC federation with Auth0 or AWS Cognito. No long-lived AWS access keys required.

## How It Works

```text
On-Prem Server → Identity Provider (OIDC token) → AWS STS → S3
```

1. Server authenticates to Auth0 or Cognito using client credentials (M2M flow)
2. Server exchanges the OIDC token for temporary AWS credentials via STS
3. Server uploads to S3 using the temporary credentials

Terraform manages both the identity provider configuration and AWS IAM roles automatically.

## Features

- **No static AWS credentials** - Uses OIDC federation for temporary credentials
- **Least privilege** - Each server gets its own IAM role scoped to a specific S3 path
- **Easy onboarding** - Add a server with one entry in `servers.tfvars`
- **Automated management** - Terraform creates both IdP app and AWS role together
- **Multiple permission levels** - `write`, `read-write`, or `full` S3 access

## Identity Provider Options

| Feature                  | Auth0                              | Entra ID                           | AWS Cognito                    |
|--------------------------|------------------------------------|------------------------------------|--------------------------------|
| External account needed  | Yes                                | Yes (Azure AD)                     | No (AWS-native)                |
| STS integration          | Direct `AssumeRoleWithWebIdentity` | Direct `AssumeRoleWithWebIdentity` | Credential vending API         |
| Token daemon support     | Yes                                | Yes                                | No (use credential_process)    |
| Terraform provider       | `auth0/auth0`                      | `hashicorp/azuread`                | `hashicorp/aws`                |
| `sub` claim format       | `{client_id}@clients`              | Service Principal Object ID        | App client UUID                |
| Implemented in project   | Yes                                | No (same pattern as Auth0)         | Yes                            |

### Entra ID (Azure AD)

Entra ID follows the same direct STS federation pattern as Auth0. Key differences:

- **Token endpoint**: `/oauth2/v2.0/token` (vs Auth0's `/oauth/token`)
- **Audience config**: Set via "Expose an API" → Application ID URI (e.g., `api://aws-s3-uploader`)
- **`sub` claim**: Uses the Service Principal Object ID (found in Enterprise Applications, not the App Registration)
- **SDK**: MSAL recommended for token acquisition
- **Issuer URL**: `https://login.microsoftonline.com/{tenant_id}/v2.0` (no trailing slash, unlike Auth0)

To adapt this project for Entra ID, replace the Auth0 Terraform resources with `azuread` provider resources and update the Python client to use MSAL for token acquisition.

## Quick Start

```bash
# 1. Deploy foundation (once per environment)
cd terraform/foundation  # or terraform-cognito/foundation
terraform init -backend-config=../environments/dev/backend.hcl
terraform apply -var-file=../environments/dev/foundation.tfvars

# 2. Add servers to servers.tfvars, then deploy
cd ../servers
terraform apply -var-file=../environments/dev/servers.tfvars

# 3. Get credentials for server configuration
terraform output -json server_configurations
terraform output -json server_secrets
```

## Python Client

```bash
pip install boto3 requests

# Upload a file
python scripts/s3_ops.py upload /path/to/file.txt

# List objects
python scripts/s3_ops.py list

# Get credentials for AWS SDK credential_process (recommended for log shippers)
python scripts/oidc_credential_provider.py get-credentials
```

## Documentation

| Document                                                   | Description                        |
|------------------------------------------------------------|------------------------------------|
| [SPEC.md](SPEC.md)                                         | Complete technical specification   |
| [DESIGN.md](DESIGN.md)                                     | Implementation design and task list|
| [IMPLEMENTATION.md](IMPLEMENTATION.md)                     | Technical implementation details   |
| [INSTALL.md](INSTALL.md)                                   | Installation and usage guide       |
| [CLAUDE.md](CLAUDE.md)                                     | Claude Code project guidance       |
| [terraform-cognito/README.md](terraform-cognito/README.md) | Cognito-specific documentation     |

## Project Structure

```text
terraform/                    # Auth0 implementation
├── foundation/              # Auth0 API, OIDC provider, S3 bucket
├── servers/                 # Per-server Auth0 app + IAM role
└── modules/server-access/   # Reusable module

terraform-cognito/           # Cognito implementation
├── foundation/              # Cognito User Pool, credential vending API, S3
├── servers/                 # Per-server Cognito client + IAM role
└── modules/server-access/   # Reusable module

scripts/
├── oidc_credential_provider.py  # OIDC auth and AWS credential management
└── s3_ops.py                    # S3 operations CLI
```

## License

MIT
