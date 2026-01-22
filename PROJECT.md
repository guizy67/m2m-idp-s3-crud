This is a solid approach for credential-free access from on-prem to AWS. Let me walk you through a complete working example.

## Overview

```
Ubuntu Server                    Entra ID                         AWS
     │                              │                              │
     ├──── Client Credentials ─────►│                              │
     │     (client_id + secret)     │                              │
     │◄──── OIDC Token (JWT) ───────┤                              │
     │                              │                              │
     ├──────────── AssumeRoleWithWebIdentity ─────────────────────►│
     │             (with OIDC token)                               │
     │◄─────────── Temporary Credentials ──────────────────────────┤
     │                                                             │
     ├──────────── S3 PutObject ──────────────────────────────────►│
```

## Step 1: Entra ID Setup

### 1a. Create App Registration

In Azure Portal → Entra ID → App registrations → New registration:
- Name: `aws-s3-uploader`
- Supported account types: Single tenant
- No redirect URI needed for client credentials flow

Note down:
- **Application (client) ID**: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
- **Directory (tenant) ID**: `yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy`

### 1b. Create Client Secret

In your App Registration → Certificates & secrets → New client secret
- Note down the **secret value** (you only see it once)

### 1c. Expose an API (Critical for AWS)

This is the part people often miss. AWS needs the token's `aud` (audience) claim to match what you configure in the OIDC provider.

In App Registration → Expose an API → Set Application ID URI:
```
api://aws-s3-uploader
```

## Step 2: AWS Setup

### 2a. Create OIDC Identity Provider

```bash
aws iam create-open-id-connect-provider \
  --url "https://login.microsoftonline.com/YOUR_TENANT_ID/v2.0" \
  --client-id-list "api://aws-s3-uploader" \
  --thumbprint-list "YOUR_THUMBPRINT"
```

To get the thumbprint (or skip it - AWS now auto-fetches for known providers):
```bash
# Often you can use a placeholder for Microsoft's well-known endpoint
# AWS validates against Microsoft's published JWKS
```

### 2b. Create IAM Role with Trust Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/login.microsoftonline.com/YOUR_TENANT_ID/v2.0"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "login.microsoftonline.com/YOUR_TENANT_ID/v2.0:aud": "api://aws-s3-uploader",
          "login.microsoftonline.com/YOUR_TENANT_ID/v2.0:sub": "YOUR_SERVICE_PRINCIPAL_OBJECT_ID"
        }
      }
    }
  ]
}
```

> **Note**: The `sub` claim in Entra tokens is the **Object ID** of the service principal (found in Enterprise Applications, not the App Registration's client ID).

### 2c. Attach S3 Policy to Role

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::your-bucket-name/*"
    }
  ]
}
```

## Step 3: Python Code on Ubuntu Server

### Install dependencies

```bash
pip install msal boto3 requests
```

### The actual code

