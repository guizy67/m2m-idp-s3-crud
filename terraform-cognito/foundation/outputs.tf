# =============================================================================
# Foundation Layer Outputs
# =============================================================================
# These outputs are consumed by the servers layer via terraform_remote_state
# =============================================================================

# -----------------------------------------------------------------------------
# Cognito Outputs
# -----------------------------------------------------------------------------

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.s3_uploader.id
}

output "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.s3_uploader.arn
}

output "cognito_domain" {
  description = "Cognito User Pool domain (for token endpoint)"
  value       = aws_cognito_user_pool_domain.s3_uploader.domain
}

output "cognito_token_endpoint" {
  description = "Full URL for the Cognito token endpoint"
  value       = "https://${aws_cognito_user_pool_domain.s3_uploader.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
}

output "resource_server_identifier" {
  description = "Cognito Resource Server identifier (audience for tokens)"
  value       = aws_cognito_resource_server.s3_uploader.identifier
}

output "resource_server_scopes" {
  description = "Available scopes on the resource server"
  value = {
    write  = "${aws_cognito_resource_server.s3_uploader.identifier}/write"
    read   = "${aws_cognito_resource_server.s3_uploader.identifier}/read"
    delete = "${aws_cognito_resource_server.s3_uploader.identifier}/delete"
    list   = "${aws_cognito_resource_server.s3_uploader.identifier}/list"
  }
}

# -----------------------------------------------------------------------------
# Credential Vending API Outputs
# -----------------------------------------------------------------------------

output "credential_vending_api_url" {
  description = "URL for the credential vending API endpoint"
  value       = "${aws_apigatewayv2_api.credential_vending.api_endpoint}/credentials"
}

output "credential_vending_lambda_role_arn" {
  description = "ARN of the credential vending Lambda's IAM role (servers must trust this)"
  value       = aws_iam_role.credential_vending.arn
}

output "client_roles_table_name" {
  description = "DynamoDB table name for client-role mappings"
  value       = aws_dynamodb_table.client_roles.name
}

output "client_roles_table_arn" {
  description = "DynamoDB table ARN for client-role mappings"
  value       = aws_dynamodb_table.client_roles.arn
}

output "cognito_issuer_url" {
  description = "Full issuer URL (with https://)"
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.s3_uploader.id}"
}

# -----------------------------------------------------------------------------
# S3 Outputs
# -----------------------------------------------------------------------------

output "bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = local.bucket_arn
}

output "bucket_name" {
  description = "Name of the S3 bucket"
  value       = local.bucket_id
}

# -----------------------------------------------------------------------------
# General Outputs
# -----------------------------------------------------------------------------

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "environment" {
  description = "Environment name"
  value       = var.environment
}

output "aws_account_id" {
  description = "AWS Account ID"
  value       = data.aws_caller_identity.current.account_id
}
