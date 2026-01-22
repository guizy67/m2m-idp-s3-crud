#!/usr/bin/env python3
"""
OIDC Credential Provider for AWS using Auth0 or Cognito.

This script provides AWS credentials via OIDC federation. It can run as:
1. A credential_process provider (recommended for log shippers)
2. A credential file daemon (writes credentials to files periodically)
3. A token file daemon (Auth0 only, for AWS_WEB_IDENTITY_TOKEN_FILE)

Requirements:
    pip install boto3 requests

Configuration via environment variables:

    Common:
        IDP_TYPE             - Identity provider: "auth0" or "cognito" (default: "auth0")
        AWS_REGION           - AWS region (e.g., "eu-west-1")

    Auth0-specific (uses AssumeRoleWithWebIdentity):
        AUTH0_DOMAIN         - Auth0 tenant domain (e.g., "your-tenant.auth0.com")
        AUTH0_CLIENT_ID      - Auth0 M2M application client ID
        AUTH0_CLIENT_SECRET  - Auth0 M2M application client secret
        AUTH0_AUDIENCE       - Auth0 API identifier
        AWS_ROLE_ARN         - IAM role ARN to assume

    Cognito-specific (uses credential vending API):
        COGNITO_DOMAIN              - Cognito User Pool domain prefix
        COGNITO_CLIENT_ID           - Cognito app client ID
        COGNITO_CLIENT_SECRET       - Cognito app client secret
        COGNITO_RESOURCE_SERVER     - Cognito resource server identifier
        COGNITO_CREDENTIAL_API_URL  - Credential vending API URL
"""

import argparse
import base64
import json
import logging
import os
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

import boto3
import requests

# Configure logging - use stderr so stdout is clean for credential_process
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    stream=sys.stderr,
)
logger = logging.getLogger(__name__)


@dataclass
class Config:
    """Configuration loaded from environment variables."""

    idp_type: str  # "auth0" or "cognito"
    aws_region: str

    # Auth0-specific
    auth0_domain: Optional[str] = None
    auth0_client_id: Optional[str] = None
    auth0_client_secret: Optional[str] = None
    auth0_audience: Optional[str] = None
    aws_role_arn: Optional[str] = None

    # Cognito-specific
    cognito_domain: Optional[str] = None
    cognito_client_id: Optional[str] = None
    cognito_client_secret: Optional[str] = None
    cognito_resource_server: Optional[str] = None
    cognito_credential_api_url: Optional[str] = None

    @classmethod
    def from_env(cls) -> "Config":
        """Load configuration from environment variables."""
        idp_type = os.environ.get("IDP_TYPE", "auth0").lower()

        missing = []
        if not os.environ.get("AWS_REGION"):
            missing.append("AWS_REGION")

        if idp_type == "auth0":
            auth0_required = [
                "AUTH0_DOMAIN",
                "AUTH0_CLIENT_ID",
                "AUTH0_CLIENT_SECRET",
                "AUTH0_AUDIENCE",
                "AWS_ROLE_ARN",
            ]
            missing.extend([var for var in auth0_required if not os.environ.get(var)])
        elif idp_type == "cognito":
            cognito_required = [
                "COGNITO_DOMAIN",
                "COGNITO_CLIENT_ID",
                "COGNITO_CLIENT_SECRET",
                "COGNITO_RESOURCE_SERVER",
                "COGNITO_CREDENTIAL_API_URL",
            ]
            missing.extend([var for var in cognito_required if not os.environ.get(var)])
        else:
            raise ValueError(f"Invalid IDP_TYPE: {idp_type}. Must be 'auth0' or 'cognito'")

        if missing:
            raise ValueError(f"Missing required environment variables: {', '.join(missing)}")

        return cls(
            idp_type=idp_type,
            aws_region=os.environ["AWS_REGION"],
            auth0_domain=os.environ.get("AUTH0_DOMAIN"),
            auth0_client_id=os.environ.get("AUTH0_CLIENT_ID"),
            auth0_client_secret=os.environ.get("AUTH0_CLIENT_SECRET"),
            auth0_audience=os.environ.get("AUTH0_AUDIENCE"),
            aws_role_arn=os.environ.get("AWS_ROLE_ARN"),
            cognito_domain=os.environ.get("COGNITO_DOMAIN"),
            cognito_client_id=os.environ.get("COGNITO_CLIENT_ID"),
            cognito_client_secret=os.environ.get("COGNITO_CLIENT_SECRET"),
            cognito_resource_server=os.environ.get("COGNITO_RESOURCE_SERVER"),
            cognito_credential_api_url=os.environ.get("COGNITO_CREDENTIAL_API_URL"),
        )


