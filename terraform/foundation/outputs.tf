output "oidc_provider_arn" {
  description = "ARN of the AWS OIDC provider"
  value       = aws_iam_openid_connect_provider.auth0.arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC provider (without https://, for IAM policy conditions)"
  value       = "${var.auth0_domain}/"
}

output "audience" {
  description = "Auth0 API identifier (audience claim in tokens)"
  value       = auth0_resource_server.s3_uploader.identifier
}

output "auth0_api_id" {
  description = "Auth0 API resource server ID"
  value       = auth0_resource_server.s3_uploader.id
}

output "bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.uploads.arn
}

output "bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.uploads.id
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "auth0_domain" {
  description = "Auth0 domain"
  value       = var.auth0_domain
}
