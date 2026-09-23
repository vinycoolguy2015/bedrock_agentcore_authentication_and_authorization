#!/bin/bash
# =============================================================================
# Amazon Bedrock AgentCore MCP Workshop - Teardown Script
# =============================================================================
# Deletes ALL resources created by deploy.sh.
# Run this to clean up after the workshop.
#
# Usage:
#   ./teardown.sh           # Interactive confirmation
#   ./teardown.sh --force   # Skip confirmation
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/scripts/helpers.sh"

FORCE="${1:-}"

# Load deployment outputs
if [ ! -f "${SCRIPT_DIR}/outputs.env" ]; then
    log_error "outputs.env not found. Nothing to tear down."
    exit 1
fi
source "${SCRIPT_DIR}/outputs.env"

# Resolve account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
export UI_BUCKET_NAME="${PROJECT_NAME}-ui-${ACCOUNT_ID}"

if [ "$FORCE" != "--force" ]; then
    echo ""
    echo "========================================================"
    echo "  WARNING: This will DELETE all workshop resources!"
    echo "========================================================"
    echo ""
    echo "The following resources will be removed:"
    echo "  - CloudFront distribution"
    echo "  - S3 bucket: ${UI_BUCKET_NAME}"
    echo "  - Lambda functions (6)"
    echo "  - API Gateways (3)"
    echo "  - DynamoDB table: ${REVIEWS_TABLE_NAME}"
    echo "  - Cognito User Pools (2)"
    echo "  - AgentCore Gateway MCP servers"
    echo "  - AgentCore Runtime"
    echo "  - AgentCore Identities"
    echo "  - Verified Permissions policy store"
    echo "  - ECR repository"
    echo "  - IAM roles (5)"
    echo ""
    read -p "Are you sure you want to proceed? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Teardown cancelled."
        exit 0
    fi
fi

echo ""
log_step "Starting Teardown"

# =============================================================================
# CloudFront Distribution
# =============================================================================
if [ -n "${CF_DIST_ID:-}" ]; then
    log_info "Disabling CloudFront distribution: ${CF_DIST_ID}..."

    # Get current config
    ETAG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query 'ETag' --output text 2>/dev/null || echo "")
    if [ -n "$ETAG" ]; then
        # Disable the distribution first
        CF_CONFIG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query 'DistributionConfig' --output json)
        DISABLED_CONFIG=$(echo "$CF_CONFIG" | jq '.Enabled = false')

        aws cloudfront update-distribution \
            --id "$CF_DIST_ID" \
            --distribution-config "$DISABLED_CONFIG" \
            --if-match "$ETAG" 2>/dev/null || true

        log_info "Waiting for CloudFront to disable (this can take 5-15 minutes)..."
        aws cloudfront wait distribution-deployed --id "$CF_DIST_ID" 2>/dev/null || true

        # Delete
        ETAG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query 'ETag' --output text 2>/dev/null || echo "")
        aws cloudfront delete-distribution --id "$CF_DIST_ID" --if-match "$ETAG" 2>/dev/null || \
            log_warn "Could not delete CloudFront ${CF_DIST_ID}. May need manual cleanup once disabled."
    fi
fi

# Delete OAC
if [ -n "${OAC_ID:-}" ]; then
    ETAG=$(aws cloudfront get-origin-access-control --id "$OAC_ID" --query 'ETag' --output text 2>/dev/null || echo "")
    if [ -n "$ETAG" ]; then
        aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$ETAG" 2>/dev/null || true
    fi
    log_success "Deleted OAC"
fi

# =============================================================================
# S3 Bucket
# =============================================================================
if [ -n "${UI_BUCKET_NAME:-}" ]; then
    log_info "Deleting S3 bucket: ${UI_BUCKET_NAME}..."
    aws s3 rb "s3://${UI_BUCKET_NAME}" --force --region "$AWS_REGION" 2>/dev/null || true
    log_success "Deleted S3 bucket"
