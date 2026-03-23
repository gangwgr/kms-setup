#!/bin/bash
# Unified KMS Plugin Deployment Script
# Supports both Cloud Vault and Local Vault installation
#
# Usage:
#   # Option 1: Use existing Cloud Vault
#   ./deploy-kms.sh --cloud \
#       --vault-addr "https://your-vault.hashicorp.cloud:8200" \
#       --vault-namespace "admin" \
#       --username "admin-user" \
#       --password "your-password"
#
#   # Option 2: Install local Vault and configure
#   ./deploy-kms.sh --local
#
#   # Option 3: Use environment variables
#   export VAULT_ADDR="https://..."
#   export VAULT_USERNAME="admin-user"
#   export VAULT_PASSWORD="password"
#   ./deploy-kms.sh --cloud
#
#   # Option 4: Use private image from Quay.io
#   export QUAY_USERNAME="your-robot-account+name"
#   export QUAY_PASSWORD="your-robot-token"
#   ./deploy-kms.sh --local
#
#   # Option 5: Deploy static pod with Cloud Vault (HCP)
#   ./deploy-kms.sh --cloud --static-pod \
#       --vault-addr "https://your-vault.hashicorp.cloud:8200" \
#       --vault-namespace "admin" \
#       --username "admin-user" \
#       --password "your-password"

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
MODE=""
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_USERNAME="${VAULT_USERNAME:-}"
VAULT_PASSWORD="${VAULT_PASSWORD:-}"
KMS_NAMESPACE="openshift-kms-plugin"
LOCAL_VAULT_NAMESPACE="vault-system"
SKIP_TLS_VERIFY="false"
DEPLOY_TYPE=""  # "static-pod" or "daemonset"; auto-selected if not specified
QUAY_USERNAME="${QUAY_USERNAME:-}"
QUAY_PASSWORD="${QUAY_PASSWORD:-}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cloud)
            MODE="cloud"
            shift
            ;;
        --local)
            MODE="local"
            shift
            ;;
        --vault-addr)
            VAULT_ADDR="$2"
            shift 2
            ;;
        --vault-namespace)
            VAULT_NAMESPACE="$2"
            shift 2
            ;;
        --token)
            VAULT_TOKEN="$2"
            shift 2
            ;;
        --username)
            VAULT_USERNAME="$2"
            shift 2
            ;;
        --password)
            VAULT_PASSWORD="$2"
            shift 2
            ;;
        --skip-tls-verify)
            SKIP_TLS_VERIFY="true"
            shift
            ;;
        --static-pod)
            DEPLOY_TYPE="static-pod"
            shift
            ;;
        --daemonset)
            DEPLOY_TYPE="daemonset"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--cloud|--local] [options]"
            echo ""
            echo "Modes:"
            echo "  --cloud             Use existing cloud/external Vault"
            echo "  --local             Install Vault locally using Helm"
            echo ""
            echo "Deployment type (optional, overrides default):"
            echo "  --static-pod        Deploy KMS plugin as static pod on control plane nodes"
            echo "  --daemonset         Deploy KMS plugin as DaemonSet"
            echo "  (Default: --local uses static-pod, --cloud uses daemonset)"
            echo ""
            echo "Options for --cloud:"
            echo "  --vault-addr        Vault server address"
            echo "  --vault-namespace   Vault namespace (Enterprise/HCP)"
            echo "  --token             Vault token (or use --username/--password)"
            echo "  --username          Vault username for userpass auth"
            echo "  --password          Vault password for userpass auth"
            echo "  --skip-tls-verify   Skip TLS verification"
            echo ""
            echo "Environment variables:"
            echo "  VAULT_ADDR, VAULT_NAMESPACE, VAULT_TOKEN"
            echo "  VAULT_USERNAME, VAULT_PASSWORD"
            echo ""
            echo "Examples:"
            echo "  # Cloud Vault with static pod deployment:"
            echo "  $0 --cloud --static-pod --vault-addr https://vault.example.com:8200 --username admin --password pass"
            echo ""
            echo "  # Cloud Vault with DaemonSet (default for cloud):"
            echo "  $0 --cloud --vault-addr https://vault.example.com:8200 --token hvs.xxx"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check mode
if [ -z "$MODE" ]; then
    echo -e "${YELLOW}No mode specified. Choose:${NC}"
    echo "  1) Cloud Vault (existing instance)"
    echo "  2) Local Vault (install with Helm)"
    read -p "Enter choice [1/2]: " choice
    case $choice in
        1) MODE="cloud" ;;
        2) MODE="local" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
fi

# Set default deploy type if not specified
if [ -z "$DEPLOY_TYPE" ]; then
    if [ "$MODE" = "local" ]; then
        DEPLOY_TYPE="static-pod"
    else
        # Cloud mode - let user choose deployment type
        echo -e "${YELLOW}Choose deployment type:${NC}"
        echo "  1) DaemonSet (default for cloud)"
        echo "  2) Static Pod (deploy directly to control plane nodes)"
        read -p "Enter choice [1/2] (default: 1): " deploy_choice
        case $deploy_choice in
            2) DEPLOY_TYPE="static-pod" ;;
            *) DEPLOY_TYPE="daemonset" ;;
        esac
    fi
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}KMS Plugin Deployment${NC}"
echo -e "${GREEN}  Vault Mode:   $MODE${NC}"
echo -e "${GREEN}  Deploy Type:  $DEPLOY_TYPE${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

