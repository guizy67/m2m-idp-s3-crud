# =============================================================================
# AWS Cognito User Pool and Resource Server
# =============================================================================
# Cognito provides native OIDC token issuance for M2M (client credentials) flows.
# No external IdP account needed - everything is AWS-native.
#
# Architecture:
#   Client → Cognito (get token) → Credential Vending API → STS creds → S3
#
# Note: Unlike Auth0, Cognito M2M tokens cannot be used directly with
# AssumeRoleWithWebIdentity. We use a credential vending Lambda/API instead.
# =============================================================================

locals {
  # Auto-generate resource server identifier if not provided
  resource_server_id = var.resource_server_identifier != "" ? var.resource_server_identifier : "https://s3-uploader.${var.environment}.${var.project_name}"
}

# -----------------------------------------------------------------------------
# Cognito User Pool
# -----------------------------------------------------------------------------
# The User Pool is the identity provider. For M2M flows, we don't need user
# sign-up/sign-in - we only use app clients with client credentials.

resource "aws_cognito_user_pool" "s3_uploader" {
  name = "${var.project_name}-${var.environment}"

  # Disable self-registration - M2M apps don't need user accounts
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # Minimal password policy (not used for M2M, but required by AWS)
  password_policy {
    minimum_length    = 8
    require_lowercase = false
    require_numbers   = false
    require_symbols   = false
    require_uppercase = false
  }

  # Account recovery not needed for M2M
  account_recovery_setting {
    recovery_mechanism {
      name     = "admin_only"
      priority = 1
    }
  }

  tags = {
    Name = "${var.project_name}-${var.environment}"
  }
}

# -----------------------------------------------------------------------------
# Cognito User Pool Domain
# -----------------------------------------------------------------------------
# Required for OAuth2 token endpoint. Uses Cognito-hosted domain.

resource "aws_cognito_user_pool_domain" "s3_uploader" {
  domain       = "${var.project_name}-${var.environment}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.s3_uploader.id
}

# -----------------------------------------------------------------------------
# Cognito Resource Server
# -----------------------------------------------------------------------------
# Defines the API (audience) and scopes for M2M tokens.
# Scopes are REQUIRED for client_credentials flow in Cognito.

resource "aws_cognito_resource_server" "s3_uploader" {
  identifier   = local.resource_server_id
  name         = "S3 Uploader API - ${var.environment}"
  user_pool_id = aws_cognito_user_pool.s3_uploader.id

  # Define scopes for different permission levels
  scope {
    scope_name        = "write"
    scope_description = "Upload files to S3"
  }

  scope {
    scope_name        = "read"
    scope_description = "Download files from S3"
  }

  scope {
    scope_name        = "delete"
    scope_description = "Delete files from S3"
  }

  scope {
    scope_name        = "list"
    scope_description = "List files in S3"
  }
}
