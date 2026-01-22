# OIDC AWS S3 Uploader - Terraform Deployment Specification

## Table of Contents

- [1. Overview](#1-overview)
- [2. Architecture](#2-architecture)
- [3. Terraform Project Structure](#3-terraform-project-structure)
- [4. Component Specifications](#4-component-specifications)
- [5. State Management](#5-state-management)
- [6. Provider Configuration](#6-provider-configuration)
- [7. Security Considerations](#7-security-considerations)
- [8. Deployment Workflow](#8-deployment-workflow)
- [9. Outputs for Server Configuration](#9-outputs-for-server-configuration)
- [10. Log Shipper Integration](#10-log-shipper-integration)
- [11. Python Client Example](#11-python-client-example)

## 1. Overview

This document specifies the Terraform-based infrastructure for deploying credential-free S3 uploads from on-premises servers using OIDC federation. The design prioritizes:

- **Separation of concerns**: Different components have different change frequencies
- **Scalability**: Easy onboarding of new servers/applications
- **Security**: Least-privilege access, no long-lived credentials

### 1.1 Key Decisions

| Decision | Choice |
|----------|--------|
| Identity Provider | Auth0, Entra ID, or **AWS Cognito** |
| IdP Management | Automated via Terraform (auth0/azuread/aws provider) |
| State Backend | S3 + DynamoDB |
| Environments | Dev + Prod |
| S3 Structure | Single bucket per environment |
| Dev S3 Config | No versioning, 10-day object expiration |
| Prod S3 Config | Versioning enabled, no expiration |
| Naming Convention | `{project}-{env}-{component}` |

### 1.2 IdP Comparison

| Aspect | Auth0 | Entra ID | AWS Cognito |
|--------|-------|----------|-------------|
| Best for | Multi-cloud, third-party IdP | Microsoft ecosystem | AWS-native, single provider |
| Terraform provider | `auth0/auth0` | `hashicorp/azuread` | `hashicorp/aws` |
| Token endpoint | `/oauth/token` | `/oauth2/v2.0/token` | `/oauth2/token` |
| `sub` claim format | `{client_id}@clients` | Service Principal Object ID | App client UUID |
| Issuer URL | Has trailing slash | No trailing slash | No trailing slash |
| STS Integration | Direct `AssumeRoleWithWebIdentity` | Direct `AssumeRoleWithWebIdentity` | **Credential vending API** (M2M tokens lack `aud` claim) |
| Cost | Per MAU/M2M token | Included with Azure AD | Free tier + pay per MAU |
| SDK needed | No (standard HTTP) | MSAL recommended | No (standard HTTP) |

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              TERRAFORM LAYERS                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ LAYER 0: Auth0 (Rare Changes)                                        │   │
│  │ ─────────────────────────────────────────────────────────────────── │   │
│  │ • Auth0 API definition (audience)                                    │   │
│  │ • M2M Applications created per-server in Layer 2                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                      │                                      │
│                                      ▼                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ LAYER 1: AWS Foundation (Rare Changes)                               │   │
│  │ ─────────────────────────────────────────────────────────────────── │   │
│  │ • AWS OIDC Identity Provider (trusts Auth0)                          │   │
│  │ • S3 bucket with lifecycle rules                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                      │                                      │
│                                      ▼                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ LAYER 2: Server Onboarding (Frequent Changes)                        │   │
│  │ ─────────────────────────────────────────────────────────────────── │   │
│  │ • Auth0 M2M Application (per server)                                 │   │
│  │ • AWS IAM Role with trust policy (per server)                        │   │
│  │ • S3 path-scoped permissions (per server)                            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Adding a New Server (Automated Flow)

```
1. Add server entry to servers.tfvars
                    │
                    ▼
2. terraform apply (servers layer)
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
3a. Auth0 M2M App         3b. AWS IAM Role
    created                   created
        │                       │
        └───────────┬───────────┘
                    ▼
4. Terraform outputs:
   - client_id, client_secret (for server config)
   - role_arn, bucket_name (for server config)
```

## 3. Terraform Project Structure

```
terraform/
├── foundation/                    # Layer 0 + 1: Rarely changes
│   ├── main.tf                   # Provider configs, backend
│   ├── variables.tf
│   ├── outputs.tf
│   ├── auth0.tf                  # Auth0 API definition
│   ├── aws-oidc-provider.tf      # AWS OIDC provider trusting Auth0
│   └── s3.tf                     # S3 bucket with lifecycle rules
│
├── servers/                       # Layer 2: Frequently changes
│   ├── main.tf                   # Provider configs, backend, remote state
│   ├── variables.tf
│   ├── outputs.tf
│   └── servers.tf                # Server definitions (uses module)
│
├── modules/
│   └── server-access/            # Reusable module for each server
│       ├── main.tf               # Auth0 M2M app + AWS IAM role
│       ├── variables.tf
│       └── outputs.tf
│
└── environments/
    ├── dev/
    │   ├── foundation.tfvars
    │   ├── servers.tfvars
    │   └── backend.hcl           # Backend config for dev
    └── prod/
        ├── foundation.tfvars
        ├── servers.tfvars
        └── backend.hcl           # Backend config for prod
```

## 4. Component Specifications

### 4.1 Foundation Layer

**Lifecycle**: Created once per environment, rarely modified

#### 4.1.1 Auth0 API Definition

```hcl
# foundation/auth0.tf

resource "auth0_resource_server" "s3_uploader" {
  name        = "oidc-s3-${var.environment}"
  identifier  = "https://s3-uploader.${var.environment}.example.com"

  # No scopes needed for M2M client credentials flow
  # Token lifetime (24 hours default is fine)
  token_lifetime = 86400
}
```

**Auth0 Provider URL**: `https://{domain}.auth0.com/` (note trailing slash)

#### 4.1.1b AWS Cognito User Pool (Alternative to Auth0)

AWS Cognito provides AWS-native identity management, eliminating the need for external IdP accounts. However, **Cognito M2M tokens cannot be used directly with `AssumeRoleWithWebIdentity`** because they lack the `aud` (audience) claim required by AWS STS.

**The Credential Vending Pattern**: Instead of direct STS federation, Cognito uses a credential vending API:

```text
Client → Cognito (get token) → Credential Vending API (Lambda) → STS AssumeRole → S3
```

The Lambda validates tokens, looks up the client's IAM role in DynamoDB, and returns temporary AWS credentials.

```hcl
# foundation/cognito.tf

resource "aws_cognito_user_pool" "s3_uploader" {
  name = "oidc-s3-${var.environment}"

  # Disable user self-registration (M2M only)
  admin_create_user_config {
    allow_admin_create_user_only = true
  }
}

resource "aws_cognito_user_pool_domain" "s3_uploader" {
  domain       = "oidc-s3-${var.environment}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.s3_uploader.id
}

resource "aws_cognito_resource_server" "s3_uploader" {
  identifier   = "https://s3-uploader.${var.environment}.example.com"
  name         = "S3 Uploader API"
  user_pool_id = aws_cognito_user_pool.s3_uploader.id

  # Scopes are required for client_credentials flow in Cognito
  scope {
    scope_name        = "write"
    scope_description = "Upload files to S3"
  }
  scope {
    scope_name        = "read"
    scope_description = "Download files from S3"
  }
}

# Credential Vending API (API Gateway + Lambda + DynamoDB)
# See terraform-cognito/foundation/credential-vending.tf for full implementation
```

**Why Cognito M2M Tokens Don't Work with STS:**

Cognito M2M access tokens look like this:

```json
{
  "iss": "https://cognito-idp.eu-west-1.amazonaws.com/eu-west-1_xxx",
  "sub": "1abc2defg3hij4klmno",
  "client_id": "1abc2defg3hij4klmno",
  "token_use": "access",
  "scope": "https://s3-uploader.dev/write"
  // NO "aud" claim!
}
```

AWS STS `AssumeRoleWithWebIdentity` requires the `aud` claim to validate tokens. Pre-token-generation Lambda triggers don't reliably fire for `client_credentials` flows, so we cannot add the claim.

**See [IMPLEMENTATION.md](IMPLEMENTATION.md) for full details on the credential vending pattern.**

#### 4.1.2 AWS OIDC Identity Provider

**For Auth0:**

```hcl
# foundation/aws-oidc-provider.tf

resource "aws_iam_openid_connect_provider" "auth0" {
  url             = "https://${var.auth0_domain}/"
  client_id_list  = [auth0_resource_server.s3_uploader.identifier]
  thumbprint_list = ["YOUR_AUTH0_THUMBPRINT"]  # AWS may auto-fetch
}
```

**For AWS Cognito:**

Cognito M2M does **not** use an AWS OIDC Identity Provider because the tokens lack the `aud` claim required by `AssumeRoleWithWebIdentity`. Instead, IAM roles trust the credential vending Lambda:

```hcl
# terraform-cognito/modules/server-access/main.tf

# IAM Role trusts the credential vending Lambda (NOT an OIDC provider)
resource "aws_iam_role" "server" {
  name = "oidc-s3-${var.environment}-${var.server_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.credential_vending_lambda_role_arn }
      Action    = "sts:AssumeRole"
    }]
  })
}
```

#### 4.1.3 S3 Bucket

```hcl
# foundation/s3.tf

resource "aws_s3_bucket" "uploads" {
  bucket = "oidc-s3-${var.environment}-uploads"
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = var.environment == "prod" ? "Enabled" : "Disabled"
  }
}

# Dev only: 10-day object expiration
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  count  = var.environment == "dev" ? 1 : 0
  bucket = aws_s3_bucket.uploads.id

  rule {
    id     = "expire-after-10-days"
    status = "Enabled"
    expiration {
      days = 10
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

#### 4.1.4 Foundation Outputs

```hcl
# foundation/outputs.tf

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.auth0.arn
}

output "oidc_provider_url" {
  # Without https:// prefix, for use in trust policy conditions
  value = "${var.auth0_domain}/"
}

output "audience" {
  value = auth0_resource_server.s3_uploader.identifier
}

output "auth0_api_id" {
  value = auth0_resource_server.s3_uploader.id
}

output "bucket_arn" {
  value = aws_s3_bucket.uploads.arn
}

output "bucket_name" {
  value = aws_s3_bucket.uploads.id
}

output "aws_region" {
  value = var.aws_region
}
```

### 4.2 Server Access Module

**Purpose**: Creates both Auth0 M2M application and AWS IAM role for one server

#### 4.2.1 Module Inputs

```hcl
# modules/server-access/variables.tf

variable "server_name" {
  description = "Unique identifier for the server (e.g., 'backup-server-01')"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string
}

variable "auth0_api_id" {
  description = "Auth0 API resource server ID (from foundation)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the AWS OIDC provider (from foundation)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the OIDC provider (without https://)"
  type        = string
}

variable "audience" {
  description = "Expected audience claim in the token"
  type        = string
}

variable "bucket_arn" {
  description = "ARN of the S3 bucket"
  type        = string
}

variable "bucket_name" {
  description = "Name of the S3 bucket (for ListBucket)"
  type        = string
}

variable "s3_path_prefix" {
  description = "Path prefix this server can write to (e.g., 'backups/server-01/')"
  type        = string
}

variable "s3_permissions" {
  description = "S3 permission level: 'write', 'read-write', or 'full'"
  type        = string
  default     = "write"

  validation {
    condition     = contains(["write", "read-write", "full"], var.s3_permissions)
    error_message = "s3_permissions must be 'write', 'read-write', or 'full'"
  }
}

variable "max_session_duration" {
  description = "Max duration for assumed role sessions (seconds)"
  type        = number
  default     = 3600
}

variable "tags" {
  description = "Tags to apply to AWS resources"
  type        = map(string)
  default     = {}
}
```

#### 4.2.2 Module Resources

```hcl
# modules/server-access/main.tf

locals {
  # Map permission levels to S3 actions
  s3_actions = {
    write = ["s3:PutObject"]
    read-write = ["s3:PutObject", "s3:GetObject"]
    full = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
  }

  # ListBucket needs bucket-level permission (not object-level)
  needs_list_bucket = var.s3_permissions == "full"
}

# ─────────────────────────────────────────────────────────────────────────────
# Auth0 M2M Application
# ─────────────────────────────────────────────────────────────────────────────

resource "auth0_client" "server" {
  name        = "oidc-s3-${var.environment}-${var.server_name}"
  description = "M2M app for ${var.server_name} S3 uploads"
  app_type    = "non_interactive"  # M2M application

  # No callbacks/logout URLs needed for M2M
  callbacks       = []
  allowed_logout_urls = []
}

# Grant the M2M app access to the API
resource "auth0_client_grant" "server" {
  client_id = auth0_client.server.id
  audience  = var.audience
  scopes    = []  # No scopes needed for client credentials
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS IAM Role
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "server" {
  name                 = "oidc-s3-${var.environment}-${var.server_name}"
  max_session_duration = var.max_session_duration

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # Auth0 sub claim format: "{client_id}@clients"
          "${var.oidc_provider_url}:aud" = var.audience
          "${var.oidc_provider_url}:sub" = "${auth0_client.server.client_id}@clients"
        }
      }
    }]
  })

  tags = var.tags
}

# S3 object-level permissions (PutObject, GetObject, DeleteObject)
resource "aws_iam_role_policy" "s3_objects" {
  name = "s3-object-access"
  role = aws_iam_role.server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = local.s3_actions[var.s3_permissions]
      Resource = "${var.bucket_arn}/${var.s3_path_prefix}*"
    }]
  })
}

# S3 bucket-level permissions (ListBucket) - only for "full" permission level
resource "aws_iam_role_policy" "s3_list" {
  count = local.needs_list_bucket ? 1 : 0
  name  = "s3-list-access"
  role  = aws_iam_role.server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = var.bucket_arn
      Condition = {
        StringLike = {
          "s3:prefix" = ["${var.s3_path_prefix}*"]
        }
      }
    }]
  })
}
```

#### 4.2.3 Module Outputs

```hcl
# modules/server-access/outputs.tf

