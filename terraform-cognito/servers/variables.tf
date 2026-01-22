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

variable "tfstate_bucket" {
  description = "S3 bucket name for Terraform state"
  type        = string
  default     = "oidc-s3-uploader-tfstate"
}

variable "servers" {
  description = "Map of server configurations"
  type = map(object({
    s3_path_prefix = string
    s3_permissions = optional(string, "write")
  }))
  default = {}
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
