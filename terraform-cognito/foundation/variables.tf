variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'"
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "oidc-s3"
}

variable "resource_server_identifier" {
  description = "Identifier for the Cognito Resource Server (becomes the audience)"
  type        = string
  default     = ""  # If empty, will be auto-generated based on environment
}

variable "token_validity_hours" {
  description = "Access token validity in hours"
  type        = number
  default     = 24
}

variable "create_s3_bucket" {
  description = "Whether to create a new S3 bucket or use existing one from Auth0 foundation"
  type        = bool
  default     = true
}

variable "existing_bucket_name" {
  description = "Name of existing S3 bucket to use (only if create_s3_bucket is false)"
  type        = string
  default     = ""
}
