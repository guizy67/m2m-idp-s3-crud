bucket         = "oidc-s3-uploader-tfstate"
key            = "prod/cognito-foundation/terraform.tfstate"
region         = "eu-west-1"
dynamodb_table = "oidc-s3-uploader-tflock"
encrypt        = true