fi

# =============================================================================
# Lambda@Edge (us-east-1)
# =============================================================================
if [ -n "${EDGE_LAMBDA_NAME:-}" ]; then
    log_info "Deleting Lambda@Edge: ${EDGE_LAMBDA_NAME}..."
    # Lambda@Edge replicas take time to clean up
    aws lambda delete-function --function-name "$EDGE_LAMBDA_NAME" --region us-east-1 2>/dev/null || \
        log_warn "Lambda@Edge ${EDGE_LAMBDA_NAME} may still have replicas. Retry later if needed."
fi

# =============================================================================
# AgentCore Gateways (delete targets first, then gateway)
# =============================================================================
delete_gateway() {
    local gw_id="$1"
    if [ -z "$gw_id" ] || [ "$gw_id" == "None" ] || [ "$gw_id" == "MANUAL_SETUP_REQUIRED" ]; then
        return
    fi
    log_info "Deleting AgentCore Gateway: ${gw_id}..."

    # Delete all targets first
    local targets
    targets=$(aws bedrock-agentcore-control list-gateway-targets \
        --gateway-identifier "$gw_id" --region "$AWS_REGION" \
        --query 'items[*].targetId' --output text 2>/dev/null || echo "")
    for tid in $targets; do
        log_info "  Deleting target ${tid}..."
        aws bedrock-agentcore-control delete-gateway-target \
            --gateway-identifier "$gw_id" --target-id "$tid" \
            --region "$AWS_REGION" 2>/dev/null || true
    done

    # Wait for targets to delete
    if [ -n "$targets" ]; then sleep 10; fi

    # Delete gateway
    aws bedrock-agentcore-control delete-gateway \
        --gateway-identifier "$gw_id" \
        --region "$AWS_REGION" 2>/dev/null || \
        log_warn "Could not delete gateway ${gw_id}. Delete via Console if needed."
}

for gw_id_var in TOS_GATEWAY_ID MULTI_GATEWAY_ID INVENTORY_GATEWAY_ID VENDOR_GATEWAY_ID AGENT_GATEWAY_ID; do
    delete_gateway "${!gw_id_var:-}"
done

# Clean up any gateways by name pattern (catches duplicates from re-runs)
log_info "Cleaning up any remaining workshop gateways..."
all_gw_ids=$(aws bedrock-agentcore-control list-gateways --region "$AWS_REGION" \
    --query "items[?contains(name,'AnyCompany') || contains(name,'anycompany')].gatewayId" --output text 2>/dev/null || echo "")
for gw_id in $all_gw_ids; do
    delete_gateway "$gw_id"
done

# =============================================================================
# AgentCore Runtime (delete endpoints first, then runtime)
# =============================================================================
if [ -n "${AGENT_RUNTIME_ID:-}" ] && [ "$AGENT_RUNTIME_ID" != "None" ]; then
    log_info "Deleting AgentCore Runtime endpoints..."
    endpoints=$(aws bedrock-agentcore-control list-agent-runtime-endpoints \
        --agent-runtime-id "$AGENT_RUNTIME_ID" --region "$AWS_REGION" \
        --query 'agentRuntimeEndpoints[*].agentRuntimeEndpointId' --output text 2>/dev/null || echo "")
    for eid in $endpoints; do
        aws bedrock-agentcore-control delete-agent-runtime-endpoint \
            --agent-runtime-id "$AGENT_RUNTIME_ID" --endpoint-id "$eid" \
            --region "$AWS_REGION" 2>/dev/null || true
    done

    log_info "Deleting AgentCore Runtime: ${AGENT_RUNTIME_ID}..."
    aws bedrock-agentcore-control delete-agent-runtime \
        --agent-runtime-id "$AGENT_RUNTIME_ID" \
        --region "$AWS_REGION" 2>/dev/null || \
        log_warn "Could not delete AgentCore Runtime. Delete via Console if needed."
fi

