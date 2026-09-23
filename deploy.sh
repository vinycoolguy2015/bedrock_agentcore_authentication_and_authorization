#!/bin/bash
# =============================================================================
# Amazon Bedrock AgentCore MCP Workshop - Deployment Script
# =============================================================================
# Deploys all workshop resources in order:
#   0. Foundation (IAM roles, Cognito, DynamoDB)
#   1. Agent Setup (AgentCore Runtime + Identity)
#   2. Terms of Service MCP (Lambda + IAM Auth)
#   3. Multi-Backend MCP (Products/Sales/Reviews)
#   4. Cross-Domain Inventory MCP
#   5. Verified Permissions
#   6. Frontend (S3 + CloudFront + Lambda@Edge)
#
# Usage:
#   ./deploy.sh              # Deploy everything
#   ./deploy.sh --activity 2 # Deploy only Activity 2
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/scripts/helpers.sh"

ACTIVITY="${1:-all}"
if [ "$ACTIVITY" == "--activity" ]; then
    ACTIVITY="${2:-all}"
fi

touch "${SCRIPT_DIR}/outputs.env"

# =============================================================================
# ACTIVITY 0: Foundation
# =============================================================================
deploy_foundation() {
    log_step "Activity 0: Foundation (IAM, Cognito, DynamoDB)"

    # --- IAM Roles ---
    log_info "Creating IAM roles..."

    # Lambda execution role
    create_role_if_not_exists \
        "$LAMBDA_ROLE_NAME" \
        "${SCRIPT_DIR}/iam/lambda-trust-policy.json" \
        "${LAMBDA_ROLE_NAME}-policy" \
        "${SCRIPT_DIR}/iam/lambda-basic-policy.json"
    LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
    save_output "LAMBDA_ROLE_ARN" "$LAMBDA_ROLE_ARN"

    # DynamoDB access role (for Customer Reviews Lambda/Gateway)
    create_role_if_not_exists \
        "$DYNAMODB_ROLE_NAME" \
        "${SCRIPT_DIR}/iam/lambda-trust-policy.json" \
        "${DYNAMODB_ROLE_NAME}-policy" \
        "${SCRIPT_DIR}/iam/dynamodb-access-policy.json"
    DYNAMODB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${DYNAMODB_ROLE_NAME}"
    save_output "DYNAMODB_ROLE_ARN" "$DYNAMODB_ROLE_ARN"

    # Agent execution role
    create_role_if_not_exists \
        "$AGENT_ROLE_NAME" \
        "${SCRIPT_DIR}/iam/agent-trust-policy.json" \
        "${AGENT_ROLE_NAME}-policy" \
        "${SCRIPT_DIR}/iam/agent-execution-policy.json"
    AGENT_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${AGENT_ROLE_NAME}"
    save_output "AGENT_ROLE_ARN" "$AGENT_ROLE_ARN"

    # Gateway execution role
    create_role_if_not_exists \
        "$GATEWAY_ROLE_NAME" \
        "${SCRIPT_DIR}/iam/gateway-trust-policy.json" \
        "${GATEWAY_ROLE_NAME}-policy" \
        "${SCRIPT_DIR}/iam/gateway-execution-policy.json"
    GATEWAY_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${GATEWAY_ROLE_NAME}"
    save_output "GATEWAY_ROLE_ARN" "$GATEWAY_ROLE_ARN"

    # Edge Lambda role
    create_role_if_not_exists \
        "$EDGE_LAMBDA_ROLE_NAME" \
        "${SCRIPT_DIR}/iam/edge-lambda-trust-policy.json" \
        "${EDGE_LAMBDA_ROLE_NAME}-policy" \
        "${SCRIPT_DIR}/iam/lambda-basic-policy.json"
    EDGE_LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EDGE_LAMBDA_ROLE_NAME}"
    save_output "EDGE_LAMBDA_ROLE_ARN" "$EDGE_LAMBDA_ROLE_ARN"

    wait_for_role "$LAMBDA_ROLE_NAME"

    # --- Cognito User Pool: Trust Domain 1 ---
    log_info "Creating Cognito User Pool (Trust Domain 1)..."
    COGNITO_D1_POOL_ID=$(aws cognito-idp create-user-pool \
        --pool-name "$COGNITO_D1_POOL_NAME" \
        --auto-verified-attributes email \
        --schema '[{"Name":"email","Required":true,"Mutable":true},{"Name":"role","AttributeDataType":"String","Mutable":true,"StringAttributeConstraints":{"MinLength":"1","MaxLength":"50"}},{"Name":"department","AttributeDataType":"String","Mutable":true,"StringAttributeConstraints":{"MinLength":"1","MaxLength":"50"}}]' \
        --policies '{"PasswordPolicy":{"MinimumLength":8,"RequireUppercase":true,"RequireLowercase":true,"RequireNumbers":true,"RequireSymbols":false}}' \
        --region "$AWS_REGION" \
        --query 'UserPool.Id' --output text)
    save_output "COGNITO_D1_POOL_ID" "$COGNITO_D1_POOL_ID"
    log_success "Cognito D1 Pool: ${COGNITO_D1_POOL_ID}"

    # Create domain for hosted UI
    aws cognito-idp create-user-pool-domain \
        --domain "$COGNITO_D1_DOMAIN" \
        --user-pool-id "$COGNITO_D1_POOL_ID" \
        --region "$AWS_REGION"
    save_output "COGNITO_D1_DOMAIN" "$COGNITO_D1_DOMAIN"
    log_success "Cognito D1 Domain: ${COGNITO_D1_DOMAIN}"

    # Resource server for OAuth 2.0 scopes
    aws cognito-idp create-resource-server \
        --user-pool-id "$COGNITO_D1_POOL_ID" \
        --identifier "retail-api" \
        --name "Retail API" \
        --scopes '[{"ScopeName":"products.read","ScopeDescription":"Read products"},{"ScopeName":"sales.read","ScopeDescription":"Read sales data"},{"ScopeName":"inventory.read","ScopeDescription":"Read inventory"},{"ScopeName":"inventory.write","ScopeDescription":"Write inventory"}]' \
        --region "$AWS_REGION"
    log_success "Created D1 resource server with scopes"

    # App client for the UI (authorization code grant)
    COGNITO_D1_UI_CLIENT_ID=$(aws cognito-idp create-user-pool-client \
        --user-pool-id "$COGNITO_D1_POOL_ID" \
        --client-name "${PROJECT_NAME}-ui-client" \
        --no-generate-secret \
        --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
        --allowed-o-auth-flows code \
        --allowed-o-auth-scopes openid email profile \
        --allowed-o-auth-flows-user-pool-client \
        --supported-identity-providers COGNITO \
        --callback-urls '["https://localhost/callback"]' \
        --logout-urls '["https://localhost"]' \
        --region "$AWS_REGION" \
        --query 'UserPoolClient.ClientId' --output text)
    save_output "COGNITO_D1_UI_CLIENT_ID" "$COGNITO_D1_UI_CLIENT_ID"
    log_success "Cognito D1 UI Client: ${COGNITO_D1_UI_CLIENT_ID}"

    # App client for MCP gateway (client credentials - 2LO)
    COGNITO_D1_M2M_CLIENT_ID=$(aws cognito-idp create-user-pool-client \
        --user-pool-id "$COGNITO_D1_POOL_ID" \
        --client-name "${PROJECT_NAME}-m2m-client" \
        --generate-secret \
        --explicit-auth-flows ALLOW_USER_SRP_AUTH \
        --allowed-o-auth-flows client_credentials \
        --allowed-o-auth-scopes "retail-api/products.read" "retail-api/sales.read" "retail-api/inventory.read" "retail-api/inventory.write" \
        --allowed-o-auth-flows-user-pool-client \
        --region "$AWS_REGION" \
        --query 'UserPoolClient.ClientId' --output text)
    save_output "COGNITO_D1_M2M_CLIENT_ID" "$COGNITO_D1_M2M_CLIENT_ID"

    COGNITO_D1_M2M_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
        --user-pool-id "$COGNITO_D1_POOL_ID" \
        --client-id "$COGNITO_D1_M2M_CLIENT_ID" \
        --region "$AWS_REGION" \
        --query 'UserPoolClient.ClientSecret' --output text)
    save_output "COGNITO_D1_M2M_CLIENT_SECRET" "$COGNITO_D1_M2M_CLIENT_SECRET"
    log_success "Cognito D1 M2M Client: ${COGNITO_D1_M2M_CLIENT_ID}"

    # --- Cognito User Pool: Trust Domain 2 ---
    log_info "Creating Cognito User Pool (Trust Domain 2)..."
    COGNITO_D2_POOL_ID=$(aws cognito-idp create-user-pool \
        --pool-name "$COGNITO_D2_POOL_NAME" \
        --auto-verified-attributes email \
        --schema '[{"Name":"email","Required":true,"Mutable":true}]' \
        --region "$AWS_REGION" \
        --query 'UserPool.Id' --output text)
    save_output "COGNITO_D2_POOL_ID" "$COGNITO_D2_POOL_ID"
    log_success "Cognito D2 Pool: ${COGNITO_D2_POOL_ID}"

    aws cognito-idp create-user-pool-domain \
        --domain "$COGNITO_D2_DOMAIN" \
        --user-pool-id "$COGNITO_D2_POOL_ID" \
        --region "$AWS_REGION"
    save_output "COGNITO_D2_DOMAIN" "$COGNITO_D2_DOMAIN"

    aws cognito-idp create-resource-server \
        --user-pool-id "$COGNITO_D2_POOL_ID" \
        --identifier "inventory-api" \
        --name "Inventory API" \
        --scopes '[{"ScopeName":"inventory.read","ScopeDescription":"Read inventory"},{"ScopeName":"inventory.write","ScopeDescription":"Write inventory"}]' \
        --region "$AWS_REGION"

    COGNITO_D2_M2M_CLIENT_ID=$(aws cognito-idp create-user-pool-client \
        --user-pool-id "$COGNITO_D2_POOL_ID" \
        --client-name "${PROJECT_NAME}-d2-m2m-client" \
        --generate-secret \
        --explicit-auth-flows ALLOW_USER_SRP_AUTH \
        --allowed-o-auth-flows client_credentials \
        --allowed-o-auth-scopes "inventory-api/inventory.read" "inventory-api/inventory.write" \
        --allowed-o-auth-flows-user-pool-client \
        --region "$AWS_REGION" \
        --query 'UserPoolClient.ClientId' --output text)
    save_output "COGNITO_D2_M2M_CLIENT_ID" "$COGNITO_D2_M2M_CLIENT_ID"

    COGNITO_D2_M2M_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
        --user-pool-id "$COGNITO_D2_POOL_ID" \
        --client-id "$COGNITO_D2_M2M_CLIENT_ID" \
        --region "$AWS_REGION" \
        --query 'UserPoolClient.ClientSecret' --output text)
    save_output "COGNITO_D2_M2M_CLIENT_SECRET" "$COGNITO_D2_M2M_CLIENT_SECRET"
    log_success "Cognito D2 M2M Client: ${COGNITO_D2_M2M_CLIENT_ID}"

    # --- DynamoDB Table: Customer Reviews ---
    log_info "Creating DynamoDB table for Customer Reviews..."
    if ! aws dynamodb describe-table --table-name "$REVIEWS_TABLE_NAME" --region "$AWS_REGION" &>/dev/null; then
        aws dynamodb create-table \
            --table-name "$REVIEWS_TABLE_NAME" \
            --attribute-definitions \
                AttributeName=product_id,AttributeType=S \
                AttributeName=review_id,AttributeType=S \
            --key-schema \
                AttributeName=product_id,KeyType=HASH \
                AttributeName=review_id,KeyType=RANGE \
            --billing-mode PAY_PER_REQUEST \
            --region "$AWS_REGION" \
            --output text --query 'TableDescription.TableArn'
        log_success "Created DynamoDB table: ${REVIEWS_TABLE_NAME}"

        log_info "Waiting for table to become active..."
        aws dynamodb wait table-exists --table-name "$REVIEWS_TABLE_NAME" --region "$AWS_REGION"

        log_info "Seeding review data..."
        aws dynamodb batch-write-item \
            --request-items "file://${SCRIPT_DIR}/dynamodb/seed-reviews.json" \
            --region "$AWS_REGION"
        log_success "Seeded ${REVIEWS_TABLE_NAME} with sample reviews"
    else
        log_info "DynamoDB table ${REVIEWS_TABLE_NAME} already exists."
    fi

    # --- Create test users in Cognito D1 ---
    log_info "Creating test users in Cognito (Trust Domain 1)..."

    WORKSHOP_PASSWORD="Workshop1!"

    local users="sarah.johnson:sarah.johnson@example.com:admin:operations
