output "server_configurations" {
  description = "Configuration values for each server (use with Python client)"
  value = {
    for name, mod in module.server_access : name => {
      # Auth0 credentials (for getting OIDC token)
      auth0_domain   = var.auth0_domain
      auth0_client_id = mod.auth0_client_id
      auth0_audience = data.terraform_remote_state.foundation.outputs.audience

      # AWS configuration (for assuming role and S3 access)
      aws_role_arn   = mod.role_arn
      aws_region     = data.terraform_remote_state.foundation.outputs.aws_region
      s3_bucket      = data.terraform_remote_state.foundation.outputs.bucket_name
      s3_path_prefix = var.servers[name].s3_path_prefix
    }
  }
  sensitive = true
}

output "server_secrets" {
  description = "Auth0 client secrets for each server (store securely!)"
  value = {
    for name, mod in module.server_access : name => mod.auth0_client_secret
  }
  sensitive = true
}

output "server_role_arns" {
  description = "IAM role ARNs for each server"
  value = {
    for name, mod in module.server_access : name => mod.role_arn
  }
}
