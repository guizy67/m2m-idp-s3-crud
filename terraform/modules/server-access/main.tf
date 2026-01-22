# =============================================================================
# Required Providers
# =============================================================================

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    auth0 = {
      source = "auth0/auth0"
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

  # ListBucket needs bucket-level permission (not object-level)
  needs_list_bucket = var.s3_permissions == "full"
}

# =============================================================================
# Auth0 M2M Application
# =============================================================================

resource "auth0_client" "server" {
  name        = "oidc-s3-${var.environment}-${var.server_name}"
  description = "M2M app for ${var.server_name} S3 uploads"
  app_type    = "non_interactive" # M2M application

  # No callbacks/logout URLs needed for M2M
  callbacks           = []
  allowed_logout_urls = []
}

# Configure client credentials (generates client secret)
resource "auth0_client_credentials" "server" {
  client_id             = auth0_client.server.id
  authentication_method = "client_secret_post"
}

# Grant the M2M app access to the API
resource "auth0_client_grant" "server" {
  client_id = auth0_client.server.id
  audience  = var.audience
  scopes    = [] # No scopes needed for client credentials
}

# =============================================================================
# AWS IAM Role
# =============================================================================

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
          # Auth0 M2M tokens use client_id as the audience for AWS validation
          # The sub claim format is "{client_id}@clients"
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
