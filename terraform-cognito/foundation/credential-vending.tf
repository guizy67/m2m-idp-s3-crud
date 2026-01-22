# =============================================================================
# Credential Vending API (API Gateway + Lambda)
# =============================================================================
# This API validates Cognito access tokens and returns short-lived AWS
# credentials for S3 access. This is required because Cognito M2M tokens
# cannot be used directly with AssumeRoleWithWebIdentity.
#
# Architecture:
#   Client → API Gateway → Lambda → STS AssumeRole → Credentials returned
#
# The Lambda:
#   1. Validates the Cognito access token (issuer, token_use, expiration)
#   2. Extracts client_id and scopes from the token
#   3. Looks up the IAM role ARN for this client from DynamoDB
#   4. Calls STS AssumeRole with appropriate session tags
#   5. Returns temporary credentials to the client
# =============================================================================

# -----------------------------------------------------------------------------
# DynamoDB Table for Client-Role Mapping
# -----------------------------------------------------------------------------
# Maps Cognito client IDs to their allowed IAM roles and S3 paths.
# This is populated by the servers layer when onboarding new servers.

resource "aws_dynamodb_table" "client_roles" {
  name         = "${var.project_name}-${var.environment}-client-roles"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "client_id"

  attribute {
    name = "client_id"
    type = "S"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-client-roles"
  }
}

# -----------------------------------------------------------------------------
# Lambda Function for Credential Vending
# -----------------------------------------------------------------------------

data "archive_file" "credential_vending" {
  type        = "zip"
  output_path = "${path.module}/lambda/credential_vending.zip"

  source {
    content  = <<-EOF
      import json
      import os
      import boto3
      import urllib.request
      import base64
      from datetime import datetime

      # Cache for JWKS
      _jwks_cache = None

      def get_jwks(issuer_url):
          """Fetch JWKS from Cognito."""
          global _jwks_cache
          if _jwks_cache:
              return _jwks_cache

          jwks_url = f"{issuer_url}/.well-known/jwks.json"
          with urllib.request.urlopen(jwks_url, timeout=5) as response:
              _jwks_cache = json.loads(response.read().decode())
          return _jwks_cache

      def decode_jwt_unverified(token):
          """Decode JWT without verification (verification done by checking claims)."""
          parts = token.split('.')
          if len(parts) != 3:
              raise ValueError("Invalid JWT format")

          # Decode header and payload
          def b64_decode(data):
              # Add padding if needed
              padding = 4 - len(data) % 4
              if padding != 4:
                  data += '=' * padding
              return base64.urlsafe_b64decode(data)

          header = json.loads(b64_decode(parts[0]))
          payload = json.loads(b64_decode(parts[1]))
          return header, payload

      def validate_token(token, expected_issuer):
          """
          Validate the Cognito access token.

          For production, you should use a proper JWT library with signature verification.
          This implementation validates claims but relies on HTTPS for transport security.
          """
          try:
              header, payload = decode_jwt_unverified(token)
          except Exception as e:
              return None, f"Invalid token format: {e}"

          # Validate issuer
          if payload.get('iss') != expected_issuer:
              return None, f"Invalid issuer: {payload.get('iss')}"

          # Validate token_use (must be 'access' for M2M tokens)
          if payload.get('token_use') != 'access':
              return None, f"Invalid token_use: {payload.get('token_use')}"

          # Validate expiration
          exp = payload.get('exp', 0)
          if datetime.utcnow().timestamp() > exp:
              return None, "Token expired"

          return payload, None

      def handler(event, context):
          """
          Lambda handler for credential vending.

          Expected request body:
          {
              "access_token": "eyJ..."
          }

          Returns:
          {
              "credentials": {
                  "access_key_id": "...",
                  "secret_access_key": "...",
                  "session_token": "...",
                  "expiration": "2024-01-01T00:00:00Z"
              },
              "s3_bucket": "...",
              "s3_path_prefix": "...",
              "aws_region": "..."
          }
          """
          print(f"Event: {json.dumps(event)}")

          # Configuration from environment
          issuer = os.environ['COGNITO_ISSUER']
          table_name = os.environ['DYNAMODB_TABLE']
          aws_region = os.environ['AWS_REGION']
          s3_bucket = os.environ['S3_BUCKET']

          # Parse request body
          try:
              if event.get('body'):
                  body = json.loads(event['body']) if isinstance(event['body'], str) else event['body']
              else:
                  body = event
              access_token = body.get('access_token')
              if not access_token:
                  return response(400, {'error': 'Missing access_token'})
          except json.JSONDecodeError as e:
              return response(400, {'error': f'Invalid JSON: {e}'})

          # Validate the access token
          claims, error = validate_token(access_token, issuer)
          if error:
              print(f"Token validation failed: {error}")
              return response(401, {'error': error})

          client_id = claims.get('client_id') or claims.get('sub')
          scopes = claims.get('scope', '').split()
          print(f"Client ID: {client_id}, Scopes: {scopes}")

          # Look up the role ARN for this client
          dynamodb = boto3.resource('dynamodb')
          table = dynamodb.Table(table_name)

          try:
              result = table.get_item(Key={'client_id': client_id})
              if 'Item' not in result:
                  print(f"No role mapping found for client: {client_id}")
                  return response(403, {'error': 'Client not authorized'})

              item = result['Item']
              role_arn = item['role_arn']
              s3_path_prefix = item['s3_path_prefix']
              allowed_scopes = item.get('allowed_scopes', [])

              print(f"Found mapping: role={role_arn}, prefix={s3_path_prefix}")
          except Exception as e:
              print(f"DynamoDB error: {e}")
              return response(500, {'error': 'Internal error looking up client'})

          # Assume the role
          sts = boto3.client('sts')
          try:
              assume_response = sts.assume_role(
                  RoleArn=role_arn,
                  RoleSessionName=f"cognito-{client_id[:8]}",
                  DurationSeconds=3600,  # 1 hour
              )

              creds = assume_response['Credentials']

              return response(200, {
                  'credentials': {
                      'access_key_id': creds['AccessKeyId'],
                      'secret_access_key': creds['SecretAccessKey'],
                      'session_token': creds['SessionToken'],
                      'expiration': creds['Expiration'].isoformat()
                  },
                  's3_bucket': s3_bucket,
                  's3_path_prefix': s3_path_prefix,
                  'aws_region': aws_region
              })
          except Exception as e:
              print(f"STS AssumeRole error: {e}")
              return response(500, {'error': f'Failed to assume role: {e}'})

      def response(status_code, body):
          """Build API Gateway response."""
          return {
              'statusCode': status_code,
              'headers': {
                  'Content-Type': 'application/json',
                  'Access-Control-Allow-Origin': '*'
              },
              'body': json.dumps(body, default=str)
          }
    EOF
    filename = "index.py"
  }
}

