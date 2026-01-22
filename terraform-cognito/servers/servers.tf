# =============================================================================
# Server Access Resources
# =============================================================================
# Creates Cognito app clients and IAM roles for each server in the configuration.
# =============================================================================

module "server_access" {
  source   = "../modules/server-access"
  for_each = var.servers

  server_name    = each.key
  environment    = var.environment
  s3_path_prefix = each.value.s3_path_prefix
  s3_permissions = each.value.s3_permissions

  # From remote state (foundation layer)
  cognito_user_pool_id               = data.terraform_remote_state.foundation.outputs.cognito_user_pool_id
  resource_server_identifier         = data.terraform_remote_state.foundation.outputs.resource_server_identifier
  credential_vending_lambda_role_arn = data.terraform_remote_state.foundation.outputs.credential_vending_lambda_role_arn
  client_roles_table_name            = data.terraform_remote_state.foundation.outputs.client_roles_table_name
  bucket_arn                         = data.terraform_remote_state.foundation.outputs.bucket_arn
  bucket_name                        = data.terraform_remote_state.foundation.outputs.bucket_name

  tags = merge(var.common_tags, {
    Server      = each.key
    Environment = var.environment
  })
}
