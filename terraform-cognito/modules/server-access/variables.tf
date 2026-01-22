variable "server_name" {
  description = "Unique identifier for the server (e.g., 'backup-server-01')"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string
}

variable "cognito_user_pool_id" {
  description = "Cognito User Pool ID (from foundation)"
  type        = string
}

variable "resource_server_identifier" {
  description = "Cognito Resource Server identifier (from foundation)"
  type        = string
}

variable "credential_vending_lambda_role_arn" {
  description = "ARN of the credential vending Lambda's IAM role (roles trust this)"
  type        = string
}

variable "client_roles_table_name" {
  description = "DynamoDB table name for client-role mappings"
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

variable "access_token_validity_minutes" {
  description = "Access token validity in minutes (default: 60, matching AWS console)"
  type        = number
  default     = 60
}

variable "tags" {
  description = "Tags to apply to AWS resources"
  type        = map(string)
  default     = {}
}
