# AWS OIDC Identity Provider that trusts Auth0
# This allows AWS STS to validate tokens from Auth0

# Fetch the TLS certificate thumbprint for Auth0
# AWS uses this to verify the OIDC provider's identity
data "tls_certificate" "auth0" {
  url = "https://${var.auth0_domain}/"
}

resource "aws_iam_openid_connect_provider" "auth0" {
  url = "https://${var.auth0_domain}/"

  # The audience claims that AWS will accept
  # Include both the API identifier (aud claim) and allow for azp claim validation
  client_id_list = [auth0_resource_server.s3_uploader.identifier]

  # Certificate thumbprint for Auth0
  thumbprint_list = [data.tls_certificate.auth0.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${var.project_name}-${var.environment}-auth0"
  }
}