#######################################
# Install Local Vault with Helm
#######################################
install_local_vault() {
    echo -e "${YELLOW}Installing Vault locally with Helm...${NC}"
    
    # Check prerequisites
    command -v helm >/dev/null 2>&1 || { echo "Error: helm is required"; exit 1; }
    
    # Add Helm repo
    helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
    helm repo update
    
    # Create namespace
    oc create namespace $LOCAL_VAULT_NAMESPACE 2>/dev/null || true
    oc label namespace $LOCAL_VAULT_NAMESPACE \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        --overwrite
    
    # Create values file with persistent storage
    cat > /tmp/vault-values.yaml << 'VALUESEOF'
global:
  openshift: true
server:
  # Use Docker Hub image explicitly
  image:
    repository: docker.io/hashicorp/vault
    tag: "1.15.4"
  # Use persistent storage instead of dev mode
  dataStorage:
    enabled: true
    size: 2Gi
    storageClass: null
    accessMode: ReadWriteOnce
  resources:
    requests:
      memory: 128Mi
      cpu: 100m
    limits:
      memory: 256Mi
      cpu: 500m
  # Deploy on control plane nodes alongside KMS plugin
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  # Tolerate control plane taints
  tolerations:
    - operator: Exists
  route:
    enabled: false
  standalone:
    enabled: true
    config: |
      ui = true
      listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
        cluster_address = "[::]:8201"
      }
      storage "file" {
        path = "/vault/data"
      }
  ha:
    enabled: false
injector:
  enabled: false
ui:
  enabled: true
VALUESEOF

    # Install Vault
    echo "  Installing Vault with Helm..."
    # Disable OpenAPI validation to avoid OpenShift CRD conflicts
    export HELM_EXPERIMENTAL_OCI=1
    helm upgrade --install vault hashicorp/vault \
        --namespace $LOCAL_VAULT_NAMESPACE \
        --values /tmp/vault-values.yaml \
        --disable-openapi-validation \
        --wait --timeout 5m

    # Wait for pod to be running (not ready, as it needs initialization)
    echo "  Waiting for Vault pod..."
    for i in {1..60}; do
        POD_STATUS=$(oc get pod vault-0 -n $LOCAL_VAULT_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$POD_STATUS" = "Running" ]; then
            echo "    Vault pod is running"
            break
        fi
        if [ $i -eq 60 ]; then
            echo -e "${RED}Error: Vault pod did not start within timeout${NC}"
            exit 1
        fi
        sleep 2
    done

    # Wait for Vault container to be ready to accept commands
    echo "  Waiting for Vault to be ready..."
    set +e  # vault status returns non-zero when sealed
    for i in {1..30}; do
        if oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- vault status 2>&1 | grep -q "Initialized"; then
            echo "    Vault is responding"
            break
        fi
        sleep 2
    done
    set -e

    # Initialize Vault if not already initialized
    echo "  Initializing Vault..."
    # Properly handle vault status when Vault is sealed/uninitialized
    # vault status returns exit code 2 when sealed, so we need to ignore it
    set +e  # Temporarily disable exit on error
    INIT_STATUS=$(oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- vault status -format=json 2>&1 | jq -r '.initialized // false' 2>/dev/null)
    set -e  # Re-enable exit on error

    if [ "$INIT_STATUS" != "true" ]; then
        echo "    Vault is not initialized, initializing now..."
        INIT_OUTPUT=$(oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json)
        UNSEAL_KEY=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
        VAULT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

        # Save keys to a secret for persistence
        oc create secret generic vault-init-keys \
            --namespace=$LOCAL_VAULT_NAMESPACE \
            --from-literal=unseal-key="$UNSEAL_KEY" \
            --from-literal=root-token="$VAULT_TOKEN" \
            --dry-run=client -o yaml | oc apply -f -

        echo "    Vault initialized successfully"
    else
        echo "    Vault already initialized, retrieving keys..."
        # Verify secret exists before trying to read it
        if ! oc get secret vault-init-keys -n $LOCAL_VAULT_NAMESPACE >/dev/null 2>&1; then
            echo -e "${RED}Error: Vault is initialized but vault-init-keys secret not found${NC}"
            echo "    Please manually retrieve the unseal key and root token"
            exit 1
        fi
        UNSEAL_KEY=$(oc get secret vault-init-keys -n $LOCAL_VAULT_NAMESPACE -o jsonpath='{.data.unseal-key}' | base64 -d)
        VAULT_TOKEN=$(oc get secret vault-init-keys -n $LOCAL_VAULT_NAMESPACE -o jsonpath='{.data.root-token}' | base64 -d)

        # Validate that we got non-empty values
        if [ -z "$UNSEAL_KEY" ] || [ -z "$VAULT_TOKEN" ]; then
            echo -e "${RED}Error: Failed to retrieve Vault keys from secret${NC}"
            exit 1
        fi
    fi

    # Unseal Vault
    echo "  Unsealing Vault..."
    # Properly handle vault status when Vault is sealed
    # vault status returns exit code 2 when sealed, so we need to ignore it
    set +e  # Temporarily disable exit on error
    SEAL_STATUS=$(oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- vault status -format=json 2>&1 | jq -r '.sealed // true' 2>/dev/null)
    set -e  # Re-enable exit on error

    if [ "$SEAL_STATUS" = "true" ]; then
        oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- vault operator unseal "$UNSEAL_KEY" >/dev/null
        echo "    Vault unsealed successfully"
    else
        echo "    Vault already unsealed"
    fi

    # Wait for Vault to be ready
    sleep 5

    # Set Vault connection info
    # For KMS plugin, use internal cluster address
    VAULT_INTERNAL_ADDR="http://$(oc get svc vault -n $LOCAL_VAULT_NAMESPACE -o jsonpath='{.spec.clusterIP}'):8200"
    VAULT_NAMESPACE=""

    # No need for port-forward - we'll use oc exec directly
    VAULT_ADDR="$VAULT_INTERNAL_ADDR"

    rm -f /tmp/vault-values.yaml

    echo -e "${GREEN}Vault installed successfully${NC}"
    echo "  Internal Address: $VAULT_INTERNAL_ADDR"
    echo "  Root Token: ${VAULT_TOKEN:0:20}..."
    echo "  Unseal Key stored in secret: vault-init-keys"
}