output "role_arn" {
  description = "ARN of the IAM role for the server to assume"
  value       = aws_iam_role.server.arn
}

output "role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.server.name
}

output "auth0_client_id" {
  description = "Auth0 client ID for the server"
  value       = auth0_client.server.client_id
}

output "auth0_client_secret" {
  description = "Auth0 client secret for the server"
  value       = auth0_client.server.client_secret
  sensitive   = true
}
```

#### 4.2.4 AWS Cognito Server Access Module (Alternative)

When using AWS Cognito, the server access module creates a Cognito app client and registers a client-role mapping in DynamoDB. **Importantly, the IAM role trusts the credential vending Lambda, not an OIDC provider.**

```hcl
# terraform-cognito/modules/server-access/main.tf

locals {
  s3_actions = {
    write      = ["s3:PutObject"]
    read-write = ["s3:PutObject", "s3:GetObject"]
    full       = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
  }
  needs_list_bucket = var.s3_permissions == "full"
}

# ─────────────────────────────────────────────────────────────────────────────
# Cognito App Client (M2M)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cognito_user_pool_client" "server" {
  name         = "oidc-s3-${var.environment}-${var.server_name}"
  user_pool_id = var.cognito_user_pool_id

  # Enable client credentials flow for M2M
  generate_secret                      = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = var.allowed_scopes  # e.g., ["resource/write", "resource/read"]

  # Token validity
  access_token_validity = 1  # hour (Cognito M2M default)
  token_validity_units {
    access_token = "hours"
  }

  # No user authentication flows needed for M2M
  explicit_auth_flows = []
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS IAM Role - Trusts Lambda (NOT OIDC provider)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "server" {
  name                 = "oidc-s3-${var.environment}-${var.server_name}"
  max_session_duration = var.max_session_duration

  # Trust the credential vending Lambda, NOT an OIDC provider
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.credential_vending_lambda_role_arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# DynamoDB: Register client-role mapping for credential vending
# ─────────────────────────────────────────────────────────────────────────────

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

# S3 policies same as Auth0 version...
```

**Cognito Module Outputs:**

```hcl
# terraform-cognito/modules/server-access/outputs.tf

output "role_arn" {
  value = aws_iam_role.server.arn
}

output "cognito_client_id" {
  description = "Cognito app client ID"
  value       = aws_cognito_user_pool_client.server.id
}

output "cognito_client_secret" {
  description = "Cognito app client secret"
  value       = aws_cognito_user_pool_client.server.client_secret
  sensitive   = true
}

output "allowed_scopes" {
  description = "OAuth scopes granted to this client"
  value       = aws_cognito_user_pool_client.server.allowed_oauth_scopes
}
```

**Key Differences from Auth0:**

| Aspect | Auth0 | AWS Cognito |
|--------|-------|-------------|
| Client resource | `auth0_client` | `aws_cognito_user_pool_client` |
| Grant resource | `auth0_client_grant` | Built into client config |
| IAM trust | OIDC provider with `aud`/`sub` conditions | Credential vending Lambda role |
| STS call | `AssumeRoleWithWebIdentity` (by client) | `AssumeRole` (by Lambda) |
| Role lookup | Encoded in trust policy conditions | DynamoDB table |
| Scopes | Optional, usually empty | Required for client_credentials flow |
| Token endpoint | `https://{domain}/oauth/token` | `https://{domain}.auth.{region}.amazoncognito.com/oauth2/token` |

### 4.3 Servers Layer

**Lifecycle**: Modified when servers are added/removed

#### 4.3.1 Server Definitions

```hcl
# environments/dev/servers.tfvars

servers = {
  "backup-server-01" = {
    s3_path_prefix  = "backups/server-01/"
    s3_permissions  = "read-write"  # Can upload and download
  }
  "backup-server-02" = {
    s3_path_prefix  = "backups/server-02/"
    s3_permissions  = "write"       # Upload only (default)
  }
  "log-shipper" = {
    s3_path_prefix  = "logs/"
    s3_permissions  = "write"
  }
  "data-sync" = {
    s3_path_prefix  = "sync/"
    s3_permissions  = "full"        # Upload, download, delete, list
  }
}
```

#### 4.3.2 Server Iteration

```hcl
# servers/servers.tf

module "server_access" {
  source   = "../modules/server-access"
  for_each = var.servers

  server_name    = each.key
  environment    = var.environment
  s3_path_prefix = each.value.s3_path_prefix
  s3_permissions = lookup(each.value, "s3_permissions", "write")

  # From remote state (foundation layer)
  auth0_api_id      = data.terraform_remote_state.foundation.outputs.auth0_api_id
  oidc_provider_arn = data.terraform_remote_state.foundation.outputs.oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.foundation.outputs.oidc_provider_url
  audience          = data.terraform_remote_state.foundation.outputs.audience
  bucket_arn        = data.terraform_remote_state.foundation.outputs.bucket_arn
  bucket_name       = data.terraform_remote_state.foundation.outputs.bucket_name

  tags = merge(var.common_tags, {
    Server      = each.key
    Environment = var.environment
  })
}
```

## 5. State Management

### 5.1 Remote State Backend

Both layers should use remote state (S3 + DynamoDB recommended):

```hcl
# foundation/main.tf
terraform {
  backend "s3" {
    bucket         = "terraform-state-bucket"
    key            = "oidc-s3-uploader/foundation/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

# servers/main.tf
terraform {
  backend "s3" {
    bucket         = "terraform-state-bucket"
    key            = "oidc-s3-uploader/servers/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

### 5.2 Cross-Layer Data Sharing

The servers layer reads foundation outputs via remote state:

```hcl
# servers/main.tf
data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = "terraform-state-bucket"
    key    = "oidc-s3-uploader/foundation/terraform.tfstate"
    region = "eu-west-1"
  }
}
```

## 6. Provider Configuration

### 6.1 Required Providers

```hcl
# foundation/main.tf and servers/main.tf

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    auth0 = {
      source  = "auth0/auth0"
      version = "~> 1.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "oidc-s3-uploader"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "auth0" {
  domain        = var.auth0_domain
  client_id     = var.auth0_client_id      # Management API client
  client_secret = var.auth0_client_secret  # Management API secret
}
```

### 6.2 Auth0 Management API Setup

Before running Terraform, create a Management API application in Auth0:

1. Auth0 Dashboard → Applications → APIs → Auth0 Management API
2. Machine to Machine Applications → Create & Authorize an application
3. Grant scopes: `create:clients`, `read:clients`, `delete:clients`, `create:client_grants`, `delete:client_grants`, `read:resource_servers`
4. Use the client credentials for `auth0_client_id` and `auth0_client_secret`

## 7. Security Considerations

### 7.1 Principle of Least Privilege

- Each server gets its own IAM role
- Each role is scoped to a specific S3 path prefix
- Trust policy validates both `aud` AND `sub` claims
- Default to `s3:PutObject` only; expand as needed

### 7.2 Path Isolation

S3 path structure:
```
s3://oidc-s3-{env}-uploads/
├── backups/
│   ├── server-01/    # Only backup-server-01 can access
│   └── server-02/    # Only backup-server-02 can access
├── logs/             # Only log-shipper can access
└── sync/             # Only data-sync can access
```

### 7.3 Audit Trail

- Enable S3 server access logging or CloudTrail data events
- IAM role session names include server identifier
- Consider adding `sts:SourceIdentity` for enhanced tracking

## 8. Deployment Workflow

### 8.1 Initial Setup

```bash
# 1. Deploy foundation (once per environment)
cd terraform/foundation
terraform init -backend-config=../environments/dev/backend.hcl
terraform plan -var-file=../environments/dev/foundation.tfvars
terraform apply -var-file=../environments/dev/foundation.tfvars