# =============================================================================
# AgentCore Identity Vault Secrets
# =============================================================================
log_info "Deleting AgentCore Identity vault secrets..."
for secret_name in "sales-api-key-resource-server" \
                   "products-oauth-client-resource-server" \
                   "inventory-oauth-client-mcp-server"; do
    aws bedrock-agentcore-control delete-api-key-credential-provider \
        --name "$secret_name" \
        --region "$AWS_REGION" 2>/dev/null || true
    aws bedrock-agentcore-control delete-oauth2-credential-provider \
        --name "$secret_name" \
        --region "$AWS_REGION" 2>/dev/null || true
done
log_success "Deleted Identity vault secrets"

# =============================================================================
# Verified Permissions (delete ALL policy stores created by the workshop)
# =============================================================================
log_info "Deleting Verified Permissions policy stores..."
avp_stores=$(aws verifiedpermissions list-policy-stores \
    --region "$AWS_REGION" \
    --query 'policyStores[*].policyStoreId' --output text 2>/dev/null || echo "")
for store_id in $avp_stores; do
    desc=$(aws verifiedpermissions get-policy-store \
        --policy-store-id "$store_id" --region "$AWS_REGION" \
        --query 'description' --output text 2>/dev/null || echo "")
    if echo "$desc" | grep -qi "agent\|retail\|tool"; then
        log_info "  Deleting policy store: ${store_id} (${desc})"
        aws verifiedpermissions delete-policy-store \
            --policy-store-id "$store_id" --region "$AWS_REGION" 2>/dev/null || true
    fi
done
if [ -n "${AVP_POLICY_STORE_ID:-}" ]; then
    aws verifiedpermissions delete-policy-store \
        --policy-store-id "$AVP_POLICY_STORE_ID" \
        --region "$AWS_REGION" 2>/dev/null || true
fi
log_success "Deleted policy stores"

# =============================================================================
# API Gateways
# =============================================================================
if [ -n "${PRODUCTS_API_ID:-}" ]; then
    log_info "Deleting Products API Gateway..."
    aws apigatewayv2 delete-api --api-id "$PRODUCTS_API_ID" --region "$AWS_REGION" 2>/dev/null || true
    log_success "Deleted Products API"
fi

if [ -n "${SALES_API_ID:-}" ]; then
    log_info "Deleting Sales API Gateway..."
    # Delete usage plan key and usage plan first
    if [ -n "${SALES_USAGE_PLAN_ID:-}" ]; then
        aws apigateway delete-usage-plan-key \
            --usage-plan-id "$SALES_USAGE_PLAN_ID" \
            --key-id "${SALES_API_KEY_ID:-}" \
            --region "$AWS_REGION" 2>/dev/null || true
        aws apigateway delete-usage-plan \
            --usage-plan-id "$SALES_USAGE_PLAN_ID" \
            --region "$AWS_REGION" 2>/dev/null || true
    fi
    if [ -n "${SALES_API_KEY_ID:-}" ]; then
        aws apigateway delete-api-key \
            --api-key "$SALES_API_KEY_ID" \
            --region "$AWS_REGION" 2>/dev/null || true
    fi
    aws apigateway delete-rest-api --rest-api-id "$SALES_API_ID" --region "$AWS_REGION" 2>/dev/null || true
    log_success "Deleted Sales API"
fi

if [ -n "${INVENTORY_API_ID:-}" ]; then
    log_info "Deleting Inventory API Gateway..."
    aws apigatewayv2 delete-api --api-id "$INVENTORY_API_ID" --region "$AWS_REGION" 2>/dev/null || true
    log_success "Deleted Inventory API"
fi

if [ -n "${AGENT_PROXY_API_ID:-}" ]; then
    log_info "Deleting Agent Proxy REST API..."
    aws apigateway delete-rest-api --rest-api-id "$AGENT_PROXY_API_ID" --region "$AWS_REGION" 2>/dev/null || true
    log_success "Deleted Agent Proxy API"