#######################################
# Authenticate to Vault
#######################################
authenticate_vault() {
    echo -e "${YELLOW}Authenticating to Vault...${NC}"
    
    if [ -n "$VAULT_TOKEN" ]; then
        echo "Using provided token"
    elif [ -n "$VAULT_USERNAME" ] && [ -n "$VAULT_PASSWORD" ]; then
        echo "Authenticating with userpass..."
        local tls_flag=""
        [ "$SKIP_TLS_VERIFY" = "true" ] && tls_flag="-k"

        local -a ns_args=()
        [ -n "$VAULT_NAMESPACE" ] && ns_args=("--header" "X-Vault-Namespace: $VAULT_NAMESPACE")

        local auth_resp http_code
        auth_resp=$(curl -s --noproxy "*" --max-time 15 $tls_flag \
            "${ns_args[@]}" \
            -w "\n%{http_code}" \
            --request POST \
            --data "{\"password\": \"$VAULT_PASSWORD\"}" \
            "$VAULT_ADDR/v1/auth/userpass/login/$VAULT_USERNAME" 2>&1) || true

        http_code=$(echo "$auth_resp" | tail -n1)
        auth_resp=$(echo "$auth_resp" | sed '$d')

        VAULT_TOKEN=$(echo "$auth_resp" | jq -r '.auth.client_token // empty' 2>/dev/null)
        
        if [ -z "$VAULT_TOKEN" ]; then
            echo -e "${RED}Error: Failed to authenticate (HTTP $http_code)${NC}"
            echo "  Vault address:  $VAULT_ADDR"
            echo "  Username:       $VAULT_USERNAME"
            echo "  Namespace:      ${VAULT_NAMESPACE:-(none)}"
            echo "  Response: $(echo "$auth_resp" | jq -r '.errors[]?' 2>/dev/null || echo "$auth_resp")"
            exit 1
        fi
    else
        echo -e "${RED}Error: No authentication method provided${NC}"
        echo "Provide --token or --username/--password"
        exit 1
    fi
    
    echo -e "${GREEN}Authentication successful${NC}"
}