# 2. Deploy initial servers
cd ../servers
terraform init -backend-config=../environments/dev/backend.hcl
terraform plan -var-file=../environments/dev/servers.tfvars
terraform apply -var-file=../environments/dev/servers.tfvars
```

### 8.2 Adding a New Server

```bash
# 1. Add to environments/dev/servers.tfvars:
#    "new-server" = {
#      s3_path_prefix = "data/new-server/"
#      s3_permissions = "write"
#    }

# 2. Apply - creates both Auth0 app and AWS role automatically
cd terraform/servers
terraform plan -var-file=../environments/dev/servers.tfvars
terraform apply -var-file=../environments/dev/servers.tfvars

# 3. Get credentials for server configuration
terraform output -json server_configurations
```

### 8.3 Removing a Server

```bash
# 1. Remove from servers.tfvars
# 2. Apply (Auth0 app and AWS role both deleted)
terraform apply -var-file=../environments/dev/servers.tfvars
# 3. Optionally clean up S3 data
```

## 9. Outputs for Server Configuration

After applying the servers layer, retrieve credentials for each server:

```hcl
# servers/outputs.tf

output "server_configurations" {
  description = "Configuration values for each server"
  value = {
    for name, mod in module.server_access : name => {
      # Auth0 credentials (for getting OIDC token)
      auth0_domain        = var.auth0_domain
      auth0_client_id     = mod.auth0_client_id
      auth0_audience      = data.terraform_remote_state.foundation.outputs.audience

      # AWS configuration (for assuming role and S3 access)
      aws_role_arn        = mod.role_arn
      aws_region          = data.terraform_remote_state.foundation.outputs.aws_region
      s3_bucket           = data.terraform_remote_state.foundation.outputs.bucket_name
      s3_path_prefix      = var.servers[name].s3_path_prefix
    }
  }
  sensitive = true  # Contains client_id
}

