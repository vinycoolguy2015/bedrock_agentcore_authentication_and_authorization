# Resource Server Scopes in the Workshop

## What's a Resource Server Scope?

In OAuth 2.0, a **resource server** is an API you want to protect. A **scope** is a specific permission on that API. In Amazon Cognito, you combine them as `resource-server-identifier/scope-name`.

Think of it as a building access system:
- **Resource server** = a floor in the building (e.g., "retail-api")
- **Scope** = a room on that floor (e.g., "products.read")
- **Full scope** = the badge that gets you into that room: `retail-api/products.read`

When a service requests a token, it says *"I need access to retail-api/products.read."* Cognito checks whether that service is allowed to have that permission. If yes, the token is stamped with that scope.

## The Workshop's Two Resource Servers

The workshop uses two separate Cognito User Pools -- one for your company, one for the vendor. Each has its own resource server with its own scopes.

**Trust Domain 1 -- Your Company (Cognito D1)**

```
Resource Server Identifier: "retail-api"

Scopes:
  retail-api/products.read      Read the product catalog
  retail-api/sales.read         Read sales data
  retail-api/inventory.read     Read inventory levels
  retail-api/inventory.write    Update inventory
```

**Trust Domain 2 -- Vendor (Cognito D2)**

```
Resource Server Identifier: "inventory-api"

Scopes:
  inventory-api/inventory.read    Read vendor inventory
  inventory-api/inventory.write   Update vendor inventory
```

These two pools are completely independent. A `retail-api/products.read` scope from D1 means nothing to D2's authorizer. Cross-domain communication requires a token from the *target* domain's Cognito pool.

## Client Credentials and Scope Allowlists

Each Cognito **app client** has an allowlist of scopes it can request. This is the first gate -- even before a token is issued:

```
D1 M2M Client (7l165nkk...)
  Allowed scopes:
    retail-api/products.read
    retail-api/sales.read
    retail-api/inventory.read
    retail-api/inventory.write

D1 Products Backend Client (6q5fat5i...)
  Allowed scopes:
    retail-api/products.read         <-- can ONLY read products

D2 M2M Client (7ll3a3ie...)
  Allowed scopes:
    inventory-api/inventory.read
    inventory-api/inventory.write
```

**Why separate clients?** Least privilege. The Products backend client can only request `products.read`. Even if its credentials are leaked, an attacker can't use it to read sales data or inventory -- Cognito will reject the scope request.

## How Scopes Flow: Two Separate Token Fetches

A common mistake is thinking there's one token for the whole chain. There are actually **two independent token fetches** at different hops, going in opposite directions:

```
                    Token Fetch #1                     Token Fetch #2
                    (inbound auth)                     (outbound auth)
                    Agent -> Gateway                   Gateway -> Backend API

Agent container                    Gateway                          Backend API
      |                              |                                |
      | 1. Agent needs to call       |                                |
      |    the gateway               |                                |
      |                              |                                |
      | 2. @requires_access_token    |                                |
      |    asks AgentCore Identity   |                                |
      |    for a D1 token            |                                |
      |                              |                                |
      | 3. Token issued with         |                                |
      |    client_id matching        |                                |
      |    gateway's allowedClients  |                                |
      |                              |                                |
      | 4. POST /mcp                 |                                |
      |    Authorization: Bearer T1 -|                                |
      |                              | 5. Gateway validates T1:      |
      |                              |    issuer = Cognito D1? Yes    |
      |                              |    client_id in allowed? Yes   |
      |                              |                                |
      |                              | 6. Gateway needs to call       |
      |                              |    the backend API             |
      |                              |                                |
      |                              | 7. Credential provider fetches |
      |                              |    a SEPARATE token (T2) from  |
      |                              |    Cognito with specific scope |
      |                              |                                |
      |                              | 8. GET /products               |
      |                              |    Authorization: Bearer T2 ---|
      |                              |                                |
      |                              |                    9. API GW validates T2:
      |                              |                       issuer = D1? Yes
      |                              |                       client_id in
      |                              |                       audience? Yes
      |                              |                       -> Lambda executes
```

**Token T1** (inbound): Authenticates the agent TO the gateway. Issued by Cognito D1, validated against the gateway's `allowedClients` list.

**Token T2** (outbound): Authenticates the gateway TO the backend API. Issued by Cognito D1 using the credential provider's stored client credentials, scoped to `retail-api/products.read`.

These are different tokens, from potentially different Cognito clients, with different scopes.

## Token Fetch #2 in Detail: Cognito Token Issuance

When the gateway's credential provider fetches a token for the outbound call:

