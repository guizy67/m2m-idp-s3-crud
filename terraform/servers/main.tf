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

  backend "s3" {
    # Backend configuration is provided via -backend-config flag
    # Note: Use a different key than foundation layer
    # e.g., key = "dev/servers/terraform.tfstate"
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
  client_id     = var.auth0_client_id
  client_secret = var.auth0_client_secret
}

# Read outputs from the foundation layer
data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = "oidc-s3-uploader-tfstate"
    key    = "${var.environment}/foundation/terraform.tfstate"
    region = var.aws_region
  }
}