# Get client secrets separately
output "server_secrets" {
  description = "Auth0 client secrets for each server (store securely!)"
  value = {
    for name, mod in module.server_access : name => mod.auth0_client_secret
  }
  sensitive = true
}
```

### 9.1 Example Output

```bash
$ terraform output -json server_configurations | jq '.["backup-server-01"]'
{
  "auth0_domain": "your-tenant.auth0.com",
  "auth0_client_id": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "auth0_audience": "https://s3-uploader.dev.example.com",
  "aws_role_arn": "arn:aws:iam::123456789012:role/oidc-s3-dev-backup-server-01",
  "aws_region": "eu-west-1",
  "s3_bucket": "oidc-s3-dev-uploads",
  "s3_path_prefix": "backups/server-01/"
}

$ terraform output -json server_secrets | jq -r '.["backup-server-01"]'
your-client-secret-here
```

## 10. Log Shipper Integration

### 10.1 Overview

Log shippers like Vector, Fluent Bit, and Logstash support AWS Web Identity Token authentication via the standard AWS SDK environment variables. However, **none of them natively fetch tokens from a custom OIDC provider like Auth0** - they expect a token file to already exist.

### 10.2 Solution: Token Refresh Sidecar

For log shippers, you need a sidecar process that:
1. Fetches OIDC tokens from Auth0 periodically
2. Writes the token to a file
3. Sets environment variables for the log shipper

```
┌─────────────────────────────────────────────────────────────────┐
│                        On-Prem Server                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐         ┌──────────────────────────────┐ │
│  │ Token Refresher  │         │ Log Shipper (Vector/etc)     │ │
│  │ (Python/systemd) │         │                              │ │
│  │                  │         │ Reads env vars:              │ │
│  │ 1. Get Auth0     │         │ - AWS_WEB_IDENTITY_TOKEN_FILE│ │
│  │    token         │         │ - AWS_ROLE_ARN               │ │
│  │ 2. Write to file │────────►│                              │ │
│  │ 3. Sleep/repeat  │         │ AWS SDK handles STS call     │ │
│  └──────────────────┘         └──────────────────────────────┘ │
│           │                                                     │
│           ▼                                                     │
│  /var/run/oidc/token                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 10.3 Log Shipper Compatibility

