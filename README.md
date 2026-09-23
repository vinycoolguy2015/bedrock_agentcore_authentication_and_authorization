# Amazon Bedrock AgentCore MCP Workshop

Build a multi-trust-domain retail agent using **Amazon Bedrock AgentCore**, **AgentCore Gateway MCP servers**, **Strands Agent SDK**, and **Amazon Verified Permissions**.

## Referennce
https://aws.amazon.com/blogs/machine-learning/introducing-amazon-bedrock-agentcore-identity-securing-agentic-ai-at-scale/ - 

https://aws.amazon.com/blogs/security/securing-ai-agents-with-amazon-bedrock-agentcore-identity/

https://catalog.us-east-1.prod.workshops.aws/workshops/e777691e-4c73-430a-9cb0-67dd9f96142b/en-US/

## Workshop Overview

Through this workshop, you'll build a **Sales Operations Toolkit** for AnyCompany Retail that demonstrates real-world identity management patterns for agentic AI applications:

- **A Chat Agent Interface:** Browser-based UI for interacting with AI agents
- **Multi-tenant Authentication:** Separate identity domains for corporate users and suppliers
- **Fine-grained Authorization:** Access control with Amazon Verified Permissions
- **Secure API Integration:** Protected endpoints with proper delegation patterns

### Components

- **Amazon Bedrock AgentCore Runtime & Gateway** — agent hosting + MCP tool integration
- **Strands Agents SDK** — agent development framework
- **Amazon Cognito** — web and API identity management (2 trust domains)
- **Amazon Verified Permissions** — centralized authorization decisions (Cedar policies)

### Data Sources & Auth Summary

| Activity | Data Source | Exposed As | Authentication |
|----------|-----------|------------|---------------|
| 2 | Terms of Service | Lambda → MCP Gateway | AWS IAM (SigV4) |
| 3 | Sales Records | REST API → MCP Gateway | API Key |
| 3 | Products | HTTP API → MCP Gateway | OAuth 2.0 (2LO) |
| 3 | Customer Reviews | DynamoDB → MCP Gateway | AWS IAM |
| 4 | Inventory | MCP-to-MCP (cross-domain) | OAuth 2.0 (2LO) |

---

## Prerequisites

- **AWS CLI v2** configured with credentials
- **Python 3.12+**
- **Podman** (for building the agent container)
- **jq** (`brew install jq` / `apt install jq`)
- **AWS Account** with Bedrock model access enabled for **Claude Sonnet 4.6**

---

## Quick Start

```bash
cd bedrock-agentcore-mcp-workshop
chmod +x deploy.sh teardown.sh
./deploy.sh
```

This deploys all 7 activities sequentially. To deploy individually:

```bash
./deploy.sh --activity 0   # Foundation (IAM, Cognito, DynamoDB)
./deploy.sh --activity 1   # Agent (Runtime, container, proxy API)
./deploy.sh --activity 2   # ToS MCP Gateway (IAM auth)
./deploy.sh --activity 3   # Sales + Products + Reviews MCP Gateway (JWT auth)
./deploy.sh --activity 4   # Inventory MCP Gateway (cross-domain MCP-to-MCP)
./deploy.sh --activity 5   # Verified Permissions (role-based tool filtering)
./deploy.sh --activity 6   # Frontend (S3 + CloudFront + Lambda@Edge)
```

---

## Activities

### Activity 0: Foundation

Creates IAM roles, Cognito user pools (Trust Domains 1 & 2), DynamoDB table, and test users.

**Test users** (password: `Workshop1!`):

| Username | Role | Department |
|----------|------|------------|
| `sarah.johnson` | admin | operations |
| `mike.chen` | everyone | finance |
| `maria.gonzalez` | everyone | support |
| `lisa.rodriguez` | manager | inventory |
| `james.miller` | supplier | sales |

### Activity 1: Agent Setup

Deploys the Strands Agent to AgentCore Runtime with HTTP protocol.

**Creates:** ECR repo, agent container, AgentCore Runtime + endpoint, Lambda proxy + REST API (59s timeout), `config.js` for the frontend.

**Agent architecture:**
- `BedrockAgentCoreApp` with `@app.entrypoint` decorator
- `@requires_access_token` for native AgentCore Identity auth to JWT gateways
- SigV4 signing for IAM-auth gateways
- MCP clients initialized once at cold start, kept alive across requests

### Activity 2: Terms of Service MCP Gateway

**Auth:** Agent (SigV4) → MCP Gateway (IAM auth) → Lambda

Creates `AnyCompany-ToS-Tool` gateway backed by a Lambda that returns delivery, payment, and refund conditions.