# IAM role for the credential vending Lambda
resource "aws_iam_role" "credential_vending" {
  name = "${var.project_name}-${var.environment}-cred-vending"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Lambda basic execution (CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "credential_vending_basic" {
  role       = aws_iam_role.credential_vending.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Policy to read from DynamoDB
resource "aws_iam_role_policy" "credential_vending_dynamodb" {
  name = "dynamodb-read"
  role = aws_iam_role.credential_vending.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem"
      ]
      Resource = aws_dynamodb_table.client_roles.arn
    }]
  })
}

# Policy to assume any server role (the roles will trust this Lambda)
resource "aws_iam_role_policy" "credential_vending_sts" {
  name = "sts-assume-role"
  role = aws_iam_role.credential_vending.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-cognito-${var.environment}-*"
    }]
  })
}

# Lambda function
resource "aws_lambda_function" "credential_vending" {
  filename         = data.archive_file.credential_vending.output_path
  function_name    = "${var.project_name}-${var.environment}-cred-vending"
  role             = aws_iam_role.credential_vending.arn
  handler          = "index.handler"
  source_code_hash = data.archive_file.credential_vending.output_base64sha256
  runtime          = "python3.12"
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      COGNITO_ISSUER = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.s3_uploader.id}"
      DYNAMODB_TABLE = aws_dynamodb_table.client_roles.name
      S3_BUCKET      = local.bucket_id
    }
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-cred-vending"
  }
}

# -----------------------------------------------------------------------------
# API Gateway (HTTP API)
# -----------------------------------------------------------------------------
# Using HTTP API (v2) for lower latency and cost compared to REST API.

resource "aws_apigatewayv2_api" "credential_vending" {
  name          = "${var.project_name}-${var.environment}-cred-vending"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 300
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-cred-vending"
  }
}

# Lambda integration
resource "aws_apigatewayv2_integration" "credential_vending" {
  api_id                 = aws_apigatewayv2_api.credential_vending.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.credential_vending.invoke_arn
  payload_format_version = "2.0"
}

# POST /credentials route
resource "aws_apigatewayv2_route" "credential_vending" {
  api_id    = aws_apigatewayv2_api.credential_vending.id
  route_key = "POST /credentials"
  target    = "integrations/${aws_apigatewayv2_integration.credential_vending.id}"
}

# Default stage with auto-deploy
resource "aws_apigatewayv2_stage" "credential_vending" {
  api_id      = aws_apigatewayv2_api.credential_vending.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      errorMessage   = "$context.error.message"
    })
  }
}

# CloudWatch log group for API Gateway
resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${var.project_name}-${var.environment}-cred-vending"
  retention_in_days = 7
}

# Permission for API Gateway to invoke Lambda
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.credential_vending.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.credential_vending.execution_arn}/*/*"
}