| Log Shipper | Web Identity Support | Configuration |
|-------------|---------------------|---------------|
| **Vector** | ✅ Via AWS SDK env vars | Set `AWS_WEB_IDENTITY_TOKEN_FILE` and `AWS_ROLE_ARN` |
| **Fluent Bit** | ✅ Via AWS SDK env vars | Set `AWS_WEB_IDENTITY_TOKEN_FILE` and `AWS_ROLE_ARN` |
| **Logstash** | ✅ `web_identity_token_file` option | Configure in S3 output plugin directly |

### 10.4 Vector Configuration Example

```toml
# /etc/vector/vector.toml

[sources.logs]
type = "file"
include = ["/var/log/*.log"]

[sinks.s3]
type = "aws_s3"
inputs = ["logs"]
bucket = "${S3_BUCKET}"
key_prefix = "${S3_PATH_PREFIX}"
region = "${AWS_REGION}"
compression = "gzip"

# Auth handled via environment variables:
# AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/oidc/token
# AWS_ROLE_ARN=arn:aws:iam::123456789012:role/oidc-s3-dev-log-shipper
```

### 10.5 Fluent Bit Configuration Example

```ini
# /etc/fluent-bit/fluent-bit.conf

[INPUT]
    Name tail
    Path /var/log/*.log
    Tag logs

[OUTPUT]
    Name s3
    Match logs
    bucket ${S3_BUCKET}
    region ${AWS_REGION}
    s3_key_format /${S3_PATH_PREFIX}$TAG/%Y/%m/%d/%H_%M_%S.gz
    total_file_size 10M
    upload_timeout 1m

# Auth handled via environment variables (same as Vector)
```

