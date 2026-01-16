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
        --help|-h)
            echo "Usage: $0 [--cloud|--local] [options]"
            echo ""
            echo "Modes:"
            echo "  --cloud             Use existing cloud/external Vault"
            echo "  --local             Install Vault locally using Helm"
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

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}KMS Plugin Deployment - Mode: $MODE${NC}"
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
    
    # Create values file
    cat > /tmp/vault-values.yaml << 'VALUESEOF'
global:
  openshift: true
server:
  # Use Docker Hub image explicitly
  image:
    repository: docker.io/hashicorp/vault
    tag: "1.15.4"
  dev:
    enabled: true
    devRootToken: "root"
  resources:
    requests:
      memory: 256Mi
      cpu: 250m
  route:
    enabled: true
    tls:
      termination: edge
  standalone:
    enabled: true
  ha:
    enabled: false
injector:
  enabled: false
ui:
  enabled: true
VALUESEOF
    
    # Install Vault
    helm upgrade --install vault hashicorp/vault \
        --namespace $LOCAL_VAULT_NAMESPACE \
        --values /tmp/vault-values.yaml \
        --wait --timeout 5m
    
    # Wait for pod
    oc wait --for=condition=Ready pod -l app.kubernetes.io/name=vault \
        -n $LOCAL_VAULT_NAMESPACE --timeout=120s
    
    # Set Vault connection info
    # For configuration, use port-forward (localhost)
    # For KMS plugin, use internal cluster address
    VAULT_INTERNAL_ADDR="http://$(oc get svc vault -n $LOCAL_VAULT_NAMESPACE -o jsonpath='{.spec.clusterIP}'):8200"
    VAULT_TOKEN="root"
    VAULT_NAMESPACE=""
    
    # Start port-forward for configuration
    echo "  Starting port-forward for configuration..."
    oc port-forward -n $LOCAL_VAULT_NAMESPACE svc/vault 8200:8200 >/dev/null 2>&1 &
    PF_PID=$!
    sleep 5
    
    # Use localhost for configuration
    VAULT_ADDR="http://127.0.0.1:8200"
    
    rm -f /tmp/vault-values.yaml
    
    echo -e "${GREEN}Vault installed successfully${NC}"
    echo "  Internal Address: $VAULT_INTERNAL_ADDR"
    echo "  Config Address: $VAULT_ADDR"
    echo "  Token: $VAULT_TOKEN"
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
        local ns_header=""
        [ -n "$VAULT_NAMESPACE" ] && ns_header="--header X-Vault-Namespace:$VAULT_NAMESPACE"
        
        VAULT_TOKEN=$(curl -sf --noproxy "*" $ns_header \
            --request POST \
            --data "{\"password\": \"$VAULT_PASSWORD\"}" \
            "$VAULT_ADDR/v1/auth/userpass/login/$VAULT_USERNAME" | jq -r '.auth.client_token')
        
        if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
            echo -e "${RED}Error: Failed to authenticate${NC}"
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
    
    # Build curl headers array
    # Add --noproxy to bypass any local proxy (Squid, etc.)
    local -a curl_headers=("--noproxy" "*" "--header" "X-Vault-Token: $VAULT_TOKEN")
    if [ -n "$VAULT_NAMESPACE" ]; then
        curl_headers+=("--header" "X-Vault-Namespace: $VAULT_NAMESPACE")
    fi
    
    # Wait for Vault to be ready (especially after port-forward)
    echo "  Waiting for Vault to be ready..."
    for i in {1..10}; do
        if curl -sf --noproxy "*" "${curl_headers[@]}" "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then
            echo "    Vault is ready"
            break
        fi
        echo "    Waiting... ($i/10)"
        sleep 2
    done
    
    # Enable Transit
    echo "  Enabling Transit secrets engine..."
    curl -sf "${curl_headers[@]}" \
        --request POST --data '{"type": "transit"}' \
        $VAULT_ADDR/v1/sys/mounts/transit 2>/dev/null || echo "    (already enabled)"
    
    # Create key
    echo "  Creating KMS key..."
    curl -sf "${curl_headers[@]}" \
        --request POST --data '{"type": "aes256-gcm96"}' \
        $VAULT_ADDR/v1/transit/keys/kms-key 2>/dev/null || echo "    (already exists)"
    
    # Enable AppRole
    echo "  Enabling AppRole auth..."
    curl -sf "${curl_headers[@]}" \
        --request POST --data '{"type": "approle"}' \
        $VAULT_ADDR/v1/sys/auth/approle 2>/dev/null || echo "    (already enabled)"
    
    # Create policy
    echo "  Creating KMS policy..."
    curl -s "${curl_headers[@]}" \
        --request PUT \
        --data '{
          "policy": "path \"transit/encrypt/kms-key\" { capabilities = [\"update\"] }\npath \"transit/decrypt/kms-key\" { capabilities = [\"update\"] }\npath \"transit/keys/kms-key\" { capabilities = [\"read\"] }\npath \"sys/license/status\" { capabilities = [\"read\"] }"
        }' \
        $VAULT_ADDR/v1/sys/policies/acl/kms-plugin-policy >/dev/null
    
    # Create AppRole
    echo "  Creating AppRole..."
    curl -s "${curl_headers[@]}" \
        --request POST \
        --data '{"policies": ["kms-plugin-policy"], "token_ttl": "1h", "token_max_ttl": "24h"}' \
        $VAULT_ADDR/v1/auth/approle/role/kms-plugin >/dev/null
    
    # Get credentials with error checking
    echo "  Getting AppRole credentials..."
    echo "    Fetching Role ID from: $VAULT_ADDR/v1/auth/approle/role/kms-plugin/role-id"
    local role_response
    role_response=$(curl -s "${curl_headers[@]}" \
        "$VAULT_ADDR/v1/auth/approle/role/kms-plugin/role-id" 2>&1)
    local curl_exit=$?
    echo "    Curl exit code: $curl_exit"
    echo "    Response (first 200 chars): ${role_response:0:200}"
    
    ROLE_ID=$(echo "$role_response" | jq -r '.data.role_id' 2>/dev/null)
    echo "    Parsed Role ID: $ROLE_ID"
    
    if [ -z "$ROLE_ID" ] || [ "$ROLE_ID" = "null" ]; then
        echo -e "${RED}Error: Failed to get Role ID${NC}"
        echo "Full response: $role_response"
        exit 1
    fi
    
    echo "    Fetching Secret ID..."
    local secret_response
    secret_response=$(curl -s "${curl_headers[@]}" \
        --request POST \
        "$VAULT_ADDR/v1/auth/approle/role/kms-plugin/secret-id" 2>&1)
    curl_exit=$?
    echo "    Curl exit code: $curl_exit"
    
    SECRET_ID=$(echo "$secret_response" | jq -r '.data.secret_id' 2>/dev/null)
    
    if [ -z "$SECRET_ID" ] || [ "$SECRET_ID" = "null" ]; then
        echo -e "${RED}Error: Failed to get Secret ID${NC}"
        echo "Full response: $secret_response"
        exit 1
    fi
    
    echo -e "${GREEN}Vault configured successfully${NC}"
    echo "  Role ID: $ROLE_ID"
    echo "  Secret ID: ${SECRET_ID:0:20}..."
}