fi

# Clean up any duplicate REST APIs created by re-runs
log_info "Cleaning up duplicate REST APIs..."
for api_name in "${AGENT_PROXY_API_NAME:-agentcore-mcp-ws-agent-proxy}" "${SALES_API_NAME:-agentcore-mcp-ws-sales-api}"; do
    dup_ids=$(aws apigateway get-rest-apis --region "$AWS_REGION" \
        --query "items[?name=='${api_name}'].id" --output text 2>/dev/null || echo "")
    for did in $dup_ids; do
        aws apigateway delete-rest-api --rest-api-id "$did" --region "$AWS_REGION" 2>/dev/null || true
        log_info "  Deleted duplicate REST API: ${did} (${api_name})"
    done
done

# Clean up any duplicate HTTP APIs
for api_name in "${PRODUCTS_API_NAME:-agentcore-mcp-ws-products-api}" "${INVENTORY_API_NAME:-agentcore-mcp-ws-inventory-api}" "${AGENT_PROXY_API_NAME:-agentcore-mcp-ws-agent-proxy}"; do
    dup_ids=$(aws apigatewayv2 get-apis --region "$AWS_REGION" \
        --query "Items[?Name=='${api_name}'].ApiId" --output text 2>/dev/null || echo "")
    for did in $dup_ids; do
        aws apigatewayv2 delete-api --api-id "$did" --region "$AWS_REGION" 2>/dev/null || true
        log_info "  Deleted duplicate HTTP API: ${did} (${api_name})"
    done
done

# =============================================================================
# Lambda Functions
# =============================================================================
log_info "Deleting Lambda functions..."
for fn in "$TOS_LAMBDA_NAME" "$PRODUCTS_LAMBDA_NAME" "$SALES_LAMBDA_NAME" \
          "$INVENTORY_LAMBDA_NAME" \
          "${AGENT_PROXY_LAMBDA_NAME:-agentcore-mcp-ws-agent-proxy}"; do
    aws lambda delete-function --function-name "$fn" --region "$AWS_REGION" 2>/dev/null || true
done
log_success "Deleted Lambda functions"

# =============================================================================
# DynamoDB Table
# =============================================================================
if [ -n "${REVIEWS_TABLE_NAME:-}" ]; then
    log_info "Deleting DynamoDB table: ${REVIEWS_TABLE_NAME}..."
    aws dynamodb delete-table --table-name "$REVIEWS_TABLE_NAME" --region "$AWS_REGION" 2>/dev/null || true
    log_success "Deleted DynamoDB table"
fi

# =============================================================================
# ECR Repository
# =============================================================================
if [ -n "${ECR_REPO_NAME:-}" ]; then
    log_info "Deleting ECR repository: ${ECR_REPO_NAME}..."
    aws ecr delete-repository \
        --repository-name "$ECR_REPO_NAME" \
        --force \
        --region "$AWS_REGION" 2>/dev/null || true
    log_success "Deleted ECR repository"
fi

# =============================================================================
# Cognito User Pools
# =============================================================================
if [ -n "${COGNITO_D1_POOL_ID:-}" ]; then
    log_info "Deleting Cognito User Pool (Trust Domain 1)..."
    # Delete domain first
    aws cognito-idp delete-user-pool-domain \
        --domain "${COGNITO_D1_DOMAIN:-}" \
        --user-pool-id "$COGNITO_D1_POOL_ID" \
        --region "$AWS_REGION" 2>/dev/null || true
    aws cognito-idp delete-user-pool \
        --user-pool-id "$COGNITO_D1_POOL_ID" \
        --region "$AWS_REGION" 2>/dev/null || true
    log_success "Deleted Cognito D1 pool"
fi

