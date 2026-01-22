# =============================================================================
# Server Access Module Outputs
# =============================================================================

output "role_arn" {
  description = "ARN of the IAM role for the server to assume"
  value       = aws_iam_role.server.arn
}

output "role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.server.name
}

output "cognito_client_id" {
  description = "Cognito app client ID for the server"
  value       = aws_cognito_user_pool_client.server.id
}

output "cognito_client_secret" {
  description = "Cognito app client secret for the server"
  value       = aws_cognito_user_pool_client.server.client_secret
  sensitive   = true
}

output "allowed_scopes" {
  description = "OAuth scopes allowed for this client"
  value       = aws_cognito_user_pool_client.server.allowed_oauth_scopes
}
