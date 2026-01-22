# S3 bucket for uploads
# Each environment gets its own bucket

resource "aws_s3_bucket" "uploads" {
  bucket = "${var.project_name}-${var.environment}-uploads"

  tags = {
    Name = "${var.project_name}-${var.environment}-uploads"
  }
}

# Versioning: enabled for prod, disabled for dev
resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  versioning_configuration {
    status = var.environment == "prod" ? "Enabled" : "Disabled"
  }
}

# Lifecycle rules: 10-day expiration for dev only
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  count  = var.environment == "dev" ? 1 : 0
  bucket = aws_s3_bucket.uploads.id

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
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