if [ -n "${COGNITO_D2_POOL_ID:-}" ]; then
    log_info "Deleting Cognito User Pool (Trust Domain 2)..."
    aws cognito-idp delete-user-pool-domain \
        --domain "${COGNITO_D2_DOMAIN:-}" \
        --user-pool-id "$COGNITO_D2_POOL_ID" \
        --region "$AWS_REGION" 2>/dev/null || true
    aws cognito-idp delete-user-pool \
        --user-pool-id "$COGNITO_D2_POOL_ID" \
        --region "$AWS_REGION" 2>/dev/null || true
    log_success "Deleted Cognito D2 pool"
fi

# =============================================================================
# IAM Roles
# =============================================================================
log_info "Deleting IAM roles..."
for role in "$LAMBDA_ROLE_NAME" "$DYNAMODB_ROLE_NAME" "$AGENT_ROLE_NAME" \
            "$GATEWAY_ROLE_NAME" "$EDGE_LAMBDA_ROLE_NAME" \
            "${INVENTORY_GATEWAY_ROLE_NAME:-AmazonBedrockAgentCoreGateway-InventoryToolRole}"; do
    # Delete inline policies
    policies=$(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null || echo "")
    for policy in $policies; do
        aws iam delete-role-policy --role-name "$role" --policy-name "$policy" 2>/dev/null || true
    done
    # Detach managed policies
    managed=$(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
    for arn in $managed; do
        aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" 2>/dev/null || true
    done
    # Delete role
    aws iam delete-role --role-name "$role" 2>/dev/null || true
done
log_success "Deleted IAM roles"

# =============================================================================
# CloudWatch Log Groups
# =============================================================================
log_info "Deleting CloudWatch log groups..."

# Lambda log groups
for fn in "$TOS_LAMBDA_NAME" "$PRODUCTS_LAMBDA_NAME" "$SALES_LAMBDA_NAME" \
          "$INVENTORY_LAMBDA_NAME" \
          "${AGENT_PROXY_LAMBDA_NAME:-agentcore-mcp-ws-agent-proxy}"; do
    aws logs delete-log-group \
        --log-group-name "/aws/lambda/${fn}" \
        --region "$AWS_REGION" 2>/dev/null || true
done
aws logs delete-log-group \
    --log-group-name "/aws/lambda/${EDGE_LAMBDA_NAME}" \
    --region us-east-1 2>/dev/null || true

# AgentCore Runtime log groups
for log_path in \
    "/aws/bedrock-agentcore/runtime/${AGENT_RUNTIME_NAME}/application" \
    "/aws/bedrock-agentcore/runtime/${AGENT_RUNTIME_NAME}/usage" \
    "/aws/bedrock-agentcore/identity/${AGENT_RUNTIME_NAME}/application"; do
    aws logs delete-log-group \
        --log-group-name "$log_path" \
        --region "$AWS_REGION" 2>/dev/null || true
done

# AgentCore Gateway log groups
for gw_name in "$TOS_GATEWAY_NAME" "$MULTI_BACKEND_GATEWAY_NAME" \
               "$INVENTORY_GATEWAY_NAME"; do
    for log_path in \
        "/aws/bedrock-agentcore/gateway/${gw_name}/application" \
        "/aws/bedrock-agentcore/gateway-identity/${gw_name}/application"; do
        aws logs delete-log-group \
            --log-group-name "$log_path" \
            --region "$AWS_REGION" 2>/dev/null || true
    done
done
log_success "Deleted log groups"

# =============================================================================
# Cleanup local files
# =============================================================================
log_info "Cleaning up local artifacts..."
rm -f "${SCRIPT_DIR}/outputs.env"
rm -f "${SCRIPT_DIR}/frontend/config.js"
find "${SCRIPT_DIR}/lambdas" -name "function.zip" -delete 2>/dev/null || true

echo ""
echo "========================================================"
echo "  Teardown Complete!"
echo "========================================================"
echo ""
log_info "All workshop resources have been deleted."
log_warn "Note: CloudFront distributions and Lambda@Edge replicas"
log_warn "may take up to 30 minutes to fully propagate deletion."
echo ""