@dataclass
class CachedCredentials:
    """AWS temporary credentials with expiration tracking."""

    access_key_id: str
    secret_access_key: str
    session_token: str
    expiration: datetime


class OidcCredentialProvider:
    """
    Provides AWS credentials via OIDC federation with Auth0 or Cognito.

    Handles token acquisition, credential exchange, and caching automatically.
    """

    REFRESH_BUFFER = timedelta(minutes=5)

    def __init__(self, config: Config):
        self.config = config
        self._oidc_token: Optional[str] = None
        self._oidc_expires: Optional[datetime] = None
        self._aws_creds: Optional[CachedCredentials] = None

    def get_oidc_token(self) -> str:
        """Get OIDC token from the configured IdP, using cache if valid."""
        now = datetime.now(timezone.utc)

        if self._oidc_token and self._oidc_expires:
            if now < self._oidc_expires - self.REFRESH_BUFFER:
                return self._oidc_token

        if self.config.idp_type == "auth0":
            return self._get_auth0_token(now)
        else:
            return self._get_cognito_token(now)

    def _get_auth0_token(self, now: datetime) -> str:
        """Get OIDC token from Auth0."""
        logger.info("Fetching new OIDC token from Auth0")
        token_url = f"https://{self.config.auth0_domain}/oauth/token"

        response = requests.post(
            token_url,
            json={
                "grant_type": "client_credentials",
                "client_id": self.config.auth0_client_id,
                "client_secret": self.config.auth0_client_secret,
                "audience": self.config.auth0_audience,
            },
            headers={"Content-Type": "application/json"},
            timeout=30,
        )
        response.raise_for_status()
        result = response.json()

        if "access_token" not in result:
            raise RuntimeError(f"Auth0 token request failed: {result}")

        self._oidc_token = result["access_token"]
        expires_in = result.get("expires_in", 86400)
        self._oidc_expires = now + timedelta(seconds=expires_in)

        logger.info("Got Auth0 token (expires in %d seconds)", expires_in)
        return self._oidc_token

    def _get_cognito_token(self, now: datetime) -> str:
        """Get OIDC token from AWS Cognito."""
        logger.info("Fetching new OIDC token from Cognito")

        token_url = f"https://{self.config.cognito_domain}.auth.{self.config.aws_region}.amazoncognito.com/oauth2/token"

        credentials = base64.b64encode(
            f"{self.config.cognito_client_id}:{self.config.cognito_client_secret}".encode()
        ).decode()

        scope = f"{self.config.cognito_resource_server}/write {self.config.cognito_resource_server}/read {self.config.cognito_resource_server}/delete {self.config.cognito_resource_server}/list"

        response = requests.post(
            token_url,
            data={
                "grant_type": "client_credentials",
                "scope": scope,
            },
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "Authorization": f"Basic {credentials}",
            },
            timeout=30,
        )
        response.raise_for_status()
        result = response.json()

        if "access_token" not in result:
            raise RuntimeError(f"Cognito token request failed: {result}")

        self._oidc_token = result["access_token"]
        expires_in = result.get("expires_in", 86400)
        self._oidc_expires = now + timedelta(seconds=expires_in)

        logger.info("Got Cognito token (expires in %d seconds)", expires_in)
        return self._oidc_token

    def get_aws_credentials(self) -> CachedCredentials:
        """Get AWS credentials, using cache if valid."""
        now = datetime.now(timezone.utc)

        if self._aws_creds:
            if now < self._aws_creds.expiration - self.REFRESH_BUFFER:
                return self._aws_creds

        if self.config.idp_type == "auth0":
            return self._get_aws_credentials_auth0()
        else:
            return self._get_aws_credentials_cognito()

    def _get_aws_credentials_auth0(self) -> CachedCredentials:
        """Exchange Auth0 OIDC token for AWS credentials via STS."""
        logger.info("Exchanging Auth0 token for AWS credentials via STS")
        oidc_token = self.get_oidc_token()

        sts = boto3.client("sts", region_name=self.config.aws_region)
        response = sts.assume_role_with_web_identity(
            RoleArn=self.config.aws_role_arn,
            RoleSessionName="oidc-credential-provider",
            WebIdentityToken=oidc_token,
            DurationSeconds=3600,
        )

        creds = response["Credentials"]
        self._aws_creds = CachedCredentials(
            access_key_id=creds["AccessKeyId"],
            secret_access_key=creds["SecretAccessKey"],
            session_token=creds["SessionToken"],
            expiration=creds["Expiration"],
        )

        logger.info("Got AWS credentials (expires: %s)", creds["Expiration"])
        return self._aws_creds

    def _get_aws_credentials_cognito(self) -> CachedCredentials:
        """Exchange Cognito token for AWS credentials via credential vending API."""
        logger.info("Exchanging Cognito token for AWS credentials via credential vending API")
        oidc_token = self.get_oidc_token()

        response = requests.post(
            self.config.cognito_credential_api_url,
            json={"access_token": oidc_token},
            headers={"Content-Type": "application/json"},
            timeout=30,
        )
        response.raise_for_status()
        result = response.json()

        if "error" in result:
            raise RuntimeError(f"Credential vending API error: {result['error']}")

        creds = result["credentials"]
        expiration = datetime.fromisoformat(creds["expiration"].replace("Z", "+00:00"))

        self._aws_creds = CachedCredentials(
            access_key_id=creds["access_key_id"],
            secret_access_key=creds["secret_access_key"],
            session_token=creds["session_token"],
            expiration=expiration,
        )

        logger.info("Got AWS credentials (expires: %s)", expiration)
        return self._aws_creds