```python
#!/usr/bin/env python3
"""
On-prem S3 uploader using Entra ID OIDC federation
"""

import msal
import boto3
import json
from pathlib import Path

# =============================================================================
# Configuration
# =============================================================================

ENTRA_CONFIG = {
    "tenant_id": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy",
    "client_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "client_secret": "your-client-secret-here",
    # The scope must match your "Expose an API" Application ID URI
    # Adding /.default requests all configured permissions
    "scope": ["api://aws-s3-uploader/.default"]
}

AWS_CONFIG = {
    "role_arn": "arn:aws:iam::123456789012:role/EntraS3UploaderRole",
    "region": "eu-west-1",
    "bucket": "your-bucket-name"
}


# =============================================================================
# Step 1: Get OIDC token from Entra ID
# =============================================================================

def get_entra_token() -> str:
    """
    Authenticate to Entra ID using client credentials flow.
    Returns a JWT access token.
    """
    authority = f"https://login.microsoftonline.com/{ENTRA_CONFIG['tenant_id']}"
    
    app = msal.ConfidentialClientApplication(
        client_id=ENTRA_CONFIG["client_id"],
        client_credential=ENTRA_CONFIG["client_secret"],
        authority=authority
    )
    
    result = app.acquire_token_for_client(scopes=ENTRA_CONFIG["scope"])
    
    if "access_token" not in result:
        raise Exception(f"Failed to get token: {result.get('error_description', result)}")
    
    print("✓ Got OIDC token from Entra ID")
    
    # Optional: decode and inspect the token (don't do this in prod)
    # import base64
    # payload = result["access_token"].split(".")[1]
    # payload += "=" * (4 - len(payload) % 4)  # Fix padding
    # print(json.dumps(json.loads(base64.urlsafe_b64decode(payload)), indent=2))
    
    return result["access_token"]


# =============================================================================
# Step 2: Exchange OIDC token for AWS credentials
# =============================================================================

def get_aws_credentials(oidc_token: str) -> dict:
    """
    Call AWS STS AssumeRoleWithWebIdentity to exchange the Entra token
    for temporary AWS credentials.
    """
    sts = boto3.client("sts", region_name=AWS_CONFIG["region"])
    
    response = sts.assume_role_with_web_identity(
        RoleArn=AWS_CONFIG["role_arn"],
        RoleSessionName="on-prem-uploader",
        WebIdentityToken=oidc_token,
        DurationSeconds=3600  # 1 hour, max depends on role config
    )
    
    creds = response["Credentials"]
    print(f"✓ Got AWS credentials (expires: {creds['Expiration']})")
    
    return {
        "aws_access_key_id": creds["AccessKeyId"],
        "aws_secret_access_key": creds["SecretAccessKey"],
        "aws_session_token": creds["SessionToken"]
    }


# =============================================================================
# Step 3: Upload to S3
# =============================================================================

def upload_to_s3(credentials: dict, local_path: str, s3_key: str):
    """
    Upload a file to S3 using the temporary credentials.
    """
    s3 = boto3.client(
        "s3",
        region_name=AWS_CONFIG["region"],
        aws_access_key_id=credentials["aws_access_key_id"],
        aws_secret_access_key=credentials["aws_secret_access_key"],
        aws_session_token=credentials["aws_session_token"]
    )
    
    s3.upload_file(local_path, AWS_CONFIG["bucket"], s3_key)
    print(f"✓ Uploaded {local_path} → s3://{AWS_CONFIG['bucket']}/{s3_key}")


# =============================================================================
# Main
# =============================================================================

def main():
    # Step 1: Get OIDC token from Entra
    oidc_token = get_entra_token()
    
    # Step 2: Exchange for AWS credentials
    aws_creds = get_aws_credentials(oidc_token)
    
    # Step 3: Upload file
    upload_to_s3(aws_creds, "/tmp/testfile.txt", "uploads/testfile.txt")


if __name__ == "__main__":
    main()
```

## Debugging Tips

### Inspect the JWT token

```python
import base64
import json

def decode_jwt(token):
    """Decode JWT payload (without verification) for debugging"""
    payload = token.split(".")[1]
    payload += "=" * (4 - len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))

token = get_entra_token()
claims = decode_jwt(token)
print(json.dumps(claims, indent=2))
```

You should see something like:
```json
{
  "aud": "api://aws-s3-uploader",
  "iss": "https://login.microsoftonline.com/YOUR_TENANT_ID/v2.0",
  "sub": "object-id-of-service-principal",
  "exp": 1234567890,
  ...
}
```

### Common errors

| Error | Cause | Fix |
|-------|-------|-----|
| `InvalidIdentityToken` | `aud` claim doesn't match OIDC provider's client-id-list | Ensure the scope in your code matches what you configured in AWS |
| `AccessDenied` on AssumeRole | Trust policy conditions don't match token claims | Check `sub` is the Object ID from Enterprise Applications |
| `ExpiredToken` | Token TTL exceeded | Tokens are valid for ~1 hour; refresh before calling STS |

## Production Considerations

1. **Don't hardcode secrets** - use environment variables or a secrets manager
2. **Cache and refresh tokens** - MSAL handles this if you reuse the `app` instance
3. **Cache AWS credentials** - they're valid for up to 12 hours depending on role config
4. **Use certificate auth instead of client secret** for better security

Want me to expand on any part, like setting up certificate-based auth or adding automatic credential refresh?