### 10.6 Logstash Configuration Example

```ruby
# /etc/logstash/conf.d/s3-output.conf

output {
  s3 {
    region => "${AWS_REGION}"
    bucket => "${S3_BUCKET}"
    prefix => "${S3_PATH_PREFIX}"

    # Direct web identity token support
    role_arn => "${AWS_ROLE_ARN}"
    web_identity_token_file => "/var/run/oidc/token"
    role_session_name => "logstash-shipper"
  }
}
```

### 10.7 Recommendation

**For simplicity**: Use the Python uploader script (see Section 11) as a standalone solution or as a token refresh daemon.

**For dedicated log shipping**: Use **Vector** - it's lightweight, fast, and has good AWS SDK integration. Run the token refresher as a systemd service alongside Vector.

## 11. Python Client Example

The client consists of two focused scripts:

- **`scripts/oidc_credential_provider.py`** - OIDC authentication and AWS credential management
  - `get-credentials` - Output credentials for AWS SDK credential_process (recommended for log shippers)
  - `credential-daemon` - Write credentials to files periodically
  - `token-daemon` - Write OIDC token for AWS_WEB_IDENTITY_TOKEN_FILE (Auth0 only)

- **`scripts/s3_ops.py`** - S3 operations using standard AWS credential chain
  - `upload`, `download`, `list`, `delete` commands

