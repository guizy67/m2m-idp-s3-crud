# =============================================================================
# S3 Bucket for Uploads
# =============================================================================
# Optionally creates a new S3 bucket, or references an existing one.
# This allows sharing the bucket with the Auth0-based deployment if desired.
# =============================================================================

# Create new bucket if requested
resource "aws_s3_bucket" "uploads" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = "${var.project_name}-cognito-${var.environment}-uploads"

  tags = {
    Name = "${var.project_name}-cognito-${var.environment}-uploads"
  }
}

# Versioning: enabled for prod, disabled for dev
resource "aws_s3_bucket_versioning" "uploads" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = aws_s3_bucket.uploads[0].id

  versioning_configuration {
    status = var.environment == "prod" ? "Enabled" : "Disabled"
  }
}

# Lifecycle rules: 10-day expiration for dev only
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  count  = var.create_s3_bucket && var.environment == "dev" ? 1 : 0
  bucket = aws_s3_bucket.uploads[0].id

  rule {
    id     = "expire-after-10-days"
    status = "Enabled"

    expiration {
      days = 10
    }

    # Apply to all objects in the bucket
    filter {}
  }
}

# Server-side encryption using AES256
resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = aws_s3_bucket.uploads[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "uploads" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = aws_s3_bucket.uploads[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Reference existing bucket if not creating new one
data "aws_s3_bucket" "existing" {
  count  = var.create_s3_bucket ? 0 : 1
  bucket = var.existing_bucket_name
}

# Local to simplify references
locals {
  bucket_id  = var.create_s3_bucket ? aws_s3_bucket.uploads[0].id : data.aws_s3_bucket.existing[0].id
  bucket_arn = var.create_s3_bucket ? aws_s3_bucket.uploads[0].arn : data.aws_s3_bucket.existing[0].arn
}