Sure! Auth0 is actually a bit simpler to configure for this use case. Here's the complete setup.

## Overview

```
Ubuntu Server                    Auth0                            AWS
     │                              │                              │
     ├──── Client Credentials ─────►│                              │
     │     (client_id + secret)     │                              │
     │◄──── OIDC Token (JWT) ───────┤                              │
     │                              │                              │
     ├──────────── AssumeRoleWithWebIdentity ─────────────────────►│
     │             (with OIDC token)                               │
     │◄─────────── Temporary Credentials ──────────────────────────┤
     │                                                             │
     ├──────────── S3 PutObject ──────────────────────────────────►│
```

## Step 1: Auth0 Setup

### 1a. Create an API

In Auth0 Dashboard → Applications → APIs → Create API:

- **Name**: `aws-s3-uploader`
- **Identifier**: `https://aws-s3-uploader` (this becomes the `aud` claim)
- **Signing Algorithm**: RS256

Note down the **Identifier** - you'll need it for AWS and your code.

### 1b. Create a Machine-to-Machine Application

In Auth0 Dashboard → Applications → Applications → Create Application:

- **Name**: `on-prem-s3-uploader`
- **Type**: Machine to Machine

Then:
1. Select the API you just created (`aws-s3-uploader`)
2. No specific scopes needed for this use case (or create custom ones if you want)

Note down:
- **Domain**: `your-tenant.auth0.com`
- **Client ID**: `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`
- **Client Secret**: `yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy`

### 1c. Verify OIDC Discovery

Auth0 exposes standard OIDC endpoints. Verify it works:

```bash
curl https://your-tenant.auth0.com/.well-known/openid-configuration
```

You should see the `issuer`, `token_endpoint`, `jwks_uri`, etc.

## Step 2: AWS Setup

### 2a. Create OIDC Identity Provider

```bash
aws iam create-open-id-connect-provider \
  --url "https://your-tenant.auth0.com/" \
  --client-id-list "https://aws-s3-uploader" \
  --thumbprint-list "933c6ddee95c9c41a40f9f50493d82be03ad87bf"
```

> **Note**: The `client-id-list` is the **API Identifier** (audience), not the application's client_id. The thumbprint is for Auth0's certificate - AWS may auto-fetch this for well-known providers.

### 2b. Create IAM Role with Trust Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/your-tenant.auth0.com/"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "your-tenant.auth0.com/:aud": "https://aws-s3-uploader"
        },
        "StringLike": {
          "your-tenant.auth0.com/:sub": "*"
        }
      }
    }
  ]
}
```

> **Note**: For machine-to-machine tokens, Auth0 sets `sub` to `CLIENT_ID@clients`. You can lock it down further:
> ```json
> "your-tenant.auth0.com/:sub": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx@clients"
> ```

### 2c. Attach S3 Policy to Role

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::your-bucket-name/*"
    }
  ]
}
```

## Step 3: Python Code on Ubuntu Server

### Install dependencies

```bash
pip install boto3 requests
```

Auth0 doesn't need a special SDK - it's just a standard OAuth2 token endpoint.

### The actual code

