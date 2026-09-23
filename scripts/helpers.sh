#!/bin/bash
# =============================================================================
# Helper functions for deployment scripts
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

check_prerequisites() {
    log_step "Checking Prerequisites"

    local missing=0

    if ! command -v aws &>/dev/null; then
        log_error "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        missing=1
    else
        log_success "AWS CLI: $(aws --version | head -1)"
    fi

    if ! command -v python3 &>/dev/null; then
        log_error "Python 3 not found."
        missing=1
    else
        log_success "Python: $(python3 --version)"
    fi

    if ! command -v podman &>/dev/null; then
        log_warn "Podman not found (needed for Activity 1 - Agent deployment)."
    else
        log_success "Podman: $(podman --version)"
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq not found. Install: brew install jq / apt install jq"
        missing=1
    else
        log_success "jq: $(jq --version)"
    fi

    if ! aws sts get-caller-identity &>/dev/null; then
        log_error "AWS credentials not configured. Run: aws configure"
        missing=1
    else
        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        export ACCOUNT_ID
        export UI_BUCKET_NAME="${PROJECT_NAME}-ui-${ACCOUNT_ID}"
        log_success "AWS Account: ${ACCOUNT_ID}"
        log_success "AWS Region: ${AWS_REGION}"
    fi

    if [ $missing -ne 0 ]; then
        log_error "Missing prerequisites. Please install them and try again."
        exit 1
    fi
}

wait_for_role() {
    local role_name=$1
    log_info "Waiting for IAM role ${role_name} to propagate..."
    sleep 10
}

create_role_if_not_exists() {
    local role_name=$1
    local trust_policy_file=$2
    local policy_name=$3
    local policy_file=$4

    if aws iam get-role --role-name "$role_name" &>/dev/null; then
        log_info "IAM role ${role_name} already exists, updating policy."
    else
        aws iam create-role \
            --role-name "$role_name" \
            --assume-role-policy-document "file://${trust_policy_file}" \
            --output text --query 'Role.Arn'
        log_success "Created IAM role: ${role_name}"
    fi

    aws iam put-role-policy \
        --role-name "$role_name" \
        --policy-name "$policy_name" \
        --policy-document "file://${policy_file}"
}

zip_lambda() {
    local source_dir=$1
    local output_zip=$2

    local tmp_dir
    tmp_dir=$(mktemp -d)
    cp "${source_dir}"/* "${tmp_dir}/"
    (cd "${tmp_dir}" && zip -r "${output_zip}" .)
    rm -rf "${tmp_dir}"

    log_success "Packaged Lambda: ${output_zip}"
}

zip_lambda_with_deps() {
    local source_dir=$1
    local output_zip=$2

    local tmp_dir
    tmp_dir=$(mktemp -d)
    if [ -f "${source_dir}/requirements.txt" ]; then
        log_info "Installing pip dependencies for Lambda..." >&2
        pip install -q -r "${source_dir}/requirements.txt" -t "${tmp_dir}/" >&2
    fi
    cp "${source_dir}"/*.py "${tmp_dir}/"
    (cd "${tmp_dir}" && zip -qr "${output_zip}" .)
    rm -rf "${tmp_dir}"

    log_success "Packaged Lambda with dependencies: ${output_zip}" >&2
}

create_lambda_if_not_exists() {
    local function_name=$1
    local zip_file=$2
    local handler=$3
    local role_arn=$4
    local runtime=${5:-python3.12}
    local env_vars=${6:-""}

    if aws lambda get-function --function-name "$function_name" --region "$AWS_REGION" &>/dev/null; then
        log_info "Lambda ${function_name} already exists, updating code..." >&2
        aws lambda update-function-code \
            --function-name "$function_name" \
            --zip-file "fileb://${zip_file}" \
            --region "$AWS_REGION" \
            --output text --query 'FunctionArn'
    else
        if [ -n "$env_vars" ]; then
            local env_json="{"
            local first=true
            IFS=',' read -ra PAIRS <<< "$env_vars"
            for pair in "${PAIRS[@]}"; do
                local key="${pair%%=*}"
                local val="${pair#*=}"
                if [ "$first" = true ]; then
                    first=false
                else
                    env_json="${env_json},"
                fi
                env_json="${env_json}\"${key}\":\"${val}\""
            done
            env_json="${env_json}}"

            aws lambda create-function \
                --function-name "$function_name" \
                --runtime "$runtime" \
                --handler "$handler" \
                --role "$role_arn" \
                --zip-file "fileb://${zip_file}" \
                --timeout 30 \
                --memory-size 256 \
                --environment "{\"Variables\":${env_json}}" \
                --region "$AWS_REGION" \
                --output text --query FunctionArn
        else
            aws lambda create-function \
                --function-name "$function_name" \
                --runtime "$runtime" \
                --handler "$handler" \
                --role "$role_arn" \
                --zip-file "fileb://${zip_file}" \
                --timeout 30 \
                --memory-size 256 \
                --region "$AWS_REGION" \
                --output text --query FunctionArn
        fi
        log_success "Created Lambda: ${function_name}" >&2
    fi
}

save_output() {
    local key=$1
    local value=$2
    local output_file="${SCRIPT_DIR}/outputs.env"

    if grep -q "^${key}=" "$output_file" 2>/dev/null; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${key}=.*|${key}=${value}|" "$output_file"
        else
            sed -i "s|^${key}=.*|${key}=${value}|" "$output_file"
        fi
    else
        echo "${key}=${value}" >> "$output_file"
    fi
}

load_outputs() {
    local output_file="${SCRIPT_DIR}/outputs.env"
    if [ -f "$output_file" ]; then
        source "$output_file"
    fi
}
