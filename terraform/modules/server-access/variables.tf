variable "server_name" {
  description = "Unique identifier for the server (e.g., 'backup-server-01')"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, prod)"
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
  description = "Expected audience claim in the token (Auth0 API identifier)"
  type        = string
}

variable "bucket_arn" {
  description = "ARN of the S3 bucket"
  type        = string
}

variable "bucket_name" {
  description = "Name of the S3 bucket"
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
