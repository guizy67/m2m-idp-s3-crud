#!/usr/bin/env python3
"""
S3 Operations CLI using standard AWS credential chain.

This script performs S3 operations (upload, download, list, delete) using
credentials from the standard AWS SDK credential chain:
  - Environment variables (AWS_ACCESS_KEY_ID, etc.)
  - AWS credential files (~/.aws/credentials or AWS_SHARED_CREDENTIALS_FILE)
  - credential_process in AWS config
  - IAM roles (EC2, ECS, Lambda)

Use with oidc_credential_provider.py to get credentials via OIDC federation.

Requirements:
    pip install boto3

Configuration via environment variables:
    AWS_REGION       - AWS region (required)
    S3_BUCKET        - S3 bucket name (required)
    S3_PATH_PREFIX   - Default path prefix for uploads (optional)
"""

import argparse
import logging
import os
import sys
from pathlib import Path
from typing import Optional

import boto3
from botocore.exceptions import ClientError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


def get_config() -> tuple[str, str, str]:
    """Get configuration from environment variables."""
    region = os.environ.get("AWS_REGION")
    bucket = os.environ.get("S3_BUCKET")
    prefix = os.environ.get("S3_PATH_PREFIX", "")

    missing = []
    if not region:
        missing.append("AWS_REGION")
    if not bucket:
        missing.append("S3_BUCKET")

    if missing:
        raise ValueError(f"Missing required environment variables: {', '.join(missing)}")

    return region, bucket, prefix


def get_s3_client(region: str):
    """Get S3 client using standard credential chain."""
    return boto3.client("s3", region_name=region)


def cmd_upload(args, region: str, bucket: str, prefix: str) -> None:
    """Upload a file to S3."""
    local_path = Path(args.file)
    if not local_path.exists():
        raise FileNotFoundError(f"File not found: {local_path}")

    if args.key:
        s3_key = args.key
    else:
        s3_key = f"{prefix}{local_path.name}"

    s3 = get_s3_client(region)
    s3.upload_file(str(local_path), bucket, s3_key)

    s3_uri = f"s3://{bucket}/{s3_key}"
    logger.info("Uploaded %s -> %s", local_path, s3_uri)
    print(s3_uri)


def cmd_download(args, region: str, bucket: str, prefix: str) -> None:
    """Download a file from S3."""
    s3 = get_s3_client(region)
    s3.download_file(bucket, args.s3_key, args.local_path)
    logger.info("Downloaded s3://%s/%s -> %s", bucket, args.s3_key, args.local_path)
    print(f"Downloaded to {args.local_path}")


def cmd_list(args, region: str, bucket: str, prefix: str) -> None:
    """List objects in S3."""
    list_prefix = args.prefix if args.prefix else prefix

    s3 = get_s3_client(region)
    paginator = s3.get_paginator("list_objects_v2")

    count = 0
    for page in paginator.paginate(Bucket=bucket, Prefix=list_prefix):
        for obj in page.get("Contents", []):
            print(obj["Key"])
            count += 1

    logger.info("Listed %d objects with prefix '%s'", count, list_prefix)


def cmd_delete(args, region: str, bucket: str, prefix: str) -> None:
    """Delete an object from S3."""
    s3 = get_s3_client(region)
    s3.delete_object(Bucket=bucket, Key=args.s3_key)
    logger.info("Deleted s3://%s/%s", bucket, args.s3_key)
    print(f"Deleted {args.s3_key}")


def main():
    parser = argparse.ArgumentParser(
        description="S3 operations using standard AWS credential chain",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
This script uses the standard AWS SDK credential chain. To use with OIDC:

  1. Configure credential_process (recommended):
     Create ~/.aws/config:
       [profile oidc-s3]
       credential_process = /path/to/oidc_credential_provider.py get-credentials

     Then: AWS_PROFILE=oidc-s3 %(prog)s upload file.txt

  2. Or use environment variables from credential daemon:
     source /var/run/aws-creds/aws-credentials.env
     %(prog)s upload file.txt

Examples:
  %(prog)s upload /path/to/file.txt
  %(prog)s upload /path/to/file.txt --key custom/path/file.txt
  %(prog)s download backups/file.txt /tmp/file.txt
  %(prog)s list
  %(prog)s list --prefix logs/
  %(prog)s delete old-file.txt

Environment:
  AWS_REGION       - AWS region (required)
  S3_BUCKET        - S3 bucket name (required)
  S3_PATH_PREFIX   - Default prefix for uploads (optional)
        """,
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # Upload command
    upload_parser = subparsers.add_parser("upload", help="Upload a file to S3")
    upload_parser.add_argument("file", help="Local file to upload")
    upload_parser.add_argument("--key", help="Custom S3 key (default: prefix + filename)")

    # Download command
    download_parser = subparsers.add_parser("download", help="Download a file from S3")
    download_parser.add_argument("s3_key", help="S3 object key to download")
    download_parser.add_argument("local_path", help="Local path to save the file")

    # List command
    list_parser = subparsers.add_parser("list", help="List objects in S3")
    list_parser.add_argument("--prefix", help="Prefix to filter (default: S3_PATH_PREFIX)")

    # Delete command
    delete_parser = subparsers.add_parser("delete", help="Delete an object from S3")
    delete_parser.add_argument("s3_key", help="S3 object key to delete")

    args = parser.parse_args()

    try:
        region, bucket, prefix = get_config()

        if args.command == "upload":
            cmd_upload(args, region, bucket, prefix)
        elif args.command == "download":
            cmd_download(args, region, bucket, prefix)
        elif args.command == "list":
            cmd_list(args, region, bucket, prefix)
        elif args.command == "delete":
            cmd_delete(args, region, bucket, prefix)

    except ValueError as e:
        logger.error(str(e))
        sys.exit(1)
    except ClientError as e:
        logger.error("AWS error: %s", e)
        sys.exit(1)
    except Exception as e:
        logger.exception("Error: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