#######################################
# Configure Vault for KMS
#######################################
configure_vault() {
    echo ""
    echo -e "${YELLOW}Configuring Vault for KMS...${NC}"

    # For local mode, use oc exec directly instead of curl
    if [ "$MODE" = "local" ]; then
        configure_vault_local
        return
    fi

    # Build curl headers array for cloud mode
    # Add --noproxy to bypass any local proxy (Squid, etc.)
    local -a curl_headers=("--noproxy" "*" "--header" "X-Vault-Token: $VAULT_TOKEN")
    if [ -n "$VAULT_NAMESPACE" ]; then
        curl_headers+=("--header" "X-Vault-Namespace: $VAULT_NAMESPACE")
    fi

    # Verify Vault connectivity
    # HCP Vault /v1/sys/health may return 404 when called with a namespace header,
    # because the health endpoint only exists at the root level.
    # Try without namespace first (root-level), then with namespace, then fall back
    # to token lookup as a final connectivity check.
    echo "  Verifying Vault connectivity..."
    local vault_ready=false
    local tls_flag=""
    [ "$SKIP_TLS_VERIFY" = "true" ] && tls_flag="-k"

    # Method 1: Health check without namespace header (works for HCP Vault)
    local health_code
    health_code=$(curl -s -o /dev/null -w "%{http_code}" $tls_flag --noproxy "*" \
        --max-time 10 \
        "$VAULT_ADDR/v1/sys/health" 2>/dev/null || echo "000")
    case "$health_code" in
        200|429|472|473)
            echo "    Vault is ready (health status: $health_code)"
            vault_ready=true
            ;;
    esac

    # Method 2: If health check failed, try token self-lookup (works with namespace)
    if [ "$vault_ready" = "false" ]; then
        local lookup_code
        lookup_code=$(curl -s -o /dev/null -w "%{http_code}" $tls_flag --noproxy "*" \
            --header "X-Vault-Token: $VAULT_TOKEN" \
            ${VAULT_NAMESPACE:+--header "X-Vault-Namespace: $VAULT_NAMESPACE"} \
            --max-time 10 \
            "$VAULT_ADDR/v1/auth/token/lookup-self" 2>/dev/null || echo "000")
        if [ "$lookup_code" = "200" ]; then
            echo "    Vault is ready (token lookup successful)"
            vault_ready=true
        else
            echo "    Health check returned: $health_code, token lookup returned: $lookup_code"
        fi
    fi

    if [ "$vault_ready" = "false" ]; then
        echo -e "${YELLOW}Warning: Could not confirm Vault health via API${NC}"
        echo "  Vault address: $VAULT_ADDR"
        echo -e "${YELLOW}  Authentication was successful earlier - continuing anyway...${NC}"
    fi

    # Enable Transit
    echo "  Enabling Transit secrets engine..."
    local response
    response=$(curl -s -w "\n%{http_code}" "${curl_headers[@]}" \
        --request POST --data '{"type": "transit"}' \
        "$VAULT_ADDR/v1/sys/mounts/transit" 2>&1)
    local http_code=$(echo "$response" | tail -n1)
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        echo "    Transit enabled successfully"
    elif echo "$response" | grep -q "path is already in use"; then
        echo "    (already enabled)"
    else
        echo -e "${RED}Error: Failed to enable Transit. HTTP code: $http_code${NC}"
        echo "$response"
        exit 1
    fi

    # Create key
    echo "  Creating KMS key..."
    response=$(curl -s -w "\n%{http_code}" "${curl_headers[@]}" \
        --request POST --data '{"type": "aes256-gcm96"}' \
        "$VAULT_ADDR/v1/transit/keys/kms-key" 2>&1)
    http_code=$(echo "$response" | tail -n1)
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        echo "    KMS key created successfully"
    else
        echo "    (key may already exist or creation in progress)"
    fi

    # Enable AppRole
    echo "  Enabling AppRole auth..."
    response=$(curl -s -w "\n%{http_code}" "${curl_headers[@]}" \
        --request POST --data '{"type": "approle"}' \
        "$VAULT_ADDR/v1/sys/auth/approle" 2>&1)
    http_code=$(echo "$response" | tail -n1)
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        echo "    AppRole enabled successfully"
    elif echo "$response" | grep -q "path is already in use"; then
        echo "    (already enabled)"
    else
        echo -e "${RED}Error: Failed to enable AppRole. HTTP code: $http_code${NC}"
        echo "$response"
        exit 1
    fi

    # Verify AppRole is enabled
    echo "  Verifying AppRole auth method..."
    response=$(curl -s "${curl_headers[@]}" "$VAULT_ADDR/v1/sys/auth")
    # HCP Vault returns auth methods under .data (e.g. .data["approle/"]) while
    # self-hosted Vault may return them at the top level (e.g. .["approle/"])
    if echo "$response" | jq -e '.["approle/"] // .data["approle/"] // .auth["approle/"]' >/dev/null 2>&1; then
        echo "    AppRole verified"
    elif echo "$response" | grep -q "approle"; then
        echo "    AppRole verified (found in response)"
    else
        echo -e "${YELLOW}Warning: Could not verify AppRole in sys/auth response${NC}"
        echo "    Response keys: $(echo "$response" | jq -r 'keys | join(", ")' 2>/dev/null || echo 'unable to parse')"
        echo "    Continuing anyway (AppRole enable returned success)..."
    fi

    # Create policy
    echo "  Creating KMS policy..."
    response=$(curl -s -w "\n%{http_code}" "${curl_headers[@]}" \
        --request PUT \
        --data '{
          "policy": "path \"transit/encrypt/kms-key\" { capabilities = [\"update\"] }\npath \"transit/decrypt/kms-key\" { capabilities = [\"update\"] }\npath \"transit/keys/kms-key\" { capabilities = [\"read\"] }\npath \"sys/license/status\" { capabilities = [\"read\"] }"
        }' \
        "$VAULT_ADDR/v1/sys/policies/acl/kms-plugin-policy" 2>&1)
    http_code=$(echo "$response" | tail -n1)
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        echo "    Policy created successfully"
    else
        echo -e "${YELLOW}Warning: Policy creation returned HTTP code: $http_code${NC}"
    fi

    # Create AppRole
    echo "  Creating AppRole role..."
    response=$(curl -s -w "\n%{http_code}" "${curl_headers[@]}" \
        --request POST \
        --data '{"policies": ["kms-plugin-policy"], "token_ttl": "1h", "token_max_ttl": "24h"}' \
        "$VAULT_ADDR/v1/auth/approle/role/kms-plugin" 2>&1)
    http_code=$(echo "$response" | tail -n1)
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        echo "    AppRole role created successfully"
    else
        echo -e "${YELLOW}Warning: Role creation returned HTTP code: $http_code${NC}"
    fi

    # Get credentials with error checking
    echo "  Getting AppRole credentials..."
    local role_response
    role_response=$(curl -s "${curl_headers[@]}" \
        "$VAULT_ADDR/v1/auth/approle/role/kms-plugin/role-id" 2>&1)

    ROLE_ID=$(echo "$role_response" | jq -r '.data.role_id' 2>/dev/null)

    if [ -z "$ROLE_ID" ] || [ "$ROLE_ID" = "null" ]; then
        echo -e "${RED}Error: Failed to get Role ID${NC}"
        echo "Response: $role_response"
        exit 1
    fi
    echo "    Role ID retrieved"

    local secret_response
    secret_response=$(curl -s "${curl_headers[@]}" \
        --request POST \
        "$VAULT_ADDR/v1/auth/approle/role/kms-plugin/secret-id" 2>&1)

    SECRET_ID=$(echo "$secret_response" | jq -r '.data.secret_id' 2>/dev/null)

    if [ -z "$SECRET_ID" ] || [ "$SECRET_ID" = "null" ]; then
        echo -e "${RED}Error: Failed to get Secret ID${NC}"
        echo "Response: $secret_response"
        exit 1
    fi
    echo "    Secret ID retrieved"

    echo -e "${GREEN}Vault configured successfully${NC}"
    echo "  Role ID: $ROLE_ID"
    echo "  Secret ID: ${SECRET_ID:0:20}..."
}

