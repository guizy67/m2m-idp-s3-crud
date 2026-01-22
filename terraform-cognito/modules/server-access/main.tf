# =============================================================================
# Server Access Module (Cognito Version - Credential Vending)
# =============================================================================
# Creates a Cognito App Client and AWS IAM role for a single server.
# Each server gets its own client credentials for M2M authentication.
#
# Architecture:
#   Client → Cognito (get token) → Credential Vending API → STS creds → S3
#
# The IAM role trusts the credential vending Lambda, which validates tokens
# and calls STS AssumeRole on behalf of clients.
# =============================================================================

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

locals {
  # Map permission levels to S3 actions
  s3_actions = {
    write      = ["s3:PutObject"]
    read-write = ["s3:PutObject", "s3:GetObject"]
    full       = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
  }

  # Map permission levels to Cognito scopes
  cognito_scopes = {
    write      = ["${var.resource_server_identifier}/write"]
    read-write = ["${var.resource_server_identifier}/write", "${var.resource_server_identifier}/read"]
    full       = ["${var.resource_server_identifier}/write", "${var.resource_server_identifier}/read", "${var.resource_server_identifier}/delete", "${var.resource_server_identifier}/list"]
  }

  # ListBucket needs bucket-level permission (not object-level)
  needs_list_bucket = var.s3_permissions == "full"
}

# =============================================================================
# Cognito App Client (M2M)
# =============================================================================
# Each server gets its own app client with client_credentials flow enabled.
# The client ID and secret are used to obtain access tokens.

resource "aws_cognito_user_pool_client" "server" {
  name         = "oidc-s3-${var.environment}-${var.server_name}"
  user_pool_id = var.cognito_user_pool_id

  # Enable client credentials flow for M2M
  generate_secret                      = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = local.cognito_scopes[var.s3_permissions]

  # Required for M2M apps
  supported_identity_providers = ["COGNITO"]

  # Token validity (matching console defaults)
  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.access_token_validity_minutes
  refresh_token_validity = 5
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # M2M auth flows (matching console)
  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  # Enable token revocation (matching console)
  enable_token_revocation = true
}

# =============================================================================
# DynamoDB Entry for Client-Role Mapping
# =============================================================================
# Register this client in the DynamoDB table so the credential vending
# Lambda knows which role to assume for this client.

resource "aws_dynamodb_table_item" "client_role_mapping" {
  table_name = var.client_roles_table_name
  hash_key   = "client_id"

  item = jsonencode({
    client_id = {
      S = aws_cognito_user_pool_client.server.id
    }
    server_name = {
      S = var.server_name
    }
    role_arn = {
      S = aws_iam_role.server.arn
    }
    s3_path_prefix = {
      S = var.s3_path_prefix
    }
    s3_permissions = {
      S = var.s3_permissions
    }
    allowed_scopes = {
      SS = local.cognito_scopes[var.s3_permissions]
    }
  })
}

# =============================================================================
# AWS IAM Role
# =============================================================================
# The role that the credential vending Lambda assumes on behalf of clients.
# Trust policy allows ONLY the credential vending Lambda to assume this role.

resource "aws_iam_role" "server" {
  name                 = "oidc-s3-cognito-${var.environment}-${var.server_name}"
  max_session_duration = var.max_session_duration

  # Trust the credential vending Lambda to assume this role
  # The Lambda validates Cognito tokens before calling AssumeRole
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = var.credential_vending_lambda_role_arn
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

# =============================================================================
# S3 IAM Policies
# =============================================================================

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