def _atomic_write(path: Path, content: str) -> None:
    """Write file atomically to avoid partial reads."""
    tmp_path = path.with_suffix(".tmp")
    tmp_path.write_text(content)
    tmp_path.rename(path)


def cmd_get_credentials(provider: OidcCredentialProvider) -> None:
    """
    Output credentials for AWS SDK credential_process.

    Prints JSON to stdout in the format expected by credential_process.
    This is the recommended approach for log shippers (Vector, Fluent Bit, etc.)
    as it enables automatic credential refresh.
    """
    creds = provider.get_aws_credentials()

    output = {
        "Version": 1,
        "AccessKeyId": creds.access_key_id,
        "SecretAccessKey": creds.secret_access_key,
        "SessionToken": creds.session_token,
        "Expiration": creds.expiration.isoformat(),
    }

    print(json.dumps(output))


def cmd_credential_daemon(provider: OidcCredentialProvider, creds_dir: str, interval: int) -> None:
    """
    Run as a daemon that refreshes AWS credentials periodically.

    Writes credentials to files that can be used via AWS_SHARED_CREDENTIALS_FILE.
    Works with both Auth0 and Cognito.
    """
    creds_path = Path(creds_dir)
    creds_path.mkdir(parents=True, exist_ok=True)

    env_file = creds_path / "aws-credentials.env"
    json_file = creds_path / "aws-credentials.json"
    aws_creds_file = creds_path / "credentials"

    logger.info("Starting credential refresh daemon (interval: %ds)", interval)
    logger.info("Credentials directory: %s", creds_dir)
    logger.info("")
    logger.info("Usage options:")
    logger.info("  1. Set AWS_SHARED_CREDENTIALS_FILE=%s", aws_creds_file)
    logger.info("  2. Source %s", env_file)
    logger.info("")
    logger.info("NOTE: Most applications cache credentials and won't detect file changes.")
    logger.info("      Consider using 'get-credentials' with credential_process instead.")

    while True:
        try:
            creds = provider.get_aws_credentials()

            # Write env file
            env_content = f"""# AWS credentials - auto-refreshed by oidc-credential-provider
# Generated: {datetime.now(timezone.utc).isoformat()}
# Expires: {creds.expiration.isoformat()}
export AWS_ACCESS_KEY_ID="{creds.access_key_id}"
export AWS_SECRET_ACCESS_KEY="{creds.secret_access_key}"
export AWS_SESSION_TOKEN="{creds.session_token}"
export AWS_REGION="{provider.config.aws_region}"
"""
            _atomic_write(env_file, env_content)

            # Write JSON file
            json_content = json.dumps(
                {
                    "access_key_id": creds.access_key_id,
                    "secret_access_key": creds.secret_access_key,
                    "session_token": creds.session_token,
                    "expiration": creds.expiration.isoformat(),
                    "region": provider.config.aws_region,
                },
                indent=2,
            )
            _atomic_write(json_file, json_content)

            # Write AWS SDK credentials file
            aws_creds_content = f"""# AWS credentials - auto-refreshed by oidc-credential-provider
# Generated: {datetime.now(timezone.utc).isoformat()}
# Expires: {creds.expiration.isoformat()}
[default]
aws_access_key_id = {creds.access_key_id}
aws_secret_access_key = {creds.secret_access_key}
aws_session_token = {creds.session_token}
region = {provider.config.aws_region}
"""
            _atomic_write(aws_creds_file, aws_creds_content)

            logger.info("Refreshed credentials (expires: %s)", creds.expiration)

        except Exception as e:
            logger.error("Failed to refresh credentials: %s", e)

        time.sleep(interval)