```
Gateway credential provider
  |
  |  POST https://cognito-d1.auth.us-east-1.amazoncognito.com/oauth2/token
  |  Content-Type: application/x-www-form-urlencoded
  |  Authorization: Basic base64(client_id:client_secret)
  |
  |  grant_type=client_credentials
  |  scope=retail-api/products.read
  |
Cognito checks:
  1. Does client 6q5fat5i... exist?                          Yes
  2. Is client_credentials flow allowed for this client?     Yes
  3. Is retail-api/products.read in this client's allowlist? Yes
  |
Cognito issues access token:
  {
    "client_id": "6q5fat5i09lfj443qf4t6fhmfv",
    "scope": "retail-api/products.read",
    "iss": "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_qFNe8GSQG",
    "token_use": "access",
    "exp": 1790064433
  }
```

Note: Cognito access tokens from `client_credentials` grant do NOT include an `aud` claim. The `client_id` claim identifies which app client requested the token.

## How the Backend API Validates the Token

The Products HTTP API has a JWT authorizer. When it receives the token:

```
Products API Gateway JWT Authorizer config:
  Issuer:   https://cognito-idp.us-east-1.amazonaws.com/us-east-1_qFNe8GSQG
  Audience: ["7l165nkkgiofodgeobq6tqkpek", "6q5fat5i09lfj443qf4t6fhmfv"]
```

Validation steps:
1. **Signature** -- verifies the JWT signature against Cognito's JWKS keys
2. **Expiry** -- checks `exp` claim hasn't passed
3. **Issuer** -- checks `iss` claim matches the configured issuer URL
4. **Audience** -- since Cognito access tokens lack an `aud` claim, API Gateway's HTTP API JWT authorizer falls back to matching the `client_id` claim against the configured Audience list

This is Cognito-specific behavior. With other identity providers that do set `aud`, the authorizer would match against `aud` directly.

## Where Each Scope Is Configured

### 1. Cognito Resource Server (defines what scopes exist)

```bash
aws cognito-idp create-resource-server \
  --identifier "retail-api" \
  --scopes '[
    {"ScopeName":"products.read", "ScopeDescription":"Read products"},
    {"ScopeName":"sales.read",    "ScopeDescription":"Read sales"}
  ]'
```

### 2. Cognito App Client (defines which scopes this client can request)

```bash
aws cognito-idp create-user-pool-client \
  --allowed-o-auth-scopes "retail-api/products.read"
```

### 3. Gateway Target Credential Provider (defines which scopes to request at call time)

```bash
aws bedrock-agentcore-control create-gateway-target \
  --credential-provider-configurations '[{
    "oauthCredentialProvider": {
      "scopes": ["retail-api/products.read"],
      "grantType": "CLIENT_CREDENTIALS"
    }
  }]'
```

### 4. Backend API JWT Authorizer (validates the token)

```bash
aws apigatewayv2 create-authorizer \
  --jwt-configuration "Issuer=...,Audience=client_id_1,client_id_2"
```

## The Cross-Domain Story (Activity 4)

This is where scopes become most interesting. Two companies, two Cognito pools, two completely separate scope namespaces:

```
Your Company (D1)                          Vendor (D2)

Agent container
  |
  | Token T1: D1 token
  | (authenticates to your gateway)
  v
Inventory Gateway
  | Validates T1 against D1 Cognito
  |
  | Now needs to call vendor's gateway
  | D1 token won't work -- vendor uses D2
  |
  | Token T2: D2 token
  | scope: inventory-api/inventory.read
  | (fetched via credential provider
  |  that stores D2 client credentials)
  v
                                           Vendor Gateway
                                             | Validates T2 against D2 Cognito
                                             | issuer matches D2? Yes
                                             | client_id in allowedClients? Yes
                                             v
                                           Inventory API -> Lambda
```

The credential provider `inventory-oauth-client-mcp-server` stores the vendor's D2 Cognito client credentials in AgentCore Identity's token vault. When the gateway needs to call the vendor, AgentCore Identity uses these stored credentials to fetch a D2 token with `inventory-api/inventory.read` scope -- without your agent ever seeing the vendor's client secret.

## Summary

| Hop | Token from | Client used | Scope requested | Validated by |
|-----|-----------|-------------|----------------|-------------|
| Agent -> Multi-Backend Gateway | Cognito D1 | Products backend client | *(inbound -- no scope required)* | Gateway JWT authorizer |
| Gateway -> Products API | Cognito D1 | Products backend client | `retail-api/products.read` | HTTP API JWT authorizer |
| Gateway -> Sales API | *(API key, not OAuth)* | -- | -- | API key validation |
| Gateway -> DynamoDB | *(IAM role, not OAuth)* | -- | -- | IAM policy |
| Agent -> Inventory Gateway | Cognito D1 | Products backend client | *(inbound -- no scope required)* | Gateway JWT authorizer |
| Inventory GW -> Vendor GW | Cognito D2 | D2 M2M client | `inventory-api/inventory.read` | Vendor gateway JWT authorizer |

Scopes create a **chain of least privilege** -- each token is limited to exactly the permissions needed for that specific hop. No single token grants access to everything.
