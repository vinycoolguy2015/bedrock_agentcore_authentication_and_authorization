"""
JWT Lambda Authorizer for API Gateway
Validates OAuth 2.0 / JWT tokens issued by Cognito.
Used by Products API (Activity 3) and Inventory API (Activity 4).
"""

import json
import os
import time
import urllib.request
import base64


COGNITO_REGION = os.environ.get("COGNITO_REGION", "us-east-1")
COGNITO_USER_POOL_ID = os.environ.get("COGNITO_USER_POOL_ID", "")
COGNITO_APP_CLIENT_ID = os.environ.get("COGNITO_APP_CLIENT_ID", "")

JWKS_URL = f"https://cognito-idp.{COGNITO_REGION}.amazonaws.com/{COGNITO_USER_POOL_ID}/.well-known/jwks.json"

_jwks_cache = None
_jwks_cache_time = 0
JWKS_CACHE_TTL = 3600


def handler(event, context):
    token = _extract_token(event)
    if not token:
        return _deny(event)

    try:
        claims = _decode_and_verify(token)
        if not claims:
            return _deny(event)
        return _allow(event, claims)
    except Exception as e:
        print(f"Authorization failed: {e}")
        return _deny(event)


def _extract_token(event):
    auth_header = event.get("authorizationToken", "")
    if not auth_header:
        headers = event.get("headers", {})
        auth_header = headers.get("authorization", headers.get("Authorization", ""))

    if auth_header.startswith("Bearer "):
        return auth_header[7:]
    return auth_header if auth_header else None


def _decode_and_verify(token):
    parts = token.split(".")
    if len(parts) != 3:
        return None

    payload = parts[1]
    padding = 4 - len(payload) % 4
    if padding != 4:
        payload += "=" * padding

    claims = json.loads(base64.urlsafe_b64decode(payload))

    now = int(time.time())
    if claims.get("exp", 0) < now:
        print("Token expired")
        return None

    expected_iss = f"https://cognito-idp.{COGNITO_REGION}.amazonaws.com/{COGNITO_USER_POOL_ID}"
    if claims.get("iss") != expected_iss:
        print(f"Invalid issuer: {claims.get('iss')}")
        return None

    if COGNITO_APP_CLIENT_ID:
        token_client = claims.get("client_id", claims.get("aud"))
        if token_client != COGNITO_APP_CLIENT_ID:
            print(f"Invalid client_id: {token_client}")
            return None

    return claims


def _allow(event, claims):
    method_arn = event.get("methodArn", "*")
    return {
        "principalId": claims.get("sub", "user"),
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [{
                "Action": "execute-api:Invoke",
                "Effect": "Allow",
                "Resource": method_arn
            }]
        },
        "context": {
            "sub": claims.get("sub", ""),
            "scope": claims.get("scope", ""),
            "client_id": claims.get("client_id", "")
        }
    }


def _deny(event):
    method_arn = event.get("methodArn", "*")
    return {
        "principalId": "unauthorized",
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [{
                "Action": "execute-api:Invoke",
                "Effect": "Deny",
                "Resource": method_arn
            }]
        }
    }