#######################################
# Configure Vault for KMS (Local Mode)
#######################################
configure_vault_local() {
    echo "  Using local Vault via oc exec..."

    # Use the VAULT_TOKEN from installation (retrieved from secret)
    local vault_cmd_prefix="VAULT_TOKEN=$VAULT_TOKEN"

    # Enable Transit
    echo "  Enabling Transit secrets engine..."
    TRANSIT_OUTPUT=$(oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- sh -c "$vault_cmd_prefix vault secrets enable transit" 2>&1)
    if echo "$TRANSIT_OUTPUT" | grep -q "Success\|path is already in use"; then
        echo "    Transit enabled"
    else
        echo -e "${RED}Error: Failed to enable Transit${NC}"
        echo "    Output: $TRANSIT_OUTPUT"
        echo "    Vault Token: ${VAULT_TOKEN:0:10}..."
        echo "    Tip: Check if Vault is initialized and unsealed with: oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- vault status"
        exit 1
    fi

    # Create key (idempotent - will skip if exists)
    echo "  Creating KMS key..."
    if oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- sh -c "$vault_cmd_prefix vault write -f transit/keys/kms-key type=aes256-gcm96" 2>&1 | grep -q "Success\|Key already exists"; then
        echo "    KMS key configured"
    else
        # Key might already exist, try to read it
        if oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- sh -c "$vault_cmd_prefix vault read transit/keys/kms-key" >/dev/null 2>&1; then
            echo "    KMS key already exists"
        else
            echo -e "${YELLOW}Warning: Could not verify KMS key${NC}"
        fi
    fi

    # Enable AppRole
    echo "  Enabling AppRole auth..."
    APPROLE_OUTPUT=$(oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- sh -c "$vault_cmd_prefix vault auth enable approle" 2>&1)
    if echo "$APPROLE_OUTPUT" | grep -q "Success\|path is already in use"; then
        echo "    AppRole enabled"
    else
        echo -e "${RED}Error: Failed to enable AppRole${NC}"
        echo "    Output: $APPROLE_OUTPUT"
        exit 1
    fi

    # Verify AppRole is enabled
    echo "  Verifying AppRole auth method..."
    if ! oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- sh -c "$vault_cmd_prefix vault auth list" 2>&1 | grep -q "approle/"; then
        echo -e "${RED}Error: AppRole auth method not found${NC}"
        exit 1
    fi
    echo "    AppRole verified"

    # Create policy
    echo "  Creating KMS policy..."
    oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- sh -c "$vault_cmd_prefix vault policy write kms-plugin-policy - <<EOF
path \"transit/encrypt/kms-key\" {
  capabilities = [\"update\"]
}
path \"transit/decrypt/kms-key\" {
  capabilities = [\"update\"]
}
path \"transit/keys/kms-key\" {
  capabilities = [\"read\"]
}
path \"sys/license/status\" {
  capabilities = [\"read\"]
}
EOF" >/dev/null 2>&1
    echo "    Policy created"

    # Create AppRole (idempotent)
    echo "  Creating AppRole role..."
    oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- sh -c "$vault_cmd_prefix vault write auth/approle/role/kms-plugin \
      policies=\"kms-plugin-policy\" \
      token_ttl=1h \
      token_max_ttl=24h" >/dev/null 2>&1
    echo "    AppRole role created"

    # Get credentials
    echo "  Getting AppRole credentials..."
    ROLE_OUTPUT=$(oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- sh -c "$vault_cmd_prefix vault read auth/approle/role/kms-plugin/role-id -format=json" 2>&1)
    ROLE_ID=$(echo "$ROLE_OUTPUT" | jq -r '.data.role_id' 2>/dev/null)

    if [ -z "$ROLE_ID" ] || [ "$ROLE_ID" = "null" ]; then
        echo -e "${RED}Error: Failed to get Role ID${NC}"
        echo "    Output: $ROLE_OUTPUT"
        exit 1
    fi
    echo "    Role ID retrieved"

    SECRET_OUTPUT=$(oc exec -n $LOCAL_VAULT_NAMESPACE vault-0 -- sh -c "$vault_cmd_prefix vault write -f auth/approle/role/kms-plugin/secret-id -format=json" 2>&1)
    SECRET_ID=$(echo "$SECRET_OUTPUT" | jq -r '.data.secret_id' 2>/dev/null)

    if [ -z "$SECRET_ID" ] || [ "$SECRET_ID" = "null" ]; then
        echo -e "${RED}Error: Failed to get Secret ID${NC}"
        echo "    Output: $SECRET_OUTPUT"
        exit 1
    fi
    echo "    Secret ID retrieved"

    echo -e "${GREEN}Vault configured successfully${NC}"
    echo "  Role ID: $ROLE_ID"
    echo "  Secret ID: ${SECRET_ID:0:20}..."
}

