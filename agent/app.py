"""
Retail Agent - Strands Agent SDK application
Deployed on Amazon Bedrock AgentCore Runtime.

Connects to AgentCore Gateways natively via AgentCore Identity:
  - Terms of Service    -> IAM Auth (no OAuth needed)
  - Products / Reviews  -> M2M via @requires_access_token (products-oauth-client-resource-server)
  - Inventory           -> M2M via @requires_access_token (products-oauth-client-resource-server, D1 token)

Uses Amazon Verified Permissions to filter tools per user role.
"""

import os
import logging
from datetime import datetime, timezone

import boto3
import httpx
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from strands import Agent
from strands.models.bedrock import BedrockModel
from strands.tools.mcp import MCPClient

try:
    from mcp.client.streamable_http import streamablehttp_client as mcp_client
except ImportError:
    from mcp.client.streamable_http import streamable_http_client as mcp_client

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from bedrock_agentcore.identity.auth import requires_access_token

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

BEDROCK_MODEL_ID           = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-6")
AWS_REGION                 = os.environ.get("AWS_REGION", "us-east-1")
TOS_MCP_ENDPOINT           = os.environ.get("TOS_MCP_ENDPOINT", "")
MULTI_BACKEND_MCP_ENDPOINT = os.environ.get("MULTI_BACKEND_MCP_ENDPOINT", "")
INVENTORY_MCP_ENDPOINT     = os.environ.get("INVENTORY_MCP_ENDPOINT", "")
AVP_POLICY_STORE_ID        = os.environ.get("AVP_POLICY_STORE_ID", "")

SYSTEM_PROMPT = """You are a helpful retail assistant. Use the tools available to you to answer questions.

Tool mapping:
- ToS-Lambda tools → Terms of Service (get, accept, check acceptance)
- Products-API-Gateway tools → Product catalog (browse, search by category)
- Sales-API-Gateway tools → Sales data (records, summaries, by product, by region)
- dynamodb-target tools → Customer Reviews (the DynamoDB table "agentcore-mcp-ws-customer-reviews" contains customer reviews with partition key "product_id" and sort key "review_id". Use Query with product_id or Scan to list reviews.)
- Inventory-MCP-Target tools → Inventory levels (stock status, warehouse locations)

Always use your tools to fetch real data. Do not make up data or say you cannot access something if you have the tool available. If a tool call returns an error, tell the user what happened.
"""

app        = BedrockAgentCoreApp()
model      = BedrockModel(model_id=BEDROCK_MODEL_ID, region_name=AWS_REGION)
avp_client = boto3.client("verifiedpermissions", region_name=AWS_REGION)


def _make_mcp_transport(url, token=None):
    """Create MCP transport — tries headers param first, falls back to http_client."""
    kwargs = {"url": url}
    if token:
        try:
            return mcp_client(url=url, headers={"Authorization": f"Bearer {token}"})
        except TypeError:
            kwargs["http_client"] = httpx.AsyncClient(headers={"Authorization": f"Bearer {token}"})
    return mcp_client(**kwargs)


class _SigV4Auth(httpx.Auth):
    """httpx auth hook that SigV4-signs every request for IAM-authed gateways."""
    def __init__(self):
        session = boto3.session.Session()
        self._credentials = session.get_credentials().get_frozen_credentials()

    def auth_flow(self, request):
        aws_req = AWSRequest(
            method=request.method,
            url=str(request.url),
            data=request.content or b"",
            headers=dict(request.headers),
        )
        SigV4Auth(self._credentials, "bedrock-agentcore", AWS_REGION).add_auth(aws_req)
        for key, value in aws_req.headers.items():
            request.headers[key] = value
        yield request


def build_tos_client() -> MCPClient:
    return MCPClient(
        lambda: mcp_client(
            url=TOS_MCP_ENDPOINT,
            http_client=httpx.AsyncClient(auth=_SigV4Auth()),
        )
    )


@requires_access_token(
    provider_name="products-oauth-client-resource-server",
    scopes=[],
    auth_flow="M2M",
)
def build_multi_backend_client(*, access_token: str) -> MCPClient:
    logger.info("Building multi-backend MCP client with AgentCore Identity token")
    return MCPClient(lambda tok=access_token: _make_mcp_transport(MULTI_BACKEND_MCP_ENDPOINT, tok))


@requires_access_token(
    provider_name="products-oauth-client-resource-server",
    scopes=[],
    auth_flow="M2M",
)
def build_inventory_client(*, access_token: str) -> MCPClient:
    logger.info("Building inventory MCP client with D1 token via AgentCore Identity")
    return MCPClient(lambda tok=access_token: _make_mcp_transport(INVENTORY_MCP_ENDPOINT, tok))