mike.chen:mike.chen@example.com:everyone:finance
maria.gonzalez:maria.gonzalez@example.com:everyone:support
lisa.rodriguez:lisa.rodriguez@example.com:manager:inventory
james.miller:james.miller@example.com:supplier:sales"

    echo "$users" | while IFS=':' read -r username email role department; do
        aws cognito-idp admin-create-user \
            --user-pool-id "$COGNITO_D1_POOL_ID" \
            --username "$username" \
            --user-attributes \
                Name=email,Value="$email" \
                Name=email_verified,Value=true \
                Name=custom:role,Value="$role" \
                Name=custom:department,Value="$department" \
            --temporary-password "$WORKSHOP_PASSWORD" \
            --message-action SUPPRESS \
            --region "$AWS_REGION" 2>/dev/null || true

        aws cognito-idp admin-set-user-password \
            --user-pool-id "$COGNITO_D1_POOL_ID" \
            --username "$username" \
            --password "$WORKSHOP_PASSWORD" \
            --permanent \
            --region "$AWS_REGION" 2>/dev/null || true
    done
    save_output "WORKSHOP_PASSWORD" "$WORKSHOP_PASSWORD"
    log_success "Test users created (password: ${WORKSHOP_PASSWORD}):"
    log_info "  sarah.johnson  (admin    / operations)"
    log_info "  mike.chen      (everyone / finance)"
    log_info "  maria.gonzalez (everyone / support)"
    log_info "  lisa.rodriguez (manager  / inventory)"
    log_info "  james.miller   (supplier / sales)"

    log_success "Foundation deployment complete!"
}