#######################################
# Deploy KMS Plugin to OpenShift
#######################################
deploy_kms_plugin() {
    echo ""
    echo -e "${YELLOW}Deploying KMS plugin to OpenShift (deploy type: $DEPLOY_TYPE)...${NC}"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Create namespace
    echo "  Creating namespace..."
    oc apply -f $SCRIPT_DIR/namespace.yaml

    # Deploy as static pod if requested (works with both cloud and local modes)
    if [ "$DEPLOY_TYPE" = "static-pod" ]; then
        deploy_static_pod
        return
    fi

    # DaemonSet deployment
    # Create service account
    echo "  Creating service account..."
    oc apply -f $SCRIPT_DIR/serviceaccount.yaml

    # Check for private image pull secret
    if [ -n "$QUAY_USERNAME" ] && [ -n "$QUAY_PASSWORD" ]; then
        echo "  Creating Quay.io pull secret..."
        oc create secret docker-registry quay-pull-secret \
            --namespace=$KMS_NAMESPACE \
            --docker-server=quay.io \
            --docker-username="$QUAY_USERNAME" \
            --docker-password="$QUAY_PASSWORD" \
            --dry-run=client -o yaml | oc apply -f -

        # Link secret to service account
        oc secrets link vault-kms-plugin quay-pull-secret --for=pull -n $KMS_NAMESPACE
        echo "    Pull secret linked to service account"
    fi

    # Create secret
    echo "  Creating credentials secret..."
    local secret_vault_addr="$VAULT_ADDR"

    # Use heredoc to avoid issues with empty values
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vault-kms-credentials
  namespace: $KMS_NAMESPACE
type: Opaque
stringData:
  VAULT_ADDR: "$secret_vault_addr"
  VAULT_NAMESPACE: "$VAULT_NAMESPACE"
  VAULT_ROLE_ID: "$ROLE_ID"
  VAULT_SECRET_ID: "$SECRET_ID"
  VAULT_KEY_NAME: "kms-key"
EOF

    # Update daemonset for skip-tls if needed
    if [ "$SKIP_TLS_VERIFY" = "true" ]; then
        echo "  Deploying DaemonSet (with skip-tls-verify)..."
    else
        echo "  Deploying DaemonSet..."
    fi
    oc apply -f $SCRIPT_DIR/daemonset.yaml

    # Wait for pods
    echo "  Waiting for KMS plugin pods..."
    sleep 10
    oc wait --for=condition=Ready pod -l app=vault-kube-kms \
        -n $KMS_NAMESPACE --timeout=120s || true

    echo -e "${GREEN}KMS plugin deployed successfully${NC}"
    oc get pods -n $KMS_NAMESPACE
}

#######################################
# Configure Global Pull Secret for Static Pods
#######################################
configure_global_pull_secret() {
    echo "  Adding Quay.io credentials to global pull secret..."

    # Get existing pull secret
    oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/global-pull-secret.json

    # Create Quay.io auth string
    # Note: macOS base64 doesn't support -w 0, use -b 0 or pipe through tr
    QUAY_AUTH=$(printf '%s' "$QUAY_USERNAME:$QUAY_PASSWORD" | base64 | tr -d '\n')

    # Merge with existing pull secret using jq
    jq ".auths += {\"quay.io\": {\"auth\": \"$QUAY_AUTH\"}}" /tmp/global-pull-secret.json > /tmp/merged-pull-secret.json

    # Update the global pull secret
    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json

    # Verify the update
    echo "    Verifying quay.io entry in global pull secret..."
    if oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -e '.auths["quay.io"]' >/dev/null 2>&1; then
        echo "    ✓ quay.io credentials added to global pull secret"
    else
        echo -e "${RED}    ✗ WARNING: quay.io entry NOT found in global pull secret after update${NC}"
        echo "    The pull secret update may have failed. Check manually:"
        echo "    oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\\.dockerconfigjson}' | base64 -d | jq '.auths | keys'"
    fi

    # Clean up
    rm -f /tmp/global-pull-secret.json /tmp/merged-pull-secret.json

    echo "    Global pull secret updated"
    echo "    Note: Nodes need time to pick up new credentials"
    echo "    MachineConfigPool will roll out changes to each node (takes 10-20 minutes)"
    echo "    Monitor with: oc get mcp"
    echo "    Waiting for initial propagation..."

    # Wait for the pull secret to begin propagating
    for i in {1..6}; do
        echo "    Waiting... ($i/6)"
        sleep 10
    done

    # Show MachineConfigPool status
    echo ""
    echo "    MachineConfigPool status:"
    oc get mcp --no-headers 2>/dev/null || true
}