### 11.1 AWS Cognito Token Acquisition

When using AWS Cognito instead of Auth0, the token acquisition differs slightly:

```python
def get_cognito_token() -> str:
    """
    Get OIDC token from AWS Cognito using client credentials flow.
    """
    import base64
    import requests

    # Cognito token endpoint format
    token_url = f"https://{COGNITO_DOMAIN}.auth.{AWS_REGION}.amazoncognito.com/oauth2/token"

    # Cognito requires Basic auth header with client credentials
    credentials = base64.b64encode(
        f"{CLIENT_ID}:{CLIENT_SECRET}".encode()
    ).decode()

    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Authorization": f"Basic {credentials}"
    }

    data = {
        "grant_type": "client_credentials",
        "scope": f"{RESOURCE_SERVER_IDENTIFIER}/upload"  # Scope is required
    }

    response = requests.post(token_url, headers=headers, data=data)
    response.raise_for_status()

    return response.json()["access_token"]
```

**Environment Variables for Cognito:**

```bash
COGNITO_DOMAIN=oidc-s3-dev-123456789012  # User pool domain prefix
COGNITO_CLIENT_ID=xxx
COGNITO_CLIENT_SECRET=xxx
COGNITO_RESOURCE_SERVER=https://s3-uploader.dev.example.com
AWS_ROLE_ARN=arn:aws:iam::123456789012:role/oidc-s3-dev-server-name
AWS_REGION=eu-west-1
S3_BUCKET=oidc-s3-dev-uploads
S3_PATH_PREFIX=backups/server-01/
```

**Key Differences from Auth0:**

| Aspect | Auth0 | AWS Cognito |
|--------|-------|-------------|
| Auth method | JSON body | Basic auth header |
| Content-Type | `application/json` | `application/x-www-form-urlencoded` |
| Scope parameter | Optional (audience instead) | Required |
| Token URL | `https://{domain}/oauth/token` | `https://{domain}.auth.{region}.amazoncognito.com/oauth2/token` |