```python
#!/usr/bin/env python3
"""
On-prem S3 uploader using Auth0 OIDC federation
"""

import boto3
import requests
import json
from pathlib import Path

# =============================================================================
# Configuration
# =============================================================================

AUTH0_CONFIG = {
    "domain": "your-tenant.auth0.com",
    "client_id": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "client_secret": "your-client-secret-here",
    # The audience is your API Identifier from Auth0
    "audience": "https://aws-s3-uploader"
}

AWS_CONFIG = {
    "role_arn": "arn:aws:iam::123456789012:role/Auth0S3UploaderRole",
    "region": "eu-west-1",
    "bucket": "your-bucket-name"
}


# =============================================================================
# Step 1: Get OIDC token from Auth0
# =============================================================================

def get_auth0_token() -> str:
    """
    Authenticate to Auth0 using client credentials flow.
    Returns a JWT access token.
    """
    token_url = f"https://{AUTH0_CONFIG['domain']}/oauth/token"
    
    payload = {
        "grant_type": "client_credentials",
        "client_id": AUTH0_CONFIG["client_id"],
        "client_secret": AUTH0_CONFIG["client_secret"],
        "audience": AUTH0_CONFIG["audience"]
    }
    
    headers = {"Content-Type": "application/json"}
    
    response = requests.post(token_url, json=payload, headers=headers)
    response.raise_for_status()
    
    result = response.json()
    
    if "access_token" not in result:
        raise Exception(f"Failed to get token: {result}")
    
    print("✓ Got OIDC token from Auth0")
    return result["access_token"]


# =============================================================================
# Step 2: Exchange OIDC token for AWS credentials
# =============================================================================

def get_aws_credentials(oidc_token: str) -> dict:
    """
    Call AWS STS AssumeRoleWithWebIdentity to exchange the Auth0 token
    for temporary AWS credentials.
    """
    sts = boto3.client("sts", region_name=AWS_CONFIG["region"])
    
    response = sts.assume_role_with_web_identity(
        RoleArn=AWS_CONFIG["role_arn"],
        RoleSessionName="on-prem-uploader",
        WebIdentityToken=oidc_token,
        DurationSeconds=3600
    )
    
    creds = response["Credentials"]
    print(f"✓ Got AWS credentials (expires: {creds['Expiration']})")
    
    return {
        "aws_access_key_id": creds["AccessKeyId"],
        "aws_secret_access_key": creds["SecretAccessKey"],
        "aws_session_token": creds["SessionToken"]
    }


# =============================================================================
# Step 3: Upload to S3
# =============================================================================

def upload_to_s3(credentials: dict, local_path: str, s3_key: str):
    """
    Upload a file to S3 using the temporary credentials.
    """
    s3 = boto3.client(
        "s3",
        region_name=AWS_CONFIG["region"],
        aws_access_key_id=credentials["aws_access_key_id"],
        aws_secret_access_key=credentials["aws_secret_access_key"],
        aws_session_token=credentials["aws_session_token"]
    )
    
    s3.upload_file(local_path, AWS_CONFIG["bucket"], s3_key)
    print(f"✓ Uploaded {local_path} → s3://{AWS_CONFIG['bucket']}/{s3_key}")


# =============================================================================
# Main
# =============================================================================

def main():
    # Step 1: Get OIDC token from Auth0
    oidc_token = get_auth0_token()
    
    # Step 2: Exchange for AWS credentials
    aws_creds = get_aws_credentials(oidc_token)
    
    # Step 3: Upload file
    upload_to_s3(aws_creds, "/tmp/testfile.txt", "uploads/testfile.txt")


if __name__ == "__main__":
    main()
```

## Debugging

### Inspect the Auth0 JWT

```python
import base64
import json

def decode_jwt(token):
    """Decode JWT payload (without verification) for debugging"""
    payload = token.split(".")[1]
    payload += "=" * (4 - len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))

token = get_auth0_token()
claims = decode_jwt(token)
print(json.dumps(claims, indent=2))
```

Expected output:
```json
{
  "iss": "https://your-tenant.auth0.com/",
  "sub": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx@clients",
  "aud": "https://aws-s3-uploader",
  "iat": 1234567890,
  "exp": 1234654290,
  "gty": "client-credentials",
  "azp": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}
```

### Common Auth0-specific errors

| Error | Cause | Fix |
|-------|-------|-----|
| `access_denied` from Auth0 | Application not authorized for the API | Go to API → Machine to Machine Applications → Authorize your app |
| `InvalidIdentityToken` from AWS | Issuer URL mismatch | Auth0 issuer has a trailing slash - make sure your OIDC provider URL matches exactly |
| `InvalidIdentityToken` - audience | `aud` doesn't match `client-id-list` | Use the API Identifier as the client-id in AWS OIDC provider |

## Key Differences: Auth0 vs Entra ID

| Aspect | Auth0 | Entra ID |
|--------|-------|----------|
| Token endpoint | `/oauth/token` | `/oauth2/v2.0/token` |
| Audience config | API Identifier | "Expose an API" Application ID URI |
| `sub` claim | `{client_id}@clients` | Service Principal Object ID |
| SDK needed | No (standard HTTP) | MSAL recommended |
| Issuer URL | Has trailing slash | No trailing slash |

