# =============================================================================
# Servers Layer Outputs
# =============================================================================

output "server_configurations" {
  description = "Configuration values for each server (use with Python client)"
  value = {
    for name, mod in module.server_access : name => {
      # Cognito credentials (for getting OIDC token)
      cognito_domain             = data.terraform_remote_state.foundation.outputs.cognito_domain
      cognito_token_endpoint     = data.terraform_remote_state.foundation.outputs.cognito_token_endpoint
      cognito_client_id          = mod.cognito_client_id
      resource_server_identifier = data.terraform_remote_state.foundation.outputs.resource_server_identifier
      allowed_scopes             = mod.allowed_scopes

      # Credential vending API (exchanges Cognito token for AWS creds)
      credential_vending_api_url = data.terraform_remote_state.foundation.outputs.credential_vending_api_url

      # S3 configuration
      aws_region     = data.terraform_remote_state.foundation.outputs.aws_region
      s3_bucket      = data.terraform_remote_state.foundation.outputs.bucket_name
      s3_path_prefix = var.servers[name].s3_path_prefix
    }
  }
  sensitive = true
}

output "server_secrets" {
  description = "Cognito client secrets for each server (store securely!)"
  value = {
    for name, mod in module.server_access : name => mod.cognito_client_secret
  }
  sensitive = true
}

output "server_role_arns" {
  description = "IAM role ARNs for each server"
  value = {
    for name, mod in module.server_access : name => mod.role_arn
  }
}

output "cognito_token_endpoint" {
  description = "Cognito token endpoint (shared by all servers)"
  value       = data.terraform_remote_state.foundation.outputs.cognito_token_endpoint
}

output "credential_vending_api_url" {
  description = "Credential vending API endpoint (shared by all servers)"
  value       = data.terraform_remote_state.foundation.outputs.credential_vending_api_url
}
