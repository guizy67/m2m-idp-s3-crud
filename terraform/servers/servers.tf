# Create server access resources for each server in the configuration
module "server_access" {
  source   = "../modules/server-access"
  for_each = var.servers

  server_name    = each.key
  environment    = var.environment
  s3_path_prefix = each.value.s3_path_prefix
  s3_permissions = each.value.s3_permissions

  # From remote state (foundation layer)
  oidc_provider_arn = data.terraform_remote_state.foundation.outputs.oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.foundation.outputs.oidc_provider_url
  audience          = data.terraform_remote_state.foundation.outputs.audience
  bucket_arn        = data.terraform_remote_state.foundation.outputs.bucket_arn
  bucket_name       = data.terraform_remote_state.foundation.outputs.bucket_name

  tags = merge(var.common_tags, {
    Server      = each.key
    Environment = var.environment
  })
}

# Add each server's Auth0 client ID to the AWS OIDC provider's client_id_list
# This is required for AWS STS to accept tokens from Auth0 M2M applications
resource "terraform_data" "oidc_client_id" {
  for_each = var.servers

  input = {
    oidc_provider_arn = data.terraform_remote_state.foundation.outputs.oidc_provider_arn
    client_id         = module.server_access[each.key].auth0_client_id
    aws_region        = var.aws_region
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws iam add-client-id-to-open-id-connect-provider \
        --open-id-connect-provider-arn "${self.input.oidc_provider_arn}" \
        --client-id "${self.input.client_id}" \
        --region "${self.input.aws_region}" 2>/dev/null || true
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws iam remove-client-id-from-open-id-connect-provider \
        --open-id-connect-provider-arn "${self.output.oidc_provider_arn}" \
        --client-id "${self.output.client_id}" \
        --region "${self.output.aws_region}" 2>/dev/null || true
    EOT
  }
}
