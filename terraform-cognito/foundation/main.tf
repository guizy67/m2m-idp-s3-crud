# =============================================================================
# AWS Cognito-based OIDC Foundation Layer
# =============================================================================
# This layer creates the Cognito User Pool, Resource Server, and OIDC provider
# for credential-free S3 uploads from on-premises servers.
#
# Key difference from Auth0: Everything is managed via AWS provider only.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Backend configuration is provided via -backend-config flag
    # See environments/{env}/backend.hcl
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      IdP         = "cognito"
    }
  }
}

# Get current AWS account ID for unique naming
data "aws_caller_identity" "current" {}