# =============================================================================
# ACTIVITY 1: Agent Setup (AgentCore Runtime + Identity)
# =============================================================================
deploy_agent() {
    log_step "Activity 1: Agent Setup (AgentCore Runtime + Identity)"
    load_outputs

    # --- Build and push agent container ---
    log_info "Building agent container..."

    # Create ECR repository
    ECR_REPO_URI=$(aws ecr describe-repositories \
        --repository-names "$ECR_REPO_NAME" \
        --region "$AWS_REGION" \
        --query 'repositories[0].repositoryUri' --output text 2>/dev/null || \
    aws ecr create-repository \
        --repository-name "$ECR_REPO_NAME" \
        --region "$AWS_REGION" \
        --query 'repository.repositoryUri' --output text)
    save_output "ECR_REPO_URI" "$ECR_REPO_URI"
    log_success "ECR Repository: ${ECR_REPO_URI}"

    # Login to ECR
    aws ecr get-login-password --region "$AWS_REGION" | \
        podman login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

    # Build and push
    podman build -t "${ECR_REPO_NAME}:latest" "${SCRIPT_DIR}/agent/"
    podman tag "${ECR_REPO_NAME}:latest" "${ECR_REPO_URI}:latest"
    podman push "${ECR_REPO_URI}:latest"
    log_success "Agent container pushed to ECR"

    # --- Deploy to AgentCore Runtime ---
    log_info "Deploying agent to AgentCore Runtime..."

    # Check if runtime already exists (list and filter by name)
    AGENT_RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes \
        --region "$AWS_REGION" \
        --query "agentRuntimes[?agentRuntimeName=='${AGENT_RUNTIME_NAME}'].agentRuntimeId | [0]" \
        --output text 2>/dev/null)

    if [ -n "$AGENT_RUNTIME_ID" ] && [ "$AGENT_RUNTIME_ID" != "None" ]; then
        log_info "Agent Runtime already exists (${AGENT_RUNTIME_ID}), updating..."
        AGENT_RUNTIME_ARN=$(aws bedrock-agentcore-control update-agent-runtime \
            --agent-runtime-id "$AGENT_RUNTIME_ID" \
            --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${ECR_REPO_URI}:latest\"}}" \
            --role-arn "$AGENT_ROLE_ARN" \
            --network-configuration '{"networkMode":"PUBLIC"}' \
            --protocol-configuration '{"serverProtocol":"HTTP"}' \
            --environment-variables "{\"BEDROCK_MODEL_ID\":\"${BEDROCK_MODEL_ID}\"}" \
            --region "$AWS_REGION" \
            --query 'agentRuntimeArn' --output text 2>&1)
        if echo "$AGENT_RUNTIME_ARN" | grep -q "arn:aws"; then
            log_success "Updated Agent Runtime: ${AGENT_RUNTIME_ARN}"
        else
            log_error "Failed to update Agent Runtime: ${AGENT_RUNTIME_ARN}"
            AGENT_RUNTIME_ARN=""
        fi
    else
        AGENT_RUNTIME_ARN=$(aws bedrock-agentcore-control create-agent-runtime \
            --agent-runtime-name "$AGENT_RUNTIME_NAME" \
            --role-arn "$AGENT_ROLE_ARN" \
            --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${ECR_REPO_URI}:latest\"}}" \
            --network-configuration '{"networkMode":"PUBLIC"}' \
            --protocol-configuration '{"serverProtocol":"HTTP"}' \
            --environment-variables "{\"BEDROCK_MODEL_ID\":\"${BEDROCK_MODEL_ID}\"}" \
            --region "$AWS_REGION" \
            --query 'agentRuntimeArn' --output text 2>&1)
        if echo "$AGENT_RUNTIME_ARN" | grep -q "arn:aws"; then
            log_success "Created Agent Runtime: ${AGENT_RUNTIME_ARN}"
        else
            log_error "Failed to create Agent Runtime: ${AGENT_RUNTIME_ARN}"
            AGENT_RUNTIME_ARN=""
        fi
    fi
    AGENT_RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes \
        --region "$AWS_REGION" \
        --query "agentRuntimes[?agentRuntimeName=='${AGENT_RUNTIME_NAME}'].agentRuntimeId | [0]" \
        --output text 2>/dev/null)
    save_output "AGENT_RUNTIME_ARN" "$AGENT_RUNTIME_ARN"
    save_output "AGENT_RUNTIME_ID" "$AGENT_RUNTIME_ID"

    # --- Enable CloudWatch Log Delivery (Console only) ---
    log_info "Enable log delivery via Console: Bedrock > AgentCore > Runtimes > ${AGENT_RUNTIME_NAME} > Log deliveries"
    log_info "  Runtime tab: Add APPLICATION_LOGS and USAGE_LOGS"
    log_info "  Identity tab: Add APPLICATION_LOGS"

    # --- Deploy Agent Proxy Lambda + REST API Gateway ---
    log_info "Deploying agent proxy Lambda..."
    local proxy_zip="${SCRIPT_DIR}/lambdas/agent-proxy/function.zip"
    zip_lambda "${SCRIPT_DIR}/lambdas/agent-proxy" "$proxy_zip"

    AGENT_PROXY_LAMBDA_ARN=$(create_lambda_if_not_exists \
        "$AGENT_PROXY_LAMBDA_NAME" "$proxy_zip" "index.handler" \
        "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}" \
        "python3.12" \
        "AGENT_RUNTIME_ARN=${AGENT_RUNTIME_ARN}")
    save_output "AGENT_PROXY_LAMBDA_ARN" "$AGENT_PROXY_LAMBDA_ARN"

    aws lambda update-function-configuration \
        --function-name "$AGENT_PROXY_LAMBDA_NAME" \
        --timeout 120 --memory-size 256 \
        --region "$AWS_REGION" 2>/dev/null || true
    log_success "Agent Proxy Lambda: ${AGENT_PROXY_LAMBDA_ARN}"

    log_info "Creating Agent Proxy REST API (59s timeout)..."
    AGENT_PROXY_API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" \
        --query "items[?name=='${AGENT_PROXY_API_NAME}'].id | [0]" --output text 2>/dev/null)

    if [ -z "$AGENT_PROXY_API_ID" ] || [ "$AGENT_PROXY_API_ID" == "None" ]; then
        AGENT_PROXY_API_ID=$(aws apigateway create-rest-api \
            --name "$AGENT_PROXY_API_NAME" \
            --region "$AWS_REGION" \
            --query 'id' --output text)

        local proxy_root_id
        proxy_root_id=$(aws apigateway get-resources \
            --rest-api-id "$AGENT_PROXY_API_ID" --region "$AWS_REGION" \
            --query 'items[0].id' --output text)

        local proxy_resource_id
        proxy_resource_id=$(aws apigateway create-resource \
            --rest-api-id "$AGENT_PROXY_API_ID" \
            --parent-id "$proxy_root_id" --path-part "invoke" \
            --region "$AWS_REGION" --query 'id' --output text)

        # POST /invoke → Lambda with 59s timeout
        aws apigateway put-method \
            --rest-api-id "$AGENT_PROXY_API_ID" --resource-id "$proxy_resource_id" \
            --http-method POST --authorization-type NONE --region "$AWS_REGION"

        aws apigateway put-integration \
            --rest-api-id "$AGENT_PROXY_API_ID" --resource-id "$proxy_resource_id" \
            --http-method POST --type AWS_PROXY --integration-http-method POST \
            --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${AGENT_PROXY_LAMBDA_NAME}/invocations" \
            --timeout-in-millis 59000 --region "$AWS_REGION"

        # OPTIONS for CORS
        aws apigateway put-method \
            --rest-api-id "$AGENT_PROXY_API_ID" --resource-id "$proxy_resource_id" \
            --http-method OPTIONS --authorization-type NONE --region "$AWS_REGION"

        aws apigateway put-integration \
            --rest-api-id "$AGENT_PROXY_API_ID" --resource-id "$proxy_resource_id" \
            --http-method OPTIONS --type MOCK \
            --request-templates '{"application/json": "{\"statusCode\": 200}"}' \
            --region "$AWS_REGION"

        aws apigateway put-method-response \
            --rest-api-id "$AGENT_PROXY_API_ID" --resource-id "$proxy_resource_id" \
            --http-method OPTIONS --status-code 200 \
            --response-parameters '{"method.response.header.Access-Control-Allow-Headers":false,"method.response.header.Access-Control-Allow-Methods":false,"method.response.header.Access-Control-Allow-Origin":false}' \
            --region "$AWS_REGION"

        aws apigateway put-integration-response \
            --rest-api-id "$AGENT_PROXY_API_ID" --resource-id "$proxy_resource_id" \
            --http-method OPTIONS --status-code 200 \
            --response-parameters "{\"method.response.header.Access-Control-Allow-Headers\":\"'Content-Type,Authorization'\",\"method.response.header.Access-Control-Allow-Methods\":\"'POST,OPTIONS'\",\"method.response.header.Access-Control-Allow-Origin\":\"'*'\"}" \
            --region "$AWS_REGION"

        aws apigateway create-deployment \
            --rest-api-id "$AGENT_PROXY_API_ID" --stage-name prod --region "$AWS_REGION"

        aws lambda add-permission \
            --function-name "$AGENT_PROXY_LAMBDA_NAME" \
            --statement-id "rest-api-invoke-${AGENT_PROXY_API_ID}" \
            --action lambda:InvokeFunction \
            --principal apigateway.amazonaws.com \
            --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${AGENT_PROXY_API_ID}/*" \
            --region "$AWS_REGION" 2>/dev/null || true

        log_success "Created Agent Proxy REST API: ${AGENT_PROXY_API_ID}"
    else
        log_info "Agent Proxy REST API already exists: ${AGENT_PROXY_API_ID}"
    fi
    save_output "AGENT_PROXY_API_ID" "$AGENT_PROXY_API_ID"

    # Ensure Lambda permission exists (idempotent — handles re-runs)
    aws lambda remove-permission --function-name "$AGENT_PROXY_LAMBDA_NAME" \
        --statement-id "rest-api-invoke-${AGENT_PROXY_API_ID}" --region "$AWS_REGION" 2>/dev/null || true
    aws lambda add-permission \
        --function-name "$AGENT_PROXY_LAMBDA_NAME" \
        --statement-id "rest-api-invoke-${AGENT_PROXY_API_ID}" \
        --action lambda:InvokeFunction \
        --principal apigateway.amazonaws.com \
        --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${AGENT_PROXY_API_ID}/*" \
        --region "$AWS_REGION" 2>/dev/null || true

    AGENT_ENDPOINT_URL="https://${AGENT_PROXY_API_ID}.execute-api.${AWS_REGION}.amazonaws.com/prod/invoke"
    save_output "AGENT_ENDPOINT_URL" "$AGENT_ENDPOINT_URL"
    log_success "Agent endpoint: ${AGENT_ENDPOINT_URL}"

    rm -f "$proxy_zip"

    cat > "${SCRIPT_DIR}/frontend/config.js" <<CONFIGEOF
// Auto-generated by deploy.sh — do not edit manually
const CONFIG = {
    cognitoDomain: '${COGNITO_D1_DOMAIN}.auth.${AWS_REGION}.amazoncognito.com',
    clientId: '${COGNITO_D1_UI_CLIENT_ID}',
    callbackUrl: window.location.origin + '/callback',
    agentEndpoint: '${AGENT_ENDPOINT_URL}',
    region: '${AWS_REGION}',
    userPoolId: '${COGNITO_D1_POOL_ID}',
};
CONFIGEOF
    log_success "Generated frontend/config.js"

    # Upload config.js to S3 if bucket exists
    if [ -n "${UI_BUCKET_NAME:-}" ] && aws s3api head-bucket --bucket "$UI_BUCKET_NAME" 2>/dev/null; then
        aws s3 cp "${SCRIPT_DIR}/frontend/config.js" "s3://${UI_BUCKET_NAME}/config.js" \
            --region "$AWS_REGION"
        log_success "Uploaded config.js to S3"
    fi

    log_success "Activity 1 complete!"
}

# =============================================================================
# ACTIVITY 2: Terms of Service MCP Server (Lambda + IAM Auth)
# =============================================================================
deploy_tos_mcp() {
    log_step "Activity 2: Terms of Service MCP (Lambda + IAM Auth)"
    load_outputs

    # --- Deploy Lambda ---
    log_info "Deploying Terms of Service Lambda..."
    local zip_file="${SCRIPT_DIR}/lambdas/terms-of-service/function.zip"
    zip_lambda "${SCRIPT_DIR}/lambdas/terms-of-service" "$zip_file"

    TOS_LAMBDA_ARN=$(create_lambda_if_not_exists \
        "$TOS_LAMBDA_NAME" \
        "$zip_file" \
        "index.handler" \
        "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}")
    save_output "TOS_LAMBDA_ARN" "$TOS_LAMBDA_ARN"
    log_success "Terms of Service Lambda: ${TOS_LAMBDA_ARN}"

    # Grant AgentCore Gateway permission to invoke Lambda
    aws lambda add-permission \
        --function-name "$TOS_LAMBDA_NAME" \
        --statement-id agentcore-gateway-invoke \
        --action lambda:InvokeFunction \
        --principal bedrock-agentcore.amazonaws.com \
        --region "$AWS_REGION" 2>/dev/null || true

    # --- Create AgentCore Gateway MCP Server ---
    log_info "Creating AgentCore Gateway: AnyCompany-ToS-Tool (IAM Auth)..."

    local tos_lambda_arn_latest="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${TOS_LAMBDA_NAME}:\$LATEST"

    # Check if gateway already exists
    TOS_GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways \
        --region "$AWS_REGION" \
        --query "items[?name=='${TOS_GATEWAY_NAME}'].gatewayId | [0]" \
        --output text 2>/dev/null)

    if [ -z "$TOS_GATEWAY_ID" ] || [ "$TOS_GATEWAY_ID" == "None" ]; then
        TOS_GATEWAY_ID=$(aws bedrock-agentcore-control create-gateway \
            --name "$TOS_GATEWAY_NAME" \
            --description "This tool allows retrieval of information about service conditions by setting the type to Delivery, Payment, or Refund." \
            --protocol-configuration '{"mcp":{"supportedVersions":["2025-11-25","2026-07-28"]}}' \
            --authorizer-type AWS_IAM \
            --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${GATEWAY_ROLE_NAME}" \
            --region "$AWS_REGION" \
            --query 'gatewayId' --output text 2>/dev/null || echo "")
    else
        log_info "Gateway ${TOS_GATEWAY_NAME} already exists: ${TOS_GATEWAY_ID}"
    fi
    save_output "TOS_GATEWAY_ID" "$TOS_GATEWAY_ID"

    if [ -z "$TOS_GATEWAY_ID" ]; then
        log_warn "AgentCore Gateway CLI not available. Create via Console:"
        log_info "  Name: ${TOS_GATEWAY_NAME}"
        log_info "  Description: This tool allows retrieval of information about service conditions by setting the type to Delivery, Payment, or Refund."
        log_info "  Supported version: 2025-11-25"
        log_info "  Inbound Identity: Use IAM Permissions"
        log_info "  Target protocol: MCP target"
        log_info "  Target name: ToS-Lambda"
        log_info "  Target type: Lambda ARN"
        log_info "  Lambda ARN: ${tos_lambda_arn_latest}"
        log_info "  Target schema: Define an inline schema (paste content of schemas/get-tos-lambda.json)"
        log_info "  Role: arn:aws:iam::${ACCOUNT_ID}:role/${GATEWAY_ROLE_NAME}"
    else
        log_success "AgentCore Gateway (ToS): ${TOS_GATEWAY_ID}"

        # Create a target for the Lambda (MCP target protocol)
        local tool_schema
        tool_schema=$(python3 -c "import json; d=json.load(open('${SCRIPT_DIR}/schemas/get-tos-lambda.json')); print(json.dumps(d['tools']))")
        aws bedrock-agentcore-control create-gateway-target \
            --gateway-identifier "$TOS_GATEWAY_ID" \
            --name "ToS-Lambda" \
            --description "This is the function to retrieve Terms of Service details" \
            --target-configuration "{\"mcp\":{\"lambda\":{\"lambdaArn\":\"${tos_lambda_arn_latest}\",\"toolSchema\":{\"inlinePayload\":${tool_schema}}}}}" \
            --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
            --region "$AWS_REGION" 2>&1 || true

        # Retrieve and save the Gateway resource URL
        TOS_GATEWAY_URL=$(aws bedrock-agentcore-control get-gateway \
            --gateway-identifier "$TOS_GATEWAY_ID" \
            --region "$AWS_REGION" \
            --query 'gatewayUrl' --output text 2>/dev/null || echo "")
        save_output "TOS_GATEWAY_URL" "$TOS_GATEWAY_URL"
        if [ -n "$TOS_GATEWAY_URL" ]; then
            log_success "Gateway resource URL: ${TOS_GATEWAY_URL}"
        fi
    fi

    # --- Enable Gateway Log Delivery (Console only) ---
    log_info "Enable log delivery via Console: Bedrock > AgentCore > Gateways > ${TOS_GATEWAY_NAME} > Log deliveries"
    log_info "  Gateway tab: Add APPLICATION_LOGS"
    log_info "  Identity tab: Add APPLICATION_LOGS"

    rm -f "$zip_file"
    log_success "Activity 2 complete!"
}

# =============================================================================
# ACTIVITY 3: Multi-Backend MCP (Products/Sales/Reviews)
# =============================================================================
deploy_multi_backend_mcp() {
    log_step "Activity 3: Multi-Backend MCP (Products + Sales + Customer Reviews)"
    load_outputs

    # --- Deploy Products Lambda ---
    log_info "Deploying Products Lambda..."
    local products_zip="${SCRIPT_DIR}/lambdas/products/function.zip"
    zip_lambda "${SCRIPT_DIR}/lambdas/products" "$products_zip"
    PRODUCTS_LAMBDA_ARN=$(create_lambda_if_not_exists \
        "$PRODUCTS_LAMBDA_NAME" "$products_zip" "index.handler" \
        "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}")
    save_output "PRODUCTS_LAMBDA_ARN" "$PRODUCTS_LAMBDA_ARN"
    log_success "Products Lambda: ${PRODUCTS_LAMBDA_ARN}"

    # --- Deploy Sales Lambda ---
    log_info "Deploying Sales Lambda..."
    local sales_zip="${SCRIPT_DIR}/lambdas/sales/function.zip"
    zip_lambda "${SCRIPT_DIR}/lambdas/sales" "$sales_zip"
    SALES_LAMBDA_ARN=$(create_lambda_if_not_exists \
        "$SALES_LAMBDA_NAME" "$sales_zip" "index.handler" \
        "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}")
    save_output "SALES_LAMBDA_ARN" "$SALES_LAMBDA_ARN"
    log_success "Sales Lambda: ${SALES_LAMBDA_ARN}"

    # --- Products API Gateway (OAuth 2.0 / Native JWT Authorizer) ---
    log_info "Creating Products API Gateway..."
    PRODUCTS_API_ID=$(aws apigatewayv2 create-api \
        --name "$PRODUCTS_API_NAME" \
        --protocol-type HTTP \
        --region "$AWS_REGION" \
        --query 'ApiId' --output text)
    save_output "PRODUCTS_API_ID" "$PRODUCTS_API_ID"

    # Lambda integration
    PRODUCTS_INTEGRATION_ID=$(aws apigatewayv2 create-integration \
        --api-id "$PRODUCTS_API_ID" \
        --integration-type AWS_PROXY \
        --integration-uri "arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${PRODUCTS_LAMBDA_NAME}" \
        --payload-format-version "2.0" \
        --region "$AWS_REGION" \
        --query 'IntegrationId' --output text)

    # JWT Authorizer
    PRODUCTS_AUTHORIZER_ID=$(aws apigatewayv2 create-authorizer \
        --api-id "$PRODUCTS_API_ID" \
        --authorizer-type JWT \
        --name "cognito-jwt-authorizer" \
        --identity-source '$request.header.Authorization' \
        --jwt-configuration "Issuer=https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_D1_POOL_ID},Audience=${COGNITO_D1_M2M_CLIENT_ID}" \
        --region "$AWS_REGION" \
        --query 'AuthorizerId' --output text)

    # Route with authorizer
    aws apigatewayv2 create-route \
        --api-id "$PRODUCTS_API_ID" \
        --route-key "GET /products" \
        --target "integrations/${PRODUCTS_INTEGRATION_ID}" \
        --authorization-type JWT \
        --authorizer-id "$PRODUCTS_AUTHORIZER_ID" \
        --region "$AWS_REGION"

    # Deploy stage
    aws apigatewayv2 create-stage \
        --api-id "$PRODUCTS_API_ID" \
        --stage-name prod \
        --auto-deploy \
        --region "$AWS_REGION"

    # Grant API Gateway permission to invoke Lambda (remove old first for idempotency)
    aws lambda remove-permission --function-name "$PRODUCTS_LAMBDA_NAME" --statement-id apigateway-invoke --region "$AWS_REGION" 2>/dev/null || true
    aws lambda add-permission \
        --function-name "$PRODUCTS_LAMBDA_NAME" \
        --statement-id apigateway-invoke \
        --action lambda:InvokeFunction \
        --principal apigateway.amazonaws.com \
        --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${PRODUCTS_API_ID}/*" \
        --region "$AWS_REGION" 2>/dev/null || true

    PRODUCTS_API_URL="https://${PRODUCTS_API_ID}.execute-api.${AWS_REGION}.amazonaws.com/prod"
    save_output "PRODUCTS_API_URL" "$PRODUCTS_API_URL"
    log_success "Products API: ${PRODUCTS_API_URL}"

    # --- Sales API Gateway (API Key) ---
    log_info "Creating Sales API Gateway..."
    SALES_API_ID=$(aws apigateway create-rest-api \
        --name "$SALES_API_NAME" \
        --api-key-source HEADER \
        --region "$AWS_REGION" \
        --query 'id' --output text)
    save_output "SALES_API_ID" "$SALES_API_ID"

    SALES_ROOT_ID=$(aws apigateway get-resources \
        --rest-api-id "$SALES_API_ID" \
        --region "$AWS_REGION" \
        --query 'items[0].id' --output text)

    # Create /sales resource
    SALES_RESOURCE_ID=$(aws apigateway create-resource \
        --rest-api-id "$SALES_API_ID" \
        --parent-id "$SALES_ROOT_ID" \
        --path-part "sales" \
        --region "$AWS_REGION" \
        --query 'id' --output text)

    # Create /sales/summary sub-resource
    SALES_SUMMARY_RESOURCE_ID=$(aws apigateway create-resource \
        --rest-api-id "$SALES_API_ID" \
        --parent-id "$SALES_RESOURCE_ID" \
        --path-part "summary" \
        --region "$AWS_REGION" \
        --query 'id' --output text)

    # GET method on /sales
    aws apigateway put-method \
        --rest-api-id "$SALES_API_ID" \
        --resource-id "$SALES_RESOURCE_ID" \
        --http-method GET \
        --authorization-type NONE \
        --api-key-required \
        --region "$AWS_REGION"

    aws apigateway put-integration \
        --rest-api-id "$SALES_API_ID" \
        --resource-id "$SALES_RESOURCE_ID" \
        --http-method GET \
        --type AWS_PROXY \
        --integration-http-method POST \
        --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${SALES_LAMBDA_NAME}/invocations" \
        --region "$AWS_REGION"

    # GET method on /sales/summary
    aws apigateway put-method \
        --rest-api-id "$SALES_API_ID" \
        --resource-id "$SALES_SUMMARY_RESOURCE_ID" \
        --http-method GET \
        --authorization-type NONE \
        --api-key-required \
        --region "$AWS_REGION"

    aws apigateway put-integration \
        --rest-api-id "$SALES_API_ID" \
        --resource-id "$SALES_SUMMARY_RESOURCE_ID" \
        --http-method GET \
        --type AWS_PROXY \
        --integration-http-method POST \
        --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${SALES_LAMBDA_NAME}/invocations" \
        --region "$AWS_REGION"

    # Create /sales/by-product sub-resource
    SALES_BY_PRODUCT_RESOURCE_ID=$(aws apigateway create-resource \
        --rest-api-id "$SALES_API_ID" \
        --parent-id "$SALES_RESOURCE_ID" \
        --path-part "by-product" \
        --region "$AWS_REGION" \
        --query 'id' --output text 2>/dev/null || echo "")

    if [ -n "$SALES_BY_PRODUCT_RESOURCE_ID" ] && [ "$SALES_BY_PRODUCT_RESOURCE_ID" != "None" ]; then
        aws apigateway put-method --rest-api-id "$SALES_API_ID" --resource-id "$SALES_BY_PRODUCT_RESOURCE_ID" \
            --http-method GET --authorization-type NONE --api-key-required --region "$AWS_REGION"
        aws apigateway put-integration --rest-api-id "$SALES_API_ID" --resource-id "$SALES_BY_PRODUCT_RESOURCE_ID" \
            --http-method GET --type AWS_PROXY --integration-http-method POST \
            --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${SALES_LAMBDA_NAME}/invocations" \
            --region "$AWS_REGION"
    fi

    # Create /sales/by-region sub-resource
    SALES_BY_REGION_RESOURCE_ID=$(aws apigateway create-resource \
        --rest-api-id "$SALES_API_ID" \
        --parent-id "$SALES_RESOURCE_ID" \
        --path-part "by-region" \
        --region "$AWS_REGION" \
        --query 'id' --output text 2>/dev/null || echo "")

    if [ -n "$SALES_BY_REGION_RESOURCE_ID" ] && [ "$SALES_BY_REGION_RESOURCE_ID" != "None" ]; then
        aws apigateway put-method --rest-api-id "$SALES_API_ID" --resource-id "$SALES_BY_REGION_RESOURCE_ID" \
            --http-method GET --authorization-type NONE --api-key-required --region "$AWS_REGION"
        aws apigateway put-integration --rest-api-id "$SALES_API_ID" --resource-id "$SALES_BY_REGION_RESOURCE_ID" \
            --http-method GET --type AWS_PROXY --integration-http-method POST \
            --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${SALES_LAMBDA_NAME}/invocations" \
            --region "$AWS_REGION"
    fi

    # Grant Lambda invocation permission (remove old first for idempotency)
    aws lambda remove-permission --function-name "$SALES_LAMBDA_NAME" --statement-id apigateway-invoke --region "$AWS_REGION" 2>/dev/null || true
    aws lambda add-permission \
        --function-name "$SALES_LAMBDA_NAME" \
        --statement-id apigateway-invoke \
        --action lambda:InvokeFunction \
        --principal apigateway.amazonaws.com \
        --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${SALES_API_ID}/*" \
        --region "$AWS_REGION" 2>/dev/null || true

    # Deploy API
    aws apigateway create-deployment \
        --rest-api-id "$SALES_API_ID" \
        --stage-name prod \
        --region "$AWS_REGION"

    # Create API Key and Usage Plan
    SALES_API_KEY_ID=$(aws apigateway create-api-key \
        --name "${PROJECT_NAME}-sales-key" \
        --enabled \
        --region "$AWS_REGION" \
        --query 'id' --output text)
    save_output "SALES_API_KEY_ID" "$SALES_API_KEY_ID"

    SALES_API_KEY_VALUE=$(aws apigateway get-api-key \
        --api-key "$SALES_API_KEY_ID" \
        --include-value \
        --region "$AWS_REGION" \
        --query 'value' --output text)
    save_output "SALES_API_KEY_VALUE" "$SALES_API_KEY_VALUE"

    SALES_USAGE_PLAN_ID=$(aws apigateway create-usage-plan \
        --name "${PROJECT_NAME}-sales-plan" \
        --api-stages "[{\"apiId\":\"${SALES_API_ID}\",\"stage\":\"prod\"}]" \
        --throttle '{"rateLimit":100,"burstLimit":200}' \
        --region "$AWS_REGION" \
        --query 'id' --output text)
    save_output "SALES_USAGE_PLAN_ID" "$SALES_USAGE_PLAN_ID"

    aws apigateway create-usage-plan-key \
        --usage-plan-id "$SALES_USAGE_PLAN_ID" \
        --key-id "$SALES_API_KEY_ID" \
        --key-type API_KEY \
        --region "$AWS_REGION"

    SALES_API_URL="https://${SALES_API_ID}.execute-api.${AWS_REGION}.amazonaws.com/prod"
    save_output "SALES_API_URL" "$SALES_API_URL"
    log_success "Sales API: ${SALES_API_URL} (API Key: ${SALES_API_KEY_VALUE})"

    # --- Store Sales API Key in AgentCore Identity Vault ---
    log_info "Storing Sales API key in AgentCore Identity vault..."
    if aws bedrock-agentcore-control get-api-key-credential-provider --name "sales-api-key-resource-server" --region "$AWS_REGION" &>/dev/null; then
        log_info "API key sales-api-key-resource-server already exists"
    else
        aws bedrock-agentcore-control create-api-key-credential-provider \
            --name "sales-api-key-resource-server" \
            --api-key "$SALES_API_KEY_VALUE" \
            --region "$AWS_REGION" 2>&1 && \
            log_success "Stored API key as: sales-api-key-resource-server" || \
            log_warn "Store API key via Console: Bedrock > AgentCore > Identity > Add Outbound Auth > Add API key > Name: sales-api-key-resource-server"
    fi
    save_output "SALES_API_KEY_SECRET_NAME" "sales-api-key-resource-server"

    # --- Prepare OpenAPI schema with actual Sales API URL ---
    log_info "Preparing Sales OpenAPI schema..."
    local sales_schema_file="${SCRIPT_DIR}/schemas/view-sales-api.json"
    local sales_schema_resolved
    sales_schema_resolved=$(mktemp)
    sed "s|{apiGatewayUrl}|${SALES_API_URL}|g" "$sales_schema_file" > "$sales_schema_resolved"
    log_success "Sales OpenAPI schema prepared with endpoint: ${SALES_API_URL}"

    # --- Cognito OpenID Connect Discovery URL ---
    COGNITO_D1_OIDC_URL="https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_D1_POOL_ID}/.well-known/openid-configuration"
    save_output "COGNITO_D1_OIDC_URL" "$COGNITO_D1_OIDC_URL"

    # --- Store Products OAuth Client in AgentCore Identity Vault ---
    log_info "Storing Products OAuth client in AgentCore Identity vault..."

    # Retrieve Cognito Products backend client ID and secret
    COGNITO_D1_PRODUCTS_CLIENT_ID=$(aws cognito-idp list-user-pool-clients \
        --user-pool-id "$COGNITO_D1_POOL_ID" \
        --region "$AWS_REGION" \
        --query "UserPoolClients[?ClientName=='${PROJECT_NAME}-products-backend-client'].ClientId" \
        --output text 2>/dev/null || echo "$COGNITO_D1_M2M_CLIENT_ID")

    if [ -z "$COGNITO_D1_PRODUCTS_CLIENT_ID" ] || [ "$COGNITO_D1_PRODUCTS_CLIENT_ID" == "None" ]; then
        # Create a dedicated products backend client if it doesn't exist
        COGNITO_D1_PRODUCTS_CLIENT_ID=$(aws cognito-idp create-user-pool-client \
            --user-pool-id "$COGNITO_D1_POOL_ID" \
            --client-name "${PROJECT_NAME}-products-backend-client" \
            --generate-secret \
            --explicit-auth-flows ALLOW_USER_SRP_AUTH \
            --allowed-o-auth-flows client_credentials \
            --allowed-o-auth-scopes "retail-api/products.read" \
            --allowed-o-auth-flows-user-pool-client \
            --region "$AWS_REGION" \
            --query 'UserPoolClient.ClientId' --output text)
        log_success "Created Products backend Cognito client: ${COGNITO_D1_PRODUCTS_CLIENT_ID}"
    fi
    save_output "COGNITO_D1_PRODUCTS_CLIENT_ID" "$COGNITO_D1_PRODUCTS_CLIENT_ID"

    COGNITO_D1_PRODUCTS_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
        --user-pool-id "$COGNITO_D1_POOL_ID" \
        --client-id "$COGNITO_D1_PRODUCTS_CLIENT_ID" \
        --region "$AWS_REGION" \
        --query 'UserPoolClient.ClientSecret' --output text)
    save_output "COGNITO_D1_PRODUCTS_CLIENT_SECRET" "$COGNITO_D1_PRODUCTS_CLIENT_SECRET"

    # Update Products API authorizer to accept the Products backend client too
    if [ -n "${PRODUCTS_AUTHORIZER_ID:-}" ]; then
        aws apigatewayv2 update-authorizer \
            --api-id "$PRODUCTS_API_ID" \
            --authorizer-id "$PRODUCTS_AUTHORIZER_ID" \
            --jwt-configuration "Issuer=https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_D1_POOL_ID},Audience=${COGNITO_D1_M2M_CLIENT_ID},${COGNITO_D1_PRODUCTS_CLIENT_ID}" \
            --region "$AWS_REGION" 2>/dev/null || true
    fi

    if aws bedrock-agentcore-control get-oauth2-credential-provider --name "products-oauth-client-resource-server" --region "$AWS_REGION" &>/dev/null; then
        log_info "OAuth client products-oauth-client-resource-server already exists"
    else
        aws bedrock-agentcore-control create-oauth2-credential-provider \
            --name "products-oauth-client-resource-server" \
            --credential-provider-vendor CustomOauth2 \
            --oauth2-provider-config-input "{\"customOauth2ProviderConfig\":{\"oauthDiscovery\":{\"discoveryUrl\":\"${COGNITO_D1_OIDC_URL}\"},\"clientId\":\"${COGNITO_D1_PRODUCTS_CLIENT_ID}\",\"clientSecret\":\"${COGNITO_D1_PRODUCTS_CLIENT_SECRET}\"}}" \
            --region "$AWS_REGION" 2>&1 && \
            log_success "Stored OAuth client as: products-oauth-client-resource-server" || \
            log_warn "Store OAuth client via Console: Bedrock > AgentCore > Identity > Add Outbound Auth > Add OAuth client > Name: products-oauth-client-resource-server"
    fi
    save_output "PRODUCTS_OAUTH_SECRET_NAME" "products-oauth-client-resource-server"

    # --- Create AgentCore Gateway: AnyCompany-Sales-Product-Reviews-Tool ---
    log_info "Creating AgentCore Gateway: ${MULTI_BACKEND_GATEWAY_NAME} (JWT Auth)..."

    MULTI_GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways \
        --region "$AWS_REGION" \
        --query "items[?name=='${MULTI_BACKEND_GATEWAY_NAME}'].gatewayId | [0]" \
        --output text 2>/dev/null)

    if [ -z "$MULTI_GATEWAY_ID" ] || [ "$MULTI_GATEWAY_ID" == "None" ]; then
        MULTI_GATEWAY_ID=$(aws bedrock-agentcore-control create-gateway \
            --name "$MULTI_BACKEND_GATEWAY_NAME" \
            --description "This tool allows retrieval information about Sales, Products in catalog, and former Customer Reviews." \
            --protocol-configuration '{"mcp":{"supportedVersions":["2025-11-25","2026-07-28"]}}' \
            --authorizer-type CUSTOM_JWT \
            --authorizer-configuration "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"${COGNITO_D1_OIDC_URL}\",\"allowedClients\":[\"${COGNITO_D1_M2M_CLIENT_ID}\",\"${COGNITO_D1_PRODUCTS_CLIENT_ID}\"]}}" \
            --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${GATEWAY_ROLE_NAME}" \
            --region "$AWS_REGION" \
            --query 'gatewayId' --output text 2>/dev/null || echo "")
    else
        log_info "Gateway ${MULTI_BACKEND_GATEWAY_NAME} already exists: ${MULTI_GATEWAY_ID}"
    fi
    save_output "MULTI_GATEWAY_ID" "$MULTI_GATEWAY_ID"

    if [ -z "$MULTI_GATEWAY_ID" ]; then
        log_warn "AgentCore Gateway CLI not available. Create via Console:"
        log_info "  Name: ${MULTI_BACKEND_GATEWAY_NAME}"
        log_info "  Description: This tool allows retrieval information about Sales, Products in catalog, and former Customer Reviews."
        log_info "  Supported version: 2025-11-25"
        log_info "  Inbound Identity: Use JSON Web Tokens (JWT)"
        log_info "  Discovery URL: ${COGNITO_D1_OIDC_URL}"
        log_info "  Client ID: ${COGNITO_D1_M2M_CLIENT_ID}"
        log_info ""
        log_info "  [Sales Target]"
        log_info "  Target protocol: MCP target"
        log_info "  Target name: Sales-API-Gateway"
        log_info "  Target description: API Gateway delivering Sales information"
        log_info "  Target type: REST API > OpenAPI schema > Define an inline schema"
        log_info "  Paste contents of: schemas/view-sales-api.json (replace {apiGatewayUrl} with ${SALES_API_URL})"
        log_info "  Outbound Auth: API key > select sales-api-key-resource-server"
        log_info "  Authorization key location: Header, Parameter name: x-api-key"
        log_info ""
        log_info "  [Products Target - add as second target to same gateway]"
        log_info "  Target protocol: MCP target"
        log_info "  Target name: Products-API-Gateway"
        log_info "  Target description: API Gateway delivering Products information"
        log_info "  Target type: REST API > OpenAPI schema > Define an inline schema"
        log_info "  Paste contents of: schemas/view-product-catalog-api.json (replace {apiGatewayUrl} with ${PRODUCTS_API_URL})"
        log_info "  Outbound Auth: OAuth client > products-oauth-client-resource-server"
        log_info "  Auth grant type: Client credentials grant (2LO), Scopes: products/read"
        log_info ""
        log_info "  [Customer Reviews Target - add as third target to same gateway]"
        log_info "  Target protocol: MCP target"
        log_info "  Target name: Customer-Reviews-Table"
        log_info "  Target description: DynamoDB table containing customer product reviews"
        log_info "  Target type: Amazon DynamoDB"
        log_info "  Table name: ${REVIEWS_TABLE_NAME}"
        log_info "  Outbound Auth: IAM"
    else
        log_success "Multi-Backend Gateway: ${MULTI_GATEWAY_ID}"

        # Get credential provider ARNs
        local sales_api_key_arn
        sales_api_key_arn=$(aws bedrock-agentcore-control get-api-key-credential-provider \
            --name "sales-api-key-resource-server" --region "$AWS_REGION" \
            --query 'credentialProviderArn' --output text 2>/dev/null)
        local products_oauth_arn
        products_oauth_arn=$(aws bedrock-agentcore-control get-oauth2-credential-provider \
            --name "products-oauth-client-resource-server" --region "$AWS_REGION" \
            --query 'credentialProviderArn' --output text 2>/dev/null)

        # Create Sales target (OpenAPI schema + API key outbound auth)
        local sales_schema_inline
        sales_schema_inline=$(cat "$sales_schema_resolved" | jq -c '.')
        aws bedrock-agentcore-control create-gateway-target \
            --gateway-identifier "$MULTI_GATEWAY_ID" \
            --name "Sales-API-Gateway" \
            --description "API Gateway delivering Sales information" \
            --target-configuration "{\"mcp\":{\"openApiSchema\":{\"inlinePayload\":$(echo "$sales_schema_inline" | jq -Rs .)}}}" \
            --credential-provider-configurations "[{\"credentialProviderType\":\"API_KEY\",\"credentialProvider\":{\"apiKeyCredentialProvider\":{\"providerArn\":\"${sales_api_key_arn}\",\"credentialParameterName\":\"x-api-key\",\"credentialLocation\":\"HEADER\"}}}]" \
            --region "$AWS_REGION" 2>&1 || true
        log_success "Created Sales target: Sales-API-Gateway"

        # Create Products target (OpenAPI schema + OAuth 2LO outbound auth)
        log_info "Adding Products target to gateway..."
        local products_schema_resolved
        products_schema_resolved=$(mktemp)
        sed "s|{apiGatewayUrl}|${PRODUCTS_API_URL}|g" "${SCRIPT_DIR}/schemas/view-product-catalog-api.json" > "$products_schema_resolved"
        local products_schema_inline
        products_schema_inline=$(cat "$products_schema_resolved" | jq -c '.')

        aws bedrock-agentcore-control create-gateway-target \
            --gateway-identifier "$MULTI_GATEWAY_ID" \
            --name "Products-API-Gateway" \
            --description "API Gateway delivering Products information" \
            --target-configuration "{\"mcp\":{\"openApiSchema\":{\"inlinePayload\":$(echo "$products_schema_inline" | jq -Rs .)}}}" \
            --credential-provider-configurations "[{\"credentialProviderType\":\"OAUTH\",\"credentialProvider\":{\"oauthCredentialProvider\":{\"providerArn\":\"${products_oauth_arn}\",\"scopes\":[\"retail-api/products.read\"],\"grantType\":\"CLIENT_CREDENTIALS\"}}}]" \
            --region "$AWS_REGION" 2>&1 || true
        log_success "Created Products target: Products-API-Gateway"
        rm -f "$products_schema_resolved"

        # --- Activity 3c: Customer Reviews target (DynamoDB — not available as native target via CLI) ---
        log_info "Adding Customer Reviews target..."
        log_warn "DynamoDB native target must be created via Console:"
        log_info "  Gateway > ${MULTI_BACKEND_GATEWAY_NAME} > Targets > Add"
        log_info "  Target name: Customer-Reviews-Table"
        log_info "  Target type: Amazon DynamoDB"
        log_info "  Table name: ${REVIEWS_TABLE_NAME}"
        log_info "  Outbound Auth: IAM"

        # Retrieve Gateway URL
        MULTI_GATEWAY_URL=$(aws bedrock-agentcore-control get-gateway \
            --gateway-identifier "$MULTI_GATEWAY_ID" \
            --region "$AWS_REGION" \
            --query 'gatewayUrl' --output text 2>/dev/null || echo "")
        save_output "MULTI_GATEWAY_URL" "$MULTI_GATEWAY_URL"
        if [ -n "$MULTI_GATEWAY_URL" ]; then
            log_success "Gateway resource URL: ${MULTI_GATEWAY_URL}"
        fi
    fi

    # --- Enable Gateway Log Delivery (Console only) ---
    log_info "Enable log delivery via Console: Bedrock > AgentCore > Gateways > ${MULTI_BACKEND_GATEWAY_NAME} > Log deliveries"
    log_info "  Gateway tab: Add APPLICATION_LOGS"
    log_info "  Identity tab: Add APPLICATION_LOGS"

    rm -f "$products_zip" "$sales_zip" "$auth_zip" "$sales_schema_resolved"
    log_success "Activity 3a (Sales) complete!"
}

# =============================================================================
# ACTIVITY 4: Inventory MCP Tool (Cross-Domain MCP-to-MCP)
# =============================================================================
deploy_inventory_mcp() {
    log_step "Activity 4: Inventory MCP Tool (MCP-to-MCP Cross-Domain)"
    load_outputs

    # =========================================================================
    # VENDOR BACKEND (Trust Domain 2)
    # Inventory Lambda + API Gateway with JWT authorizer (Cognito D2)
    # =========================================================================
    log_info "Deploying Inventory Lambda (vendor backend, Trust Domain 2)..."
    local inv_zip="${SCRIPT_DIR}/lambdas/inventory/function.zip"
    zip_lambda "${SCRIPT_DIR}/lambdas/inventory" "$inv_zip"
    INVENTORY_LAMBDA_ARN=$(create_lambda_if_not_exists \
        "$INVENTORY_LAMBDA_NAME" "$inv_zip" "index.handler" \
        "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}")
    save_output "INVENTORY_LAMBDA_ARN" "$INVENTORY_LAMBDA_ARN"
    log_success "Inventory Lambda: ${INVENTORY_LAMBDA_ARN}"

    log_info "Creating Inventory API Gateway (vendor backend, Trust Domain 2)..."
    INVENTORY_API_ID=$(aws apigatewayv2 get-apis --region "$AWS_REGION" \
        --query "Items[?Name=='${INVENTORY_API_NAME}'].ApiId | [0]" --output text 2>/dev/null)

    if [ -z "$INVENTORY_API_ID" ] || [ "$INVENTORY_API_ID" == "None" ]; then
        INVENTORY_API_ID=$(aws apigatewayv2 create-api \
            --name "$INVENTORY_API_NAME" \
            --protocol-type HTTP \
            --region "$AWS_REGION" \
            --query 'ApiId' --output text)

        INVENTORY_INTEGRATION_ID=$(aws apigatewayv2 create-integration \
            --api-id "$INVENTORY_API_ID" \
            --integration-type AWS_PROXY \
            --integration-uri "arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${INVENTORY_LAMBDA_NAME}" \
            --payload-format-version "2.0" \
            --region "$AWS_REGION" \
            --query 'IntegrationId' --output text)

        # JWT authorizer using Cognito D2
        INVENTORY_AUTHORIZER_ID=$(aws apigatewayv2 create-authorizer \
            --api-id "$INVENTORY_API_ID" \
            --authorizer-type JWT \
            --name "d2-cognito-jwt-authorizer" \
            --identity-source '$request.header.Authorization' \
            --jwt-configuration "Issuer=https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_D2_POOL_ID},Audience=${COGNITO_D2_M2M_CLIENT_ID}" \
            --region "$AWS_REGION" \
            --query 'AuthorizerId' --output text)

        aws apigatewayv2 create-route \
            --api-id "$INVENTORY_API_ID" \
            --route-key "GET /inventory" \
            --target "integrations/${INVENTORY_INTEGRATION_ID}" \
            --authorization-type JWT \
            --authorizer-id "$INVENTORY_AUTHORIZER_ID" \
            --region "$AWS_REGION"

        aws apigatewayv2 create-route \
            --api-id "$INVENTORY_API_ID" \
            --route-key "PUT /inventory" \
            --target "integrations/${INVENTORY_INTEGRATION_ID}" \
            --authorization-type JWT \
            --authorizer-id "$INVENTORY_AUTHORIZER_ID" \
            --region "$AWS_REGION"

        aws apigatewayv2 create-stage \
            --api-id "$INVENTORY_API_ID" \
            --stage-name prod \
            --auto-deploy \
            --region "$AWS_REGION"

        aws lambda remove-permission --function-name "$INVENTORY_LAMBDA_NAME" --statement-id apigateway-invoke --region "$AWS_REGION" 2>/dev/null || true
        aws lambda add-permission \
            --function-name "$INVENTORY_LAMBDA_NAME" \
            --statement-id apigateway-invoke \
            --action lambda:InvokeFunction \
            --principal apigateway.amazonaws.com \
            --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${INVENTORY_API_ID}/*" \
            --region "$AWS_REGION" 2>/dev/null || true

        log_success "Inventory API Gateway created: ${INVENTORY_API_ID}"
    else
        log_info "Inventory API Gateway already exists: ${INVENTORY_API_ID}"
    fi
    save_output "INVENTORY_API_ID" "$INVENTORY_API_ID"

    INVENTORY_API_URL="https://${INVENTORY_API_ID}.execute-api.${AWS_REGION}.amazonaws.com/prod"
    save_output "INVENTORY_API_URL" "$INVENTORY_API_URL"
    log_success "Inventory API (vendor backend): ${INVENTORY_API_URL}"

    # --- Cognito D2 credentials ---
    VENDOR_COGNITO_ISSUER="https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_D2_POOL_ID}"
    VENDOR_COGNITO_TOKEN_ENDPOINT="https://${COGNITO_D2_DOMAIN}.auth.${AWS_REGION}.amazoncognito.com/oauth2/token"
    VENDOR_COGNITO_AUTH_ENDPOINT="https://${COGNITO_D2_DOMAIN}.auth.${AWS_REGION}.amazoncognito.com/oauth2/authorize"
    VENDOR_COGNITO_OIDC_URL="${VENDOR_COGNITO_ISSUER}/.well-known/openid-configuration"

    # --- Store vendor OAuth client in AgentCore Identity vault ---
    # This credential is used by BOTH:
    #   1. Gateway ④ outbound → to authenticate to the Vendor Gateway (JWT 2LO)
    #   2. Vendor Gateway outbound → to get a D2 JWT for calling Inventory API Gateway
    log_info "Creating OAuth client in AgentCore Identity: inventory-oauth-client-mcp-server..."
    if aws bedrock-agentcore-control get-oauth2-credential-provider --name "inventory-oauth-client-mcp-server" --region "$AWS_REGION" &>/dev/null; then
        log_info "OAuth client inventory-oauth-client-mcp-server already exists"
    else
        aws bedrock-agentcore-control create-oauth2-credential-provider \
            --name "inventory-oauth-client-mcp-server" \
            --credential-provider-vendor CognitoOauth2 \
            --oauth2-provider-config-input "{\"includedOauth2ProviderConfig\":{\"clientId\":\"${COGNITO_D2_M2M_CLIENT_ID}\",\"clientSecret\":\"${COGNITO_D2_M2M_CLIENT_SECRET}\",\"issuer\":\"${VENDOR_COGNITO_ISSUER}\",\"authorizationEndpoint\":\"${VENDOR_COGNITO_AUTH_ENDPOINT}\",\"tokenEndpoint\":\"${VENDOR_COGNITO_TOKEN_ENDPOINT}\"}}" \
            --region "$AWS_REGION" 2>&1 && \
            log_success "Stored OAuth client: inventory-oauth-client-mcp-server" || \
            log_warn "Store OAuth client via Console: Bedrock > AgentCore > Identity > Add Outbound Auth > Add OAuth client > Name: inventory-oauth-client-mcp-server"
    fi
    save_output "INVENTORY_OAUTH_SECRET_NAME" "inventory-oauth-client-mcp-server"

    # =========================================================================
    # VENDOR AGENTCORE GATEWAY (Trust Domain 2)
    # Matches architecture: Vendor Gateway (MCP, JWT 2LO inbound) → API GW → Inventory Lambda
    # =========================================================================
    log_info "Creating Vendor Gateway: ${VENDOR_GATEWAY_NAME} (Trust Domain 2)..."

    VENDOR_GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways \
        --region "$AWS_REGION" \
        --query "items[?name=='${VENDOR_GATEWAY_NAME}'].gatewayId | [0]" \
        --output text 2>/dev/null)

    if [ -z "$VENDOR_GATEWAY_ID" ] || [ "$VENDOR_GATEWAY_ID" == "None" ]; then
        VENDOR_GATEWAY_ID=$(aws bedrock-agentcore-control create-gateway \
            --name "$VENDOR_GATEWAY_NAME" \
            --description "Vendor inventory gateway (Trust Domain 2). Fronts the Inventory API." \
            --protocol-configuration '{"mcp":{"supportedVersions":["2025-11-25","2026-07-28"]}}' \
            --authorizer-type CUSTOM_JWT \
            --authorizer-configuration "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"${VENDOR_COGNITO_OIDC_URL}\",\"allowedClients\":[\"${COGNITO_D2_M2M_CLIENT_ID}\"]}}" \
            --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${GATEWAY_ROLE_NAME}" \
            --region "$AWS_REGION" \
            --query 'gatewayId' --output text 2>/dev/null || echo "")
    else
        log_info "Vendor Gateway already exists: ${VENDOR_GATEWAY_ID}"
    fi
    save_output "VENDOR_GATEWAY_ID" "$VENDOR_GATEWAY_ID"

    if [ -n "$VENDOR_GATEWAY_ID" ]; then
        log_success "Vendor Gateway (D2): ${VENDOR_GATEWAY_ID}"

        # Add OpenAPI target with OAuth outbound (D2 JWT to call Inventory API Gateway)
        local existing_vendor_targets
        existing_vendor_targets=$(aws bedrock-agentcore-control list-gateway-targets \
            --gateway-identifier "$VENDOR_GATEWAY_ID" --region "$AWS_REGION" \
            --query 'items | length(@)' --output text 2>/dev/null || echo "0")

        if [ "$existing_vendor_targets" == "0" ]; then
            local inv_oauth_arn
            inv_oauth_arn=$(aws bedrock-agentcore-control get-oauth2-credential-provider \
                --name "inventory-oauth-client-mcp-server" --region "$AWS_REGION" \
                --query 'credentialProviderArn' --output text 2>/dev/null)

            local inv_schema_resolved="$TMPDIR/inventory_schema.json"
            sed "s|{apiGatewayUrl}|${INVENTORY_API_URL}|g" "${SCRIPT_DIR}/schemas/view-inventory-api.json" > "$inv_schema_resolved"
            local inv_schema_inline
            inv_schema_inline=$(cat "$inv_schema_resolved" | jq -c '.' | jq -Rs .)

            aws bedrock-agentcore-control create-gateway-target \
                --gateway-identifier "$VENDOR_GATEWAY_ID" \
                --name "Inventory-API" \
                --description "Inventory REST API behind API Gateway (JWT auth)" \
                --target-configuration "{\"mcp\":{\"openApiSchema\":{\"inlinePayload\":${inv_schema_inline}}}}" \
                --credential-provider-configurations "[{\"credentialProviderType\":\"OAUTH\",\"credentialProvider\":{\"oauthCredentialProvider\":{\"providerArn\":\"${inv_oauth_arn}\",\"scopes\":[\"inventory-api/inventory.read\"],\"grantType\":\"CLIENT_CREDENTIALS\"}}}]" \
                --region "$AWS_REGION" 2>&1 || true
            log_success "Created vendor target: Inventory-API (OpenAPI + OAuth 2LO)"
            rm -f "$inv_schema_resolved"
        else
            log_info "Vendor Gateway already has targets, skipping"
        fi

        VENDOR_MCP_URL=$(aws bedrock-agentcore-control get-gateway \
            --gateway-identifier "$VENDOR_GATEWAY_ID" \
            --region "$AWS_REGION" \
            --query 'gatewayUrl' --output text 2>/dev/null || echo "")
        save_output "VENDOR_MCP_URL" "$VENDOR_MCP_URL"
        log_success "Vendor Gateway URL: ${VENDOR_MCP_URL}"
    else
        log_warn "Failed to create Vendor Gateway. Create via Console."
    fi

    log_info "Enable log delivery via Console: Bedrock > AgentCore > Gateways > ${VENDOR_GATEWAY_NAME} > Log deliveries"
    log_info "  Gateway tab: Add APPLICATION_LOGS"
    log_info "  Identity tab: Add APPLICATION_LOGS"

    # =========================================================================
    # GATEWAY ④ (Trust Domain 1) — your agent's inventory gateway
    # Connects to the Vendor Gateway via MCP-to-MCP
    # =========================================================================
    COGNITO_D1_OIDC_URL="https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_D1_POOL_ID}/.well-known/openid-configuration"

    # Create a dedicated Cognito D1 app client for inventory gateway inbound auth
    COGNITO_D1_INV_CLIENT_ID=$(aws cognito-idp create-user-pool-client \
        --user-pool-id "$COGNITO_D1_POOL_ID" \
        --client-name "${PROJECT_NAME}-corp-inventory-client" \
        --generate-secret \
        --explicit-auth-flows ALLOW_USER_SRP_AUTH \
        --allowed-o-auth-flows client_credentials \
        --allowed-o-auth-scopes "retail-api/inventory.read" "retail-api/inventory.write" \
        --allowed-o-auth-flows-user-pool-client \
        --region "$AWS_REGION" \
        --query 'UserPoolClient.ClientId' --output text 2>/dev/null || echo "${COGNITO_D1_M2M_CLIENT_ID}")
    save_output "COGNITO_D1_INV_CLIENT_ID" "$COGNITO_D1_INV_CLIENT_ID"

    log_info "Creating IAM role: ${INVENTORY_GATEWAY_ROLE_NAME}..."
    create_role_if_not_exists \
        "$INVENTORY_GATEWAY_ROLE_NAME" \
        "${SCRIPT_DIR}/iam/gateway-trust-policy.json" \
        "${INVENTORY_GATEWAY_ROLE_NAME}-policy" \
        "${SCRIPT_DIR}/iam/gateway-execution-policy.json"
    INVENTORY_GATEWAY_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${INVENTORY_GATEWAY_ROLE_NAME}"
    save_output "INVENTORY_GATEWAY_ROLE_ARN" "$INVENTORY_GATEWAY_ROLE_ARN"

    log_info "Creating AgentCore Gateway: ${INVENTORY_GATEWAY_NAME} (JWT inbound, MCP-to-MCP)..."

    INVENTORY_GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways \
        --region "$AWS_REGION" \
        --query "items[?name=='${INVENTORY_GATEWAY_NAME}'].gatewayId | [0]" \
        --output text 2>/dev/null)

    if [ -z "$INVENTORY_GATEWAY_ID" ] || [ "$INVENTORY_GATEWAY_ID" == "None" ]; then
        INVENTORY_GATEWAY_ID=$(aws bedrock-agentcore-control create-gateway \
            --name "$INVENTORY_GATEWAY_NAME" \
            --description "This tool allows to retrieve inventory information from external vendor MCP server." \
            --protocol-configuration '{"mcp":{"supportedVersions":["2025-11-25","2026-07-28"]}}' \
            --authorizer-type CUSTOM_JWT \
            --authorizer-configuration "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"${COGNITO_D1_OIDC_URL}\",\"allowedClients\":[\"${COGNITO_D1_INV_CLIENT_ID}\",\"${COGNITO_D1_M2M_CLIENT_ID}\",\"${COGNITO_D1_PRODUCTS_CLIENT_ID}\"]}}" \
            --role-arn "$INVENTORY_GATEWAY_ROLE_ARN" \
            --region "$AWS_REGION" \
            --query 'gatewayId' --output text 2>/dev/null || echo "")
    else
        log_info "Gateway ${INVENTORY_GATEWAY_NAME} already exists: ${INVENTORY_GATEWAY_ID}"
    fi
    save_output "INVENTORY_GATEWAY_ID" "$INVENTORY_GATEWAY_ID"

    if [ -n "$INVENTORY_GATEWAY_ID" ] && [ -n "$VENDOR_MCP_URL" ]; then
        log_success "Inventory Gateway (D1): ${INVENTORY_GATEWAY_ID}"

        # Check if target already exists
        local existing_inv_targets
        existing_inv_targets=$(aws bedrock-agentcore-control list-gateway-targets \
            --gateway-identifier "$INVENTORY_GATEWAY_ID" --region "$AWS_REGION" \
            --query 'items | length(@)' --output text 2>/dev/null || echo "0")

        if [ "$existing_inv_targets" == "0" ]; then
            # Create MCP server target pointing at the Vendor Gateway
            local inventory_oauth_arn
            inventory_oauth_arn=$(aws bedrock-agentcore-control get-oauth2-credential-provider \
                --name "inventory-oauth-client-mcp-server" --region "$AWS_REGION" \
                --query 'credentialProviderArn' --output text 2>/dev/null)

            aws bedrock-agentcore-control create-gateway-target \
                --gateway-identifier "$INVENTORY_GATEWAY_ID" \
                --name "Inventory-MCP-Target" \
                --description "Vendor inventory MCP server (cross-domain)" \
                --target-configuration "{\"mcp\":{\"mcpServer\":{\"endpoint\":\"${VENDOR_MCP_URL}/mcp\"}}}" \
                --credential-provider-configurations "[{\"credentialProviderType\":\"OAUTH\",\"credentialProvider\":{\"oauthCredentialProvider\":{\"providerArn\":\"${inventory_oauth_arn}\",\"scopes\":[\"inventory-api/inventory.read\"],\"grantType\":\"CLIENT_CREDENTIALS\"}}}]" \
                --region "$AWS_REGION" 2>&1 || true
            log_success "Created target: Inventory-MCP-Target → ${VENDOR_MCP_URL}"
        else
            log_info "Gateway ④ already has targets, skipping"
        fi

        INVENTORY_GATEWAY_URL=$(aws bedrock-agentcore-control get-gateway \
            --gateway-identifier "$INVENTORY_GATEWAY_ID" \
            --region "$AWS_REGION" \
            --query 'gatewayUrl' --output text 2>/dev/null || echo "")
        save_output "INVENTORY_GATEWAY_URL" "$INVENTORY_GATEWAY_URL"
        if [ -n "$INVENTORY_GATEWAY_URL" ]; then
            log_success "Gateway ④ URL: ${INVENTORY_GATEWAY_URL}"
        fi
    else
        log_warn "Create Gateway ④ and MCP target via Console"
        log_info "  MCP server target URL: ${VENDOR_MCP_URL}"
        log_info "  Outbound Auth: OAuth > inventory-oauth-client-mcp-server, 2LO, scope: inventory-api/inventory.read"
    fi

    log_info "Enable log delivery via Console: Bedrock > AgentCore > Gateways > ${INVENTORY_GATEWAY_NAME} > Log deliveries"
    log_info "  Gateway tab: Add APPLICATION_LOGS"
    log_info "  Identity tab: Add APPLICATION_LOGS"

    rm -f "$inv_zip"
    log_success "Activity 4 complete!"
}

# =============================================================================
# ACTIVITY 5: Amazon Verified Permissions
# =============================================================================
deploy_verified_permissions() {
    log_step "Activity 5: Dynamic Tool Filtering with Amazon Verified Permissions"
    load_outputs

    # --- Create Policy Store ---
    log_info "Creating Verified Permissions policy store..."
    AVP_POLICY_STORE_ID=$(aws verifiedpermissions create-policy-store \
        --validation-settings '{"mode":"STRICT"}' \
        --description "Policy store for controlling access to AI agent tools" \
        --region "$AWS_REGION" \
        --query 'policyStoreId' --output text)
    save_output "AVP_POLICY_STORE_ID" "$AVP_POLICY_STORE_ID"
    log_success "Policy Store: ${AVP_POLICY_STORE_ID}"

    # --- Upload Cedar Schema ---
    log_info "Uploading Cedar schema..."
    CEDAR_SCHEMA=$(cat "${SCRIPT_DIR}/policies/schema.cedarschema")
    aws verifiedpermissions put-schema \
        --policy-store-id "$AVP_POLICY_STORE_ID" \
        --definition "{\"cedarJson\": $(echo "$CEDAR_SCHEMA" | jq -Rs .)}" \
        --region "$AWS_REGION"
    log_success "Cedar schema uploaded"

    # --- Connect Cognito as Identity Source ---
    log_info "Connecting Cognito as identity source..."
    aws verifiedpermissions create-identity-source \
        --policy-store-id "$AVP_POLICY_STORE_ID" \
        --configuration "{\"cognitoUserPoolConfiguration\":{\"userPoolArn\":\"arn:aws:cognito-idp:${AWS_REGION}:${ACCOUNT_ID}:userpool/${COGNITO_D1_POOL_ID}\",\"clientIds\":[\"${COGNITO_D1_UI_CLIENT_ID}\"]}}" \
        --principal-entity-type "RetailAgent::User" \
        --region "$AWS_REGION" \
        --output text --query 'identitySourceId'
    log_success "Connected Cognito D1 as identity source"

    # --- Create pre-defined policies ---
    # Tool names follow: <TargetName>___<operationId>
    # ToS tools:      ToS-Lambda___get_terms_of_service, ToS-Lambda___accept_terms_of_service, etc.
    # Products tools: Products-API-Gateway___getProducts
    # Sales tools:    Sales-API-Gateway___getSalesRecords, getSalesSummary, getSalesByProduct, getSalesByRegion
    # Reviews tools:  dynamodb-target___Query, dynamodb-target___Scan, dynamodb-target___GetItem, dynamodb-target___DescribeTable
    # Inventory tool: Inventory-MCP-Target___Inventory-API___getInventory

    # Policy 1: Everyone — ToS + Products (gateway attribute matches target name prefix)
    log_info "Creating 'Everyone' policy (ToS + Products)..."
    EVERYONE_POLICY='permit(
    principal,
    action == RetailAgent::Action::"InvokeTool",
    resource
) when {
    (resource.gateway == "ToS-Lambda" || resource.gateway == "Products-API-Gateway")
    && resource has gateway
};'
    aws verifiedpermissions create-policy \
        --policy-store-id "$AVP_POLICY_STORE_ID" \
        --definition "{\"static\":{\"description\":\"Allow Everyone access to Terms of Service and Products tools\",\"statement\":$(echo "$EVERYONE_POLICY" | jq -Rs .)}}" \
        --region "$AWS_REGION" \
        --output text --query 'policyId' && log_success "Created 'Everyone' policy" || log_warn "Failed to create Everyone policy"

    # Policy 2: Admin — full access to all tools
    log_info "Creating 'Admin' policy (all tools)..."
    ADMIN_POLICY='permit(
    principal,
    action == RetailAgent::Action::"InvokeTool",
    resource
) when {
    principal.role == "admin"
};'
    aws verifiedpermissions create-policy \
        --policy-store-id "$AVP_POLICY_STORE_ID" \
        --definition "{\"static\":{\"description\":\"Allow Admin access to all tools\",\"statement\":$(echo "$ADMIN_POLICY" | jq -Rs .)}}" \
        --region "$AWS_REGION" \
        --output text --query 'policyId' && log_success "Created 'Admin' policy" || log_warn "Failed to create Admin policy"

    log_success "Pre-defined policies created (Everyone + Admin)"

    # Policy 3: Managers — all Sales tools
    log_info "Creating 'Manager Sales' policy..."
    MANAGER_SALES_POLICY='permit(
    principal,
    action == RetailAgent::Action::"InvokeTool",
    resource
) when {
    principal.role == "manager" &&
    resource.gateway == "Sales-API-Gateway" &&
    resource has gateway
};'
    aws verifiedpermissions create-policy \
        --policy-store-id "$AVP_POLICY_STORE_ID" \
        --definition "{\"static\":{\"description\":\"Allow Managers access to Sales tools\",\"statement\":$(echo "$MANAGER_SALES_POLICY" | jq -Rs .)}}" \
        --region "$AWS_REGION" \
        --output text --query 'policyId' && log_success "Created 'Manager Sales' policy" || log_warn "Failed to create Manager Sales policy"

    # Policy 4: Managers — Customer Reviews (DynamoDB) tools
    log_info "Creating 'Manager Reviews' policy..."
    MANAGER_REVIEWS_POLICY='permit(
    principal,
    action == RetailAgent::Action::"InvokeTool",
    resource
) when {
    principal.role == "manager" &&
    resource.gateway == "dynamodb-target" &&
    resource has gateway
};'
    aws verifiedpermissions create-policy \
        --policy-store-id "$AVP_POLICY_STORE_ID" \
        --definition "{\"static\":{\"description\":\"Allow Managers access to Customer Reviews tools\",\"statement\":$(echo "$MANAGER_REVIEWS_POLICY" | jq -Rs .)}}" \
        --region "$AWS_REGION" \
        --output text --query 'policyId' && log_success "Created 'Manager Reviews' policy" || log_warn "Failed to create Manager Reviews policy"

    # Policy 5: Suppliers — Inventory tool
    log_info "Creating 'Supplier Inventory' policy..."
    SUPPLIER_INVENTORY_POLICY='permit(
    principal,
    action == RetailAgent::Action::"InvokeTool",
    resource
) when {
    principal.role == "supplier" &&
    resource.gateway == "Inventory-MCP-Target" &&
    resource has gateway
};'
    aws verifiedpermissions create-policy \
        --policy-store-id "$AVP_POLICY_STORE_ID" \
        --definition "{\"static\":{\"description\":\"Allow Suppliers access to Inventory tool\",\"statement\":$(echo "$SUPPLIER_INVENTORY_POLICY" | jq -Rs .)}}" \
        --region "$AWS_REGION" \
        --output text --query 'policyId' && log_success "Created 'Supplier Inventory' policy" || log_warn "Failed to create Supplier Inventory policy"

    log_success "All 5 policies created (Everyone + Admin + Manager Sales + Manager Reviews + Supplier Inventory)"

    # --- Update agent environment with AVP policy store ID ---
    log_info "Updating agent environment with AVP_POLICY_STORE_ID..."
    local runtime_id
    runtime_id=$(aws bedrock-agentcore-control list-agent-runtimes \
        --region "$AWS_REGION" \
        --query "agentRuntimes[?agentRuntimeName=='${AGENT_RUNTIME_NAME}'].agentRuntimeId | [0]" \
        --output text 2>/dev/null)

    if [ -n "$runtime_id" ] && [ "$runtime_id" != "None" ]; then
        aws bedrock-agentcore-control update-agent-runtime \
            --agent-runtime-id "$runtime_id" \
            --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${ECR_REPO_URI}:latest\"}}" \
            --role-arn "$AGENT_ROLE_ARN" \
            --network-configuration '{"networkMode":"PUBLIC"}' \
            --protocol-configuration '{"serverProtocol":"HTTP"}' \
            --environment-variables "{\"BEDROCK_MODEL_ID\":\"${BEDROCK_MODEL_ID}\",\"AVP_POLICY_STORE_ID\":\"${AVP_POLICY_STORE_ID}\",\"TOS_MCP_ENDPOINT\":\"${TOS_GATEWAY_URL}/mcp\",\"MULTI_BACKEND_MCP_ENDPOINT\":\"${MULTI_GATEWAY_URL}/mcp\",\"INVENTORY_MCP_ENDPOINT\":\"${INVENTORY_GATEWAY_URL}/mcp\"}" \
            --region "$AWS_REGION" 2>&1 && \
            log_success "Updated agent runtime with all environment variables" || \
            log_warn "Failed to update agent runtime environment variables"
    else
        log_warn "Agent runtime not found. Update AVP_POLICY_STORE_ID=${AVP_POLICY_STORE_ID} via Console."
    fi

    log_success "Activity 5 complete!"
}

# =============================================================================
# ACTIVITY 6: Frontend (S3 + CloudFront + Lambda@Edge)
# =============================================================================
deploy_frontend() {
    log_step "Activity 6: Frontend (S3 + CloudFront + Lambda@Edge)"
    load_outputs

    # --- S3 Bucket ---
    log_info "Creating S3 bucket for UI..."
    if ! aws s3api head-bucket --bucket "$UI_BUCKET_NAME" 2>/dev/null; then
        aws s3api create-bucket \
            --bucket "$UI_BUCKET_NAME" \
            --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" 2>/dev/null || \
        aws s3api create-bucket \
            --bucket "$UI_BUCKET_NAME" \
            --region "$AWS_REGION"
    fi

    aws s3api put-public-access-block \
        --bucket "$UI_BUCKET_NAME" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    log_success "S3 Bucket: ${UI_BUCKET_NAME}"

    # --- Upload frontend files ---
    log_info "Uploading frontend files..."
    aws s3 sync "${SCRIPT_DIR}/frontend/" "s3://${UI_BUCKET_NAME}/" \
        --region "$AWS_REGION"
    log_success "Frontend files uploaded"

    # --- Lambda@Edge (must be in us-east-1) ---
    log_info "Deploying Lambda@Edge for authentication..."
    local edge_zip="${SCRIPT_DIR}/lambdas/edge-auth/function.zip"

    # Lambda@Edge cannot use env vars — inject values into the JS before zipping
    # CALLBACK_URL is derived from the Host header at runtime (no chicken-and-egg with CloudFront)
    local edge_staging_dir
    edge_staging_dir=$(mktemp -d)
    sed -e "s|%%COGNITO_DOMAIN%%|${COGNITO_D1_DOMAIN}.auth.${AWS_REGION}.amazoncognito.com|g" \
        -e "s|%%CLIENT_ID%%|${COGNITO_D1_UI_CLIENT_ID}|g" \
        "${SCRIPT_DIR}/lambdas/edge-auth/index.js" > "${edge_staging_dir}/index.js"
    (cd "$edge_staging_dir" && zip -r "$edge_zip" index.js)
    rm -rf "$edge_staging_dir"

    EDGE_LAMBDA_ARN=$(aws lambda create-function \
        --function-name "$EDGE_LAMBDA_NAME" \
        --runtime "nodejs22.x" \
        --handler "index.handler" \
        --role "arn:aws:iam::${ACCOUNT_ID}:role/${EDGE_LAMBDA_ROLE_NAME}" \
        --zip-file "fileb://${edge_zip}" \
        --timeout 5 \
        --memory-size 128 \
        --region us-east-1 \
        --query 'FunctionArn' --output text 2>/dev/null || \
    aws lambda update-function-code \
        --function-name "$EDGE_LAMBDA_NAME" \
        --zip-file "fileb://${edge_zip}" \
        --region us-east-1 \
        --query 'FunctionArn' --output text)

    # Wait for Lambda to become Active before publishing
    aws lambda wait function-active-v2 --function-name "$EDGE_LAMBDA_NAME" --region us-east-1

    # Publish a version (required for Lambda@Edge)
    EDGE_LAMBDA_VERSION_ARN=$(aws lambda publish-version \
        --function-name "$EDGE_LAMBDA_NAME" \
        --region us-east-1 \
        --query 'FunctionArn' --output text)
    save_output "EDGE_LAMBDA_VERSION_ARN" "$EDGE_LAMBDA_VERSION_ARN"
    log_success "Lambda@Edge: ${EDGE_LAMBDA_VERSION_ARN}"

    # --- CloudFront OAC ---
    log_info "Creating CloudFront Origin Access Control..."
    OAC_ID=$(aws cloudfront list-origin-access-controls \
        --query "OriginAccessControlList.Items[?Name=='${PROJECT_NAME}-oac'].Id | [0]" \
        --output text 2>/dev/null)
    if [ -z "$OAC_ID" ] || [ "$OAC_ID" == "None" ]; then
        OAC_ID=$(aws cloudfront create-origin-access-control \
            --origin-access-control-config "{\"Name\":\"${PROJECT_NAME}-oac\",\"OriginAccessControlOriginType\":\"s3\",\"SigningBehavior\":\"always\",\"SigningProtocol\":\"sigv4\"}" \
            --query 'OriginAccessControl.Id' --output text)
    else
        log_info "OAC already exists: ${OAC_ID}"
    fi
    save_output "OAC_ID" "$OAC_ID"

    # --- CloudFront Distribution ---
    if [ -n "${CF_DIST_ID:-}" ] && [ "$CF_DIST_ID" != "None" ] && \
       aws cloudfront get-distribution --id "$CF_DIST_ID" &>/dev/null; then
        log_info "Updating existing CloudFront distribution: ${CF_DIST_ID}..."

        # Get current config and ETag for update
        local cf_current
        cf_current=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --output json)
        local cf_etag
        cf_etag=$(echo "$cf_current" | jq -r '.ETag')

        # Update the Lambda@Edge ARN in the existing config
        local cf_updated_config
        cf_updated_config=$(echo "$cf_current" | jq --arg arn "$EDGE_LAMBDA_VERSION_ARN" --arg oac "$OAC_ID" \
            '.DistributionConfig |
             .DefaultCacheBehavior.LambdaFunctionAssociations.Items[0].LambdaFunctionARN = $arn |
             .Origins.Items[0].OriginAccessControlId = $oac |
             .CustomErrorResponses = {"Quantity":2,"Items":[{"ErrorCode":403,"ResponsePagePath":"/index.html","ResponseCode":"200","ErrorCachingMinTTL":0},{"ErrorCode":404,"ResponsePagePath":"/index.html","ResponseCode":"200","ErrorCachingMinTTL":0}]}')

        echo "$cf_updated_config" | aws cloudfront update-distribution \
            --id "$CF_DIST_ID" \
            --distribution-config file:///dev/stdin \
            --if-match "$cf_etag" \
            --output text --query 'Distribution.Id'
        log_success "Updated CloudFront distribution: ${CF_DIST_ID}"
    else
        log_info "Creating CloudFront distribution..."
        CF_CONFIG=$(cat <<CFEOF
{
  "CallerReference": "${PROJECT_NAME}-$(date +%s)",
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "S3-${UI_BUCKET_NAME}",
        "DomainName": "${UI_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com",
        "OriginAccessControlId": "${OAC_ID}",
        "S3OriginConfig": {
          "OriginAccessIdentity": ""
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "S3-${UI_BUCKET_NAME}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"]
    },
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "LambdaFunctionAssociations": {
      "Quantity": 1,
      "Items": [
        {
          "LambdaFunctionARN": "${EDGE_LAMBDA_VERSION_ARN}",
          "EventType": "viewer-request",
          "IncludeBody": false
        }
      ]
    },
    "Compress": true
  },
  "CustomErrorResponses": {
    "Quantity": 2,
    "Items": [
      {
        "ErrorCode": 403,
        "ResponsePagePath": "/index.html",
        "ResponseCode": "200",
        "ErrorCachingMinTTL": 0
      },
      {
        "ErrorCode": 404,
        "ResponsePagePath": "/index.html",
        "ResponseCode": "200",
        "ErrorCachingMinTTL": 0
      }
    ]
  },
  "Enabled": true,
  "Comment": "${PROJECT_NAME} UI"
}
CFEOF
)
        CF_DIST_ID=$(echo "$CF_CONFIG" | aws cloudfront create-distribution \
            --distribution-config file:///dev/stdin \
            --query 'Distribution.Id' --output text)
        save_output "CF_DIST_ID" "$CF_DIST_ID"
    fi

    CF_DOMAIN=$(aws cloudfront get-distribution \
        --id "$CF_DIST_ID" \
        --query 'Distribution.DomainName' --output text)
    save_output "CF_DOMAIN" "$CF_DOMAIN"
    log_success "CloudFront Distribution: ${CF_DOMAIN}"

    # --- S3 Bucket Policy for CloudFront ---
    log_info "Setting S3 bucket policy for CloudFront..."
    BUCKET_POLICY=$(cat <<BPEOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipal",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudfront.amazonaws.com"
      },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${UI_BUCKET_NAME}/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${CF_DIST_ID}"
        }
      }
    }
  ]
}
BPEOF
)
    echo "$BUCKET_POLICY" | aws s3api put-bucket-policy \
        --bucket "$UI_BUCKET_NAME" \
        --policy file:///dev/stdin

    # --- Update Cognito callback URLs ---
    log_info "Updating Cognito callback URLs with CloudFront domain..."
    aws cognito-idp update-user-pool-client \
        --user-pool-id "$COGNITO_D1_POOL_ID" \
        --client-id "$COGNITO_D1_UI_CLIENT_ID" \
        --callback-urls "https://${CF_DOMAIN}/callback" \
        --logout-urls "https://${CF_DOMAIN}" \
        --allowed-o-auth-flows code \
        --allowed-o-auth-scopes openid email profile \
        --allowed-o-auth-flows-user-pool-client \
        --supported-identity-providers COGNITO \
        --region "$AWS_REGION"
    log_success "Updated Cognito callback: https://${CF_DOMAIN}/callback"

    rm -f "$edge_zip"
    log_success "Activity 6 complete!"
    echo ""
    log_info "UI URL: https://${CF_DOMAIN}"
    log_info "Test credentials (password: Workshop1!):"
    log_info "  sarah.johnson  (admin    / operations) — full access"
    log_info "  mike.chen      (everyone / finance)    — ToS + Products only"
    log_info "  lisa.rodriguez (manager  / inventory)  — ToS + Products + Sales + Reviews"
    log_info "  james.miller   (supplier / sales)      — ToS + Products + Inventory"
    log_info "  maria.gonzalez (everyone / support)    — ToS + Products only"
}

# =============================================================================
# Main execution
# =============================================================================
main() {
    echo ""
    echo "========================================================"
    echo "  Amazon Bedrock AgentCore MCP Workshop - Deployment"
    echo "========================================================"
    echo ""

    check_prerequisites

    case "$ACTIVITY" in
        all)
            deploy_foundation
            deploy_agent
            deploy_tos_mcp
            deploy_multi_backend_mcp
            deploy_inventory_mcp
            deploy_verified_permissions
            deploy_frontend
            ;;
        0|foundation)  deploy_foundation ;;
        1|agent)       load_outputs && deploy_agent ;;
        2|tos)         load_outputs && deploy_tos_mcp ;;
        3|multi)       load_outputs && deploy_multi_backend_mcp ;;
        4|inventory)   load_outputs && deploy_inventory_mcp ;;
        5|avp)         load_outputs && deploy_verified_permissions ;;
        6|frontend)    load_outputs && deploy_frontend ;;
        *)
            log_error "Unknown activity: ${ACTIVITY}"
            echo "Usage: ./deploy.sh [--activity <0-6|all>]"
            exit 1
            ;;
    esac

    echo ""
    echo "========================================================"
    echo "  Deployment Complete!"
    echo "========================================================"
    echo ""
    log_info "Resource outputs saved to: ${SCRIPT_DIR}/outputs.env"
    echo ""
}

main