#######################################
# Deploy KMS Plugin to OpenShift
#######################################
deploy_kms_plugin() {
    echo ""
    echo -e "${YELLOW}Deploying KMS plugin to OpenShift...${NC}"
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Create namespace
    echo "  Creating namespace..."
    oc apply -f $SCRIPT_DIR/namespace.yaml
    
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
    # For local mode, use internal address; for cloud, use VAULT_ADDR
    local secret_vault_addr="$VAULT_ADDR"
    if [ "$MODE" = "local" ]; then
        secret_vault_addr="$VAULT_INTERNAL_ADDR"
    fi
    oc create secret generic vault-kms-credentials \
        --namespace=$KMS_NAMESPACE \
        --from-literal=VAULT_ADDR="$secret_vault_addr" \
        --from-literal=VAULT_NAMESPACE="$VAULT_NAMESPACE" \
        --from-literal=VAULT_ROLE_ID="$ROLE_ID" \
        --from-literal=VAULT_SECRET_ID="$SECRET_ID" \
        --from-literal=VAULT_KEY_NAME="kms-key" \
        --dry-run=client -o yaml | oc apply -f -
    
    # Update daemonset for skip-tls if needed
    if [ "$SKIP_TLS_VERIFY" = "true" ] || [ "$MODE" = "local" ]; then
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
# Enable KMS Encryption
#######################################
enable_kms_encryption() {
    echo ""
    echo -e "${YELLOW}Enabling KMS encryption...${NC}"
    
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
    
    # Kill port-forward if running (local mode)
    if [ -n "$PF_PID" ]; then
        kill $PF_PID 2>/dev/null || true
    fi
    
    deploy_kms_plugin
    
    echo ""
    read -p "Enable KMS encryption now? [y/N]: " enable_now
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
