# =============================================================================
# AWS Cognito-based OIDC Servers Layer
# =============================================================================
# This layer creates Cognito app clients and IAM roles for each server.
# It reads foundation outputs via terraform_remote_state.
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
    # Note: Use a different key than foundation layer
    # e.g., key = "dev/cognito-servers/terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "oidc-s3-uploader"
      Environment = var.environment
      ManagedBy   = "terraform"
      IdP         = "cognito"
    }
  }
}

# Read outputs from the foundation layer
data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.environment}/cognito-foundation/terraform.tfstate"
    region = var.aws_region
  }
}
