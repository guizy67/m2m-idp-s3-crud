output "role_arn" {
  description = "ARN of the IAM role for the server to assume"
  value       = aws_iam_role.server.arn
}

output "role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.server.name
}

output "auth0_client_id" {
  description = "Auth0 client ID for the server"
  value       = auth0_client.server.client_id
}

output "auth0_client_secret" {
  description = "Auth0 client secret for the server"
  value       = auth0_client_credentials.server.client_secret
  sensitive   = true
}