#######################################
# Deploy KMS Plugin as Static Pod
#######################################
deploy_static_pod() {
    echo ""
    echo -e "${YELLOW}Deploying KMS plugin as static pod...${NC}"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Check for private image pull credentials
    if [ -n "$QUAY_USERNAME" ] && [ -n "$QUAY_PASSWORD" ]; then
        echo "  Configuring image pull credentials for static pods..."
        configure_global_pull_secret
    fi

    # Prepare vault address for static pod
    # For local mode, use internal cluster address; for cloud mode, use the external Vault address
    local secret_vault_addr
    if [ "$MODE" = "local" ]; then
        secret_vault_addr="$VAULT_INTERNAL_ADDR"
    else
        secret_vault_addr="$VAULT_ADDR"
    fi

    # Create static pod manifest with substituted values
    echo "  Creating static pod manifest..."
    cat > /tmp/vault-kube-kms-static.yaml <<'STATICPODEOF'
apiVersion: v1
kind: Pod
metadata:
  name: vault-kube-kms
  namespace: openshift-kms-plugin
  labels:
    app: vault-kube-kms
    tier: control-plane
spec:
  priorityClassName: system-node-critical
  containers:
  - name: vault-kube-kms
    image: quay.io/rhn_support_rgangwar/vault-kube-kms:latest
    imagePullPolicy: Always
    command:
    - /bin/sh
    - -c
    args:
    - |
      echo "$VAULT_SECRET_ID" > /tmp/secret-id
      exec /vault-kube-kms \
        -listen-address=unix:///var/run/kmsplugin/kms.sock \
        -vault-address=$VAULT_ADDR \
        -vault-namespace=$VAULT_NAMESPACE \
        -transit-mount=transit \
        -transit-key=$VAULT_KEY_NAME \
        -log-level=debug-extended \
        -approle-role-id=$VAULT_ROLE_ID \
        -approle-secret-id-path=/tmp/secret-id
STATICPODEOF

    # Append environment variables with actual values
    cat >> /tmp/vault-kube-kms-static.yaml <<EOF
    env:
    - name: VAULT_ROLE_ID
      value: "$ROLE_ID"
    - name: VAULT_SECRET_ID
      value: "$SECRET_ID"
    - name: VAULT_ADDR
      value: "$secret_vault_addr"
    - name: VAULT_NAMESPACE
      value: "$VAULT_NAMESPACE"
    - name: VAULT_KEY_NAME
      value: "kms-key"
    volumeMounts:
    - name: kmsplugin
      mountPath: /var/run/kmsplugin
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 128Mi
    securityContext:
      privileged: true
  volumes:
  - name: kmsplugin
    hostPath:
      path: /var/run/kmsplugin
      type: DirectoryOrCreate
EOF

    # Get list of control plane nodes
    echo "  Getting control plane nodes..."
    CONTROL_PLANE_NODES=$(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}')

    if [ -z "$CONTROL_PLANE_NODES" ]; then
        echo -e "${RED}Error: No control plane nodes found${NC}"
        exit 1
    fi

    echo "  Found control plane nodes: $CONTROL_PLANE_NODES"

    # Deploy static pod to each control plane node
    for node in $CONTROL_PLANE_NODES; do
        echo "  Deploying static pod to node: $node"

        # Create base64 encoded manifest to avoid shell escaping issues
        # Note: macOS base64 doesn't support -w 0, use tr -d to strip newlines
        MANIFEST_B64=$(cat /tmp/vault-kube-kms-static.yaml | base64 | tr -d '\n')

        # Deploy using oc debug node with base64 encoding
        echo "    Copying manifest to $node:/etc/kubernetes/manifests/"

        oc debug node/$node -q -- chroot /host bash -c "
            mkdir -p /etc/kubernetes/manifests
            echo '$MANIFEST_B64' | base64 -d > /etc/kubernetes/manifests/vault-kube-kms.yaml
            chmod 644 /etc/kubernetes/manifests/vault-kube-kms.yaml
        " 2>&1 | grep -v "^Temporary namespace" | grep -v "^This container will be kept" | grep -v "^Waiting for" || true

        # Verify the file was created with content
        FILE_SIZE=$(oc debug node/$node -q -- chroot /host stat -c %s /etc/kubernetes/manifests/vault-kube-kms.yaml 2>/dev/null || echo "0")

        if [ "$FILE_SIZE" -gt 100 ]; then
            echo "    ✓ Static pod manifest deployed to $node (size: $FILE_SIZE bytes)"
        else
            echo -e "    ${YELLOW}⚠ Warning: Manifest on $node is too small ($FILE_SIZE bytes)${NC}"
        fi
    done

    # Clean up temporary files
    rm -f /tmp/vault-kube-kms-static.yaml /tmp/deploy-static-pod.sh

    # Wait for static pods to start
    echo ""
    echo "  Waiting for static pods to start (this may take 1-2 minutes)..."
    sleep 30

    echo ""
    echo -e "${GREEN}Static pod deployment initiated${NC}"
    echo ""
    echo "Checking static pod status on control plane nodes..."
    echo "(Static pods appear with node name suffix, e.g., vault-kube-kms-master-0)"
    echo ""

    # Check for static pods
    local found_pods=0
    for node in $CONTROL_PLANE_NODES; do
        local node_short=$(echo $node | cut -d'.' -f1)
        echo "Node: $node"
        if oc get pods -n openshift-kms-plugin -o wide 2>/dev/null | grep "vault-kube-kms.*$node_short"; then
            found_pods=$((found_pods + 1))
        else
            echo "  Static pod not yet visible on $node"
        fi
        echo ""
    done

    if [ $found_pods -gt 0 ]; then
        echo -e "${GREEN}✓ Found $found_pods static pod(s)${NC}"
        echo ""
        echo "If any pods show ErrImagePull or ImagePullBackOff:"
        echo "  - This is normal if Quay credentials were just added"
        echo "  - Nodes need to restart to pick up the new pull secret"
        echo "  - Wait 2-5 minutes and check again: oc get pods -n openshift-kms-plugin"
        echo "  - Or manually restart kubelet on affected nodes"
    else
        echo -e "${YELLOW}⚠ Static pods not yet visible. This is normal - they may take 30-60 seconds to appear.${NC}"
    fi

    echo ""
    echo "Useful commands:"
    echo "  Check pod status:  oc get pods -n openshift-kms-plugin -o wide"
    echo "  View pod logs:     oc logs -n openshift-kms-plugin vault-kube-kms-<node-name>"
    echo "  Remove static pod: oc debug node/<node-name> -- chroot /host rm /etc/kubernetes/manifests/vault-kube-kms.yaml"
}