### Activity 3: Sales + Products + Reviews MCP Gateway

**Auth:** Agent (JWT 2LO) → MCP Gateway (JWT auth) → Backend APIs

Creates `AnyCompany-Sales-Product-Reviews-Tool` gateway with three targets:

| Target | Backend | Outbound Auth |
|--------|---------|--------------|
| Sales-API-Gateway | REST API (4 endpoints) | API key from Identity vault |
| Products-API-Gateway | HTTP API | OAuth 2LO from Identity vault |
| dynamodb-target | DynamoDB table | IAM role |

### Activity 4: Inventory MCP Gateway (Cross-Domain)

**Auth:** Agent (JWT D1) → Inventory Gateway → Vendor Gateway (OAuth D2) → Inventory API

Creates two gateways simulating a cross-domain MCP-to-MCP scenario:
- `AnyCompany-Inventory-Tool` (Trust Domain 1) — your agent's gateway
- `AnyCompany-Vendor-Inventory-Server` (Trust Domain 2) — the vendor's gateway

### Activity 5: Verified Permissions

Integrates Amazon Verified Permissions for role-based tool filtering. All 5 policies are created automatically by `deploy.sh`.

**Role-Based Access:**

| Role | ToS | Products | Sales | Reviews | Inventory |
|------|-----|----------|-------|---------|-----------|
| Everyone | Yes | Yes | - | - | - |
| Manager | Yes | Yes | Yes | Yes | - |
| Supplier | Yes | Yes | - | - | Yes |
| Admin | Yes | Yes | Yes | Yes | Yes |

> **Note: How Verified Permissions connects to Cognito**
>
> During Activity 5, `deploy.sh` calls `create-identity-source` pointing the policy store at the D1 Cognito User Pool. This tells AVP: *"users authenticated by this Cognito pool are `RetailAgent::User` entities."*
>
> However, the agent doesn't actually use that identity source link at runtime. The agent calls `IsAuthorized` (not `IsAuthorizedWithToken`), and manually passes the user's role as an inline entity attribute:
>
> ```python
> avp_client.is_authorized(
>     principal={"entityType": "RetailAgent::User", "entityId": user_sub},
>     resource={"entityType": "RetailAgent::Tool", "entityId": tool_name},
>     entities={"entityList": [{
>         "identifier": {"entityType": "RetailAgent::User", "entityId": user_sub},
>         "attributes": {"role": {"string": user_role}},
>     }]}
> )
> ```
>
> The `user_sub` and `user_role` come from the browser's request payload (parsed from the Cognito JWT by the frontend). The agent builds the entity inline — it doesn't pass a Cognito token to AVP for automatic claim extraction.
>
> **So why create the identity source at all?** Two reasons:
> 1. **Schema validation** — the identity source lets AVP validate that the Cedar schema's `RetailAgent::User` entity aligns with Cognito's user attributes. Without it, schema validation in STRICT mode may reject policies that reference user attributes.
> 2. **Future upgrade path** — if you switch to `IsAuthorizedWithToken`, AVP can automatically extract `custom:role`, `custom:department`, `sub`, and `email` from the Cognito JWT, eliminating the need to pass them manually. The identity source mapping is already in place for that.

### Activity 6: Frontend

Deploys S3 + CloudFront + Lambda@Edge for the chat UI.

**Auth flow:** User → CloudFront → Lambda@Edge (Cognito redirect for unauthenticated, passthrough for static assets) → S3 → SPA exchanges code for tokens → calls agent via REST API proxy.

---

## Testing

After deploying all activities:

1. Open the CloudFront URL from `outputs.env` (key: `CF_DOMAIN`)
2. Sign in with a test user (password: `Workshop1!`)
3. Try these prompts:

| User | Role | Try |
|------|------|-----|
| `sarah.johnson` | admin | "Show me sales data", "Check inventory levels" |
| `mike.chen` | everyone | "What products do you have?", "What are the delivery conditions?" |
| `lisa.rodriguez` | manager | "Show me customer reviews", "Show sales summary" |
| `james.miller` | supplier | "Check inventory for PROD-001" |

---

## Configuration

Edit `config.env` before deployment:

```bash
export AWS_REGION="us-east-1"
export PROJECT_NAME="agentcore-mcp-ws"
export BEDROCK_MODEL_ID="us.anthropic.claude-sonnet-4-6"
```

---

## Teardown

```bash
./teardown.sh           # Interactive confirmation
./teardown.sh --force   # Skip confirmation
```

Deletes all resources in dependency order. CloudFront takes 5-15 min, Lambda@Edge replicas up to 30 min.
---