## Production Version with Caching

Here's a more robust version that caches both tokens:

```python
#!/usr/bin/env python3
"""
Production-ready S3 uploader with token caching
"""

import boto3
import requests
from datetime import datetime, timezone, timedelta
from dataclasses import dataclass
from typing import Optional


@dataclass
class CachedCredentials:
    access_key_id: str
    secret_access_key: str
    session_token: str
    expiration: datetime


class Auth0S3Uploader:
    def __init__(self, auth0_config: dict, aws_config: dict):
        self.auth0 = auth0_config
        self.aws = aws_config
        self._oidc_token: Optional[str] = None
        self._oidc_expires: Optional[datetime] = None
        self._aws_creds: Optional[CachedCredentials] = None
    
    def _get_oidc_token(self) -> str:
        """Get OIDC token, using cache if valid."""
        now = datetime.now(timezone.utc)
        
        # Return cached token if still valid (with 5 min buffer)
        if self._oidc_token and self._oidc_expires:
            if now < self._oidc_expires - timedelta(minutes=5):
                return self._oidc_token
        
        # Fetch new token
        response = requests.post(
            f"https://{self.auth0['domain']}/oauth/token",
            json={
                "grant_type": "client_credentials",
                "client_id": self.auth0["client_id"],
                "client_secret": self.auth0["client_secret"],
                "audience": self.auth0["audience"]
            },
            headers={"Content-Type": "application/json"}
        )
        response.raise_for_status()
        result = response.json()
        
        self._oidc_token = result["access_token"]
        # Auth0 tokens typically expire in 24 hours
        self._oidc_expires = now + timedelta(seconds=result.get("expires_in", 86400))
        
        return self._oidc_token
    
    def _get_aws_credentials(self) -> CachedCredentials:
        """Get AWS credentials, using cache if valid."""
        now = datetime.now(timezone.utc)
        
        # Return cached creds if still valid (with 5 min buffer)
        if self._aws_creds:
            if now < self._aws_creds.expiration - timedelta(minutes=5):
                return self._aws_creds
        
        # Exchange OIDC token for AWS credentials
        oidc_token = self._get_oidc_token()
        sts = boto3.client("sts", region_name=self.aws["region"])
        
        response = sts.assume_role_with_web_identity(
            RoleArn=self.aws["role_arn"],
            RoleSessionName="on-prem-uploader",
            WebIdentityToken=oidc_token,
            DurationSeconds=3600
        )
        
        creds = response["Credentials"]
        self._aws_creds = CachedCredentials(
            access_key_id=creds["AccessKeyId"],
            secret_access_key=creds["SecretAccessKey"],
            session_token=creds["SessionToken"],
            expiration=creds["Expiration"]
        )
        
        return self._aws_creds
    
    def get_s3_client(self):
        """Get an S3 client with fresh credentials."""
        creds = self._get_aws_credentials()
        return boto3.client(
            "s3",
            region_name=self.aws["region"],
            aws_access_key_id=creds.access_key_id,
            aws_secret_access_key=creds.secret_access_key,
            aws_session_token=creds.session_token
        )
    
    def upload(self, local_path: str, s3_key: str):
        """Upload a file to S3."""
        s3 = self.get_s3_client()
        s3.upload_file(local_path, self.aws["bucket"], s3_key)
        print(f"✓ Uploaded {local_path} → s3://{self.aws['bucket']}/{s3_key}")


# Usage
if __name__ == "__main__":
    uploader = Auth0S3Uploader(
        auth0_config={
            "domain": "your-tenant.auth0.com",
            "client_id": "xxx",
            "client_secret": "yyy",
            "audience": "https://aws-s3-uploader"
        },
        aws_config={
            "role_arn": "arn:aws:iam::123456789012:role/Auth0S3UploaderRole",
            "region": "eu-west-1",
            "bucket": "your-bucket-name"
        }
    )
    
    # Can be called repeatedly - credentials are cached
    uploader.upload("/tmp/file1.txt", "uploads/file1.txt")
    uploader.upload("/tmp/file2.txt", "uploads/file2.txt")
```

Want me to show you how to set up the same pattern with Keycloak or another OIDC provider?