#######################################
# Enable KMSEncryption FeatureGate
#######################################
enable_kms_featuregate() {
    echo ""
    echo -e "${YELLOW}Enabling KMSEncryption FeatureGate...${NC}"

    # Check if the featuregate is already enabled
    local current_features
    current_features=$(oc get featuregate cluster -o json 2>/dev/null || echo "{}")

    if echo "$current_features" | jq -e '.spec.customNoUpgrade.enabled // [] | index("KMSEncryptionProvider")' >/dev/null 2>&1; then
        echo "  KMSEncryptionProvider FeatureGate already enabled"
        return
    fi

    echo "  Patching FeatureGate to enable KMSEncryptionProvider..."
    echo -e "${YELLOW}  WARNING: This sets featureSet=CustomNoUpgrade which prevents minor version upgrades${NC}"
    oc patch featuregate/cluster --type=merge -p '{
        "spec": {
            "featureSet": "CustomNoUpgrade",
            "customNoUpgrade": {
                "enabled": ["KMSEncryption"]
            }
        }
    }'

    echo -e "${GREEN}  KMSEncryptionProvider FeatureGate enabled${NC}"
    echo ""
    echo "  Waiting for kube-apiserver to roll out with the new feature gate..."
    echo "  This can take several minutes as each control plane node is updated sequentially."
    echo ""
    echo "  Monitor with:"
    echo "    oc get clusteroperator kube-apiserver"
    echo "    oc get nodes -l node-role.kubernetes.io/master"
    echo ""

    # Wait for kube-apiserver operator to begin progressing
    echo "  Waiting for kube-apiserver operator to start rolling out..."
    local max_wait=120
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local progressing
        progressing=$(oc get clusteroperator kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "Unknown")
        if [ "$progressing" = "True" ]; then
            echo "    kube-apiserver is progressing..."
            break
        fi
        sleep 10
        waited=$((waited + 10))
        echo "    Waiting for rollout to begin... ($waited/${max_wait}s)"
    done

    # Wait for kube-apiserver operator to become available and not progressing
    echo "  Waiting for kube-apiserver rollout to complete (this may take 10-20 minutes)..."
    oc wait clusteroperator kube-apiserver \
        --for=condition=Progressing=False \
        --timeout=1200s 2>/dev/null || echo -e "${YELLOW}  Timeout waiting for rollout - check manually${NC}"

    local available
    available=$(oc get clusteroperator kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
    if [ "$available" = "True" ]; then
        echo -e "${GREEN}  kube-apiserver rollout complete and available${NC}"
    else
        echo -e "${YELLOW}  kube-apiserver availability: $available - please verify manually${NC}"
    fi
}

#######################################
# Enable KMS Encryption
#######################################
enable_kms_encryption() {
    echo ""
    echo -e "${YELLOW}Enabling KMS encryption on etcd...${NC}"
    
    oc patch apiserver cluster --type=merge -p '{"spec":{"encryption":{"type":"KMS"}}}'
    
    echo -e "${GREEN}KMS encryption enabled${NC}"
    echo ""
    echo "Monitor progress with:"
    echo "  oc get clusteroperator kube-apiserver"
    echo "  oc get kubeapiserver cluster -o jsonpath='{.status.conditions}' | jq '.[] | select(.type | contains(\"Encrypt\"))'"
}

#######################################
# Main
#######################################
main() {
    # Check prerequisites
    command -v oc >/dev/null 2>&1 || { echo "Error: oc is required"; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "Error: jq is required"; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo "Error: curl is required"; exit 1; }
    
    if [ "$MODE" = "local" ]; then
        install_local_vault
    else
        # Cloud mode - collect Vault details
        # If running interactively (no --vault-addr provided), prompt for all details
        if [ -z "$VAULT_ADDR" ] || [[ "$VAULT_ADDR" == *"127.0.0.1"* ]] || [[ "$VAULT_ADDR" == *"localhost"* ]]; then
            echo -e "${YELLOW}Enter Cloud Vault details:${NC}"
            read -p "  Vault address (e.g., https://vault.example.com:8200): " VAULT_ADDR
        else
            echo "Using Vault address: $VAULT_ADDR"
        fi
        
        if [ -z "$VAULT_NAMESPACE" ]; then
            read -p "  Vault namespace (e.g., admin, or leave empty): " VAULT_NAMESPACE
        else
            echo "Using Vault namespace: $VAULT_NAMESPACE"
        fi
        
        # Check for existing credentials
        if [ -n "$VAULT_TOKEN" ]; then
            echo "Using existing token: ${VAULT_TOKEN:0:10}..."
        elif [ -n "$VAULT_USERNAME" ]; then
            echo "Using existing username: $VAULT_USERNAME"
        else
            # No credentials - prompt for them
            echo ""
            echo "Choose authentication method:"
            echo "  1) Username/Password"
            echo "  2) Token"
            read -p "Enter choice [1/2]: " auth_choice
            case $auth_choice in
                1)
                    read -p "  Username: " VAULT_USERNAME
                    read -sp "  Password: " VAULT_PASSWORD
                    echo ""
                    ;;
                2)
                    read -sp "  Token: " VAULT_TOKEN
                    echo ""
                    ;;
                *)
                    echo "Invalid choice"
                    exit 1
                    ;;
            esac
        fi
        authenticate_vault
    fi
    
    configure_vault

    # Enable KMSEncryption FeatureGate (required before KMS can be used)
    echo ""
    read -p "Enable KMSEncryption FeatureGate now? (required for KMS) [Y/n]: " enable_fg
    if [ "$enable_fg" != "n" ] && [ "$enable_fg" != "N" ]; then
        enable_kms_featuregate
    else
        echo ""
        echo -e "${YELLOW}Skipping FeatureGate - you must enable it manually before KMS will work:${NC}"
        echo "  oc patch featuregate/cluster --type=merge -p '{\"spec\":{\"featureSet\":\"CustomNoUpgrade\",\"customNoUpgrade\":{\"enabled\":[\"KMSEncryptionProvider\"]}}}'"
    fi

    deploy_kms_plugin
    
    echo ""
    read -p "Enable KMS encryption on etcd now? [y/N]: " enable_now
    if [ "$enable_now" = "y" ] || [ "$enable_now" = "Y" ]; then
        enable_kms_encryption
    else
        echo ""
        echo "To enable KMS encryption later, run:"
        echo "  oc patch apiserver cluster --type=merge -p '{\"spec\":{\"encryption\":{\"type\":\"KMS\"}}}'"
    fi
    
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}Deployment complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
}

main
