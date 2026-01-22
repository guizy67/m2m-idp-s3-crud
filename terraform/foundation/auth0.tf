# Auth0 API (Resource Server) for S3 uploader
# This defines the audience claim that will be in OIDC tokens

resource "auth0_resource_server" "s3_uploader" {
  name       = "${var.project_name}-${var.environment}"
  identifier = "https://${var.project_name}-${var.environment}.example.com"

  # No scopes needed for M2M client credentials flow
  # Token lifetime: 24 hours (in seconds)
  token_lifetime = 86400

  # Skip consent for M2M apps
  skip_consent_for_verifiable_first_party_clients = true
}