def cmd_token_daemon(provider: OidcCredentialProvider, token_path: str, interval: int) -> None:
    """
    Run as a daemon that refreshes the OIDC token periodically.

    This is for use with AWS_WEB_IDENTITY_TOKEN_FILE.
    Only works with Auth0 (Cognito tokens cannot be used with AssumeRoleWithWebIdentity).
    """
    if provider.config.idp_type != "auth0":
        logger.error("Token daemon only works with Auth0.")
        logger.error("Cognito requires the credential vending API - use 'get-credentials' or 'credential-daemon' instead.")
        sys.exit(1)

    token_file = Path(token_path)

    logger.info("Starting token refresh daemon (interval: %ds)", interval)
    logger.info("Token file: %s", token_path)
    logger.info("")
    logger.info("Configure your application with:")
    logger.info("  AWS_WEB_IDENTITY_TOKEN_FILE=%s", token_path)
    logger.info("  AWS_ROLE_ARN=%s", provider.config.aws_role_arn)

    while True:
        try:
            token = provider.get_oidc_token()
            token_file.parent.mkdir(parents=True, exist_ok=True)
            _atomic_write(token_file, token)
            logger.info("Wrote OIDC token to %s", token_path)

        except Exception as e:
            logger.error("Failed to refresh token: %s", e)

        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(
        description="OIDC Credential Provider for AWS using Auth0 or Cognito",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Modes of operation:

  get-credentials (RECOMMENDED for log shippers)
    Outputs credentials in AWS SDK credential_process format.
    The AWS SDK calls this script when credentials are needed/expired.

    Setup:
      1. Create ~/.aws/config:
         [profile oidc-s3]
         credential_process = /path/to/oidc_credential_provider.py get-credentials

      2. Set AWS_CONFIG_FILE and AWS_PROFILE for your application

  credential-daemon
    Writes credentials to files periodically.
    NOTE: Most apps cache credentials and won't detect file changes.

  token-daemon (Auth0 only)
    Writes OIDC token for AWS_WEB_IDENTITY_TOKEN_FILE.

Examples:
  # For log shippers (Vector, Fluent Bit, etc.)
  %(prog)s get-credentials

  # Write credentials to files (45-minute refresh)
  %(prog)s credential-daemon --creds-dir /var/run/aws-creds

  # Write OIDC token for web identity (Auth0 only)
  %(prog)s token-daemon --token-file /var/run/oidc/token

Environment:
  IDP_TYPE=auth0|cognito (default: auth0)
  See module docstring for IdP-specific variables.
        """,
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # get-credentials command
    subparsers.add_parser(
        "get-credentials",
        help="Output credentials for AWS SDK credential_process (recommended)",
    )

    # credential-daemon command
    cred_daemon = subparsers.add_parser(
        "credential-daemon",
        help="Run as credential file refresh daemon",
    )
    cred_daemon.add_argument(
        "--creds-dir",
        default="/var/run/aws-creds",
        help="Directory to write credential files (default: /var/run/aws-creds)",
    )
    cred_daemon.add_argument(
        "--interval",
        type=int,
        default=2700,
        help="Refresh interval in seconds (default: 2700 = 45 minutes)",
    )

    # token-daemon command
    token_daemon = subparsers.add_parser(
        "token-daemon",
        help="Run as OIDC token refresh daemon (Auth0 only)",
    )
    token_daemon.add_argument(
        "--token-file",
        default="/var/run/oidc/token",
        help="Path to write the OIDC token (default: /var/run/oidc/token)",
    )
    token_daemon.add_argument(
        "--interval",
        type=int,
        default=3600,
        help="Refresh interval in seconds (default: 3600)",
    )

    args = parser.parse_args()

    try:
        config = Config.from_env()
        provider = OidcCredentialProvider(config)

        if args.command == "get-credentials":
            cmd_get_credentials(provider)

        elif args.command == "credential-daemon":
            cmd_credential_daemon(provider, args.creds_dir, args.interval)

        elif args.command == "token-daemon":
            cmd_token_daemon(provider, args.token_file, args.interval)

    except ValueError as e:
        logger.error(str(e))
        sys.exit(1)
    except Exception as e:
        logger.exception("Error: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