DYNAMODB_ALLOWED_TOOLS = {
    "dynamodb-target___GetItem",
    "dynamodb-target___Query",
    "dynamodb-target___Scan",
    "dynamodb-target___DescribeTable",
}


def init_mcp_clients() -> tuple[list[MCPClient], list]:
    clients: list[MCPClient] = []
    all_tools: list = []

    builders = []
    if TOS_MCP_ENDPOINT:
        builders.append(("ToS",          build_tos_client))
    if MULTI_BACKEND_MCP_ENDPOINT:
        builders.append(("MultiBackend", build_multi_backend_client))
    if INVENTORY_MCP_ENDPOINT:
        builders.append(("Inventory",    build_inventory_client))

    for name, builder in builders:
        try:
            client = builder()
            client.__enter__()
            tools = client.list_tools_sync()

            filtered = []
            for t in tools:
                tool_name = t.tool_name if hasattr(t, "tool_name") else str(t)
                if tool_name.startswith("dynamodb-target___"):
                    if tool_name in DYNAMODB_ALLOWED_TOOLS:
                        filtered.append(t)
                    else:
                        logger.debug(f"[cold-start] SKIP {tool_name}")
                else:
                    filtered.append(t)

            all_tools.extend(filtered)
            clients.append(client)
            logger.info(f"[cold-start] {name}: {len(filtered)}/{len(tools)} tools kept")
        except Exception as e:
            logger.error(f"[cold-start] {name} failed to connect: {e}")

    logger.info(f"[cold-start] Total tools available: {len(all_tools)}")
    return clients, all_tools


_mcp_clients, _all_tools = init_mcp_clients()


def filter_tools_by_authorization(
    tools: list, user_sub: str, user_role: str
) -> tuple[list, list]:
    if not AVP_POLICY_STORE_ID:
        logger.warning("No AVP policy store configured — returning all tools unfiltered")
        tool_names = [t.tool_name if hasattr(t, "tool_name") else str(t) for t in tools]
        return tools, [
            {"tool": n, "decision": "ALLOW", "timestamp": datetime.now(timezone.utc).isoformat()}
            for n in tool_names
        ]

    allowed_tools = []
    audit_log = []

    for tool in tools:
        tool_name = tool.tool_name if hasattr(tool, "tool_name") else str(tool)
        try:
            response = avp_client.is_authorized(
                policyStoreId=AVP_POLICY_STORE_ID,
                principal={"entityType": "RetailAgent::User",   "entityId": user_sub},
                action=   {"actionType": "RetailAgent::Action", "actionId": "InvokeTool"},
                resource= {"entityType": "RetailAgent::Tool",   "entityId": tool_name},
                entities={"entityList": [
                    {"identifier": {"entityType": "RetailAgent::User", "entityId": user_sub},
                     "attributes": {"role": {"string": user_role}}},
                    {"identifier": {"entityType": "RetailAgent::Tool", "entityId": tool_name},
                     "attributes": {"gateway": {"string": tool_name.split("___")[0] if "___" in tool_name else tool_name}}},
                ]},
            )
            decision = response.get("decision", "DENY")
            audit_log.append({"tool": tool_name, "decision": decision, "timestamp": datetime.now(timezone.utc).isoformat()})
            if decision == "ALLOW":
                allowed_tools.append(tool)
                logger.info(f"ALLOW tool={tool_name} user={user_sub} role={user_role}")
            else:
                logger.info(f"DENY  tool={tool_name} user={user_sub} role={user_role}")
        except Exception as e:
            logger.error(f"AVP check failed for tool={tool_name}: {e}")
            audit_log.append({"tool": tool_name, "decision": "ERROR", "timestamp": datetime.now(timezone.utc).isoformat()})

    logger.info(f"Tool filtering: {len(allowed_tools)}/{len(tools)} allowed for user={user_sub} role={user_role}")
    return allowed_tools, audit_log


@app.entrypoint
def handle_request(payload, context):
    user_message = payload.get("message", "")
    user_sub     = payload.get("user_sub", "anonymous")
    user_role    = payload.get("user_role", "everyone")
    session_id   = payload.get("session_id", "default")

    if not user_message.strip():
        return {"error": "Invalid input: 'message' must be a non-empty string"}

    logger.info(f"Invocation: user={user_sub} role={user_role} session={session_id}")

    tools, audit_log = filter_tools_by_authorization(_all_tools, user_sub, user_role)

    agent = Agent(model=model, tools=tools, system_prompt=SYSTEM_PROMPT)
    response = agent(user_message)

    return {
        "response": str(response),
        "session_id": session_id,
        "allowed_tools": [t.tool_name if hasattr(t, "tool_name") else str(t) for t in tools],
        "audit_log": audit_log,
        "user_role": user_role,
    }


if __name__ == "__main__":
    app.run()
