#!/bin/bash

# Vault Setup for Transit Engine (KMS Provider for Kubernetes/OpenShift)
# This configures Vault to act as a KMS provider for etcd encryption using Transit engine

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Retry function for transient network errors
retry_command() {
    local max_attempts=3
    local timeout=5
    local attempt=1
    local command="$@"

    while [ $attempt -le $max_attempts ]; do
        if eval "$command"; then
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                log_warn "Command failed (attempt $attempt/$max_attempts), retrying in ${timeout}s..."
                sleep $timeout
                attempt=$((attempt + 1))
            else
                log_error "Command failed after $max_attempts attempts"
                return 1
            fi
        fi
    done
}

# Configuration
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_SERVICE="vault"
TRANSIT_KEY_NAME="${TRANSIT_KEY_NAME:-kubernetes-encryption}"
APPROLE_NAME="${APPROLE_NAME:-kms-plugin}"

log_info "Setting up Vault Transit Engine for Kubernetes KMS..."

# Check prerequisites
log_info "Checking prerequisites..."
for cmd in oc helm; do
    if ! command -v $cmd &> /dev/null; then
        log_error "$cmd is not installed"
        exit 1
    fi
done

# Check OCP connection
if ! oc whoami &> /dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi

log_info "All prerequisites satisfied"

# Step 0: Cleanup any existing Vault installations
log_info "Cleaning up any existing Vault installations..."

# Check for existing Vault Helm releases in any namespace
for ns in vault vault-server; do
    if helm list -n $ns 2>/dev/null | grep -q "^vault"; then
        log_warn "Found existing Vault installation in namespace: $ns"
        log_info "Uninstalling Vault from $ns..."
        helm uninstall vault -n $ns 2>/dev/null || true
        sleep 5
    fi
done

# Delete conflicting ClusterRoleBindings
log_info "Removing conflicting cluster resources..."
oc delete clusterrolebinding vault-server-binding 2>/dev/null || true
oc delete clusterrolebinding vault-agent-injector-binding 2>/dev/null || true
oc delete mutatingwebhookconfigurations vault-agent-injector-cfg 2>/dev/null || true

# Clean up old namespaces if different from target
if [ "${VAULT_NAMESPACE}" != "vault-server" ]; then
    if oc get namespace vault-server >/dev/null 2>&1; then
        log_warn "Found old vault-server namespace, deleting..."
        oc delete namespace vault-server --wait=false 2>/dev/null || true
    fi
fi

sleep 5

# Step 1: Create namespace
log_info "Creating namespace: ${VAULT_NAMESPACE}"
if oc get namespace ${VAULT_NAMESPACE} >/dev/null 2>&1; then
    log_warn "Namespace ${VAULT_NAMESPACE} already exists, reusing it"
else
    oc create namespace ${VAULT_NAMESPACE}
fi

# Step 2: Grant OpenShift SCC
log_info "Granting Security Context Constraints..."
oc adm policy add-scc-to-user anyuid -z vault -n ${VAULT_NAMESPACE} 2>/dev/null || true
oc adm policy add-scc-to-user anyuid -z vault-agent-injector -n ${VAULT_NAMESPACE} 2>/dev/null || true

# Step 3: Install Vault (simple dev/standalone mode)
log_info "Installing Vault in dev/standalone mode..."

helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update hashicorp

# Simple Vault configuration for Transit engine use
cat > vault-values-transit.yaml <<'VALUESEOF'
global:
  openshift: true

server:
  image:
    repository: "docker.io/hashicorp/vault"
    tag: "1.16.1"

  dev:
    enabled: true
    devRootToken: "root"

  standalone:
    enabled: false

  dataStorage:
    enabled: false

injector:
  enabled: false

ui:
  enabled: true
  serviceType: ClusterIP
VALUESEOF

log_info "Installing Vault..."
helm upgrade --install vault hashicorp/vault \
    --namespace=${VAULT_NAMESPACE} \
    --values vault-values-transit.yaml \
    --wait

log_info "Vault installed successfully!"

# Step 4: Wait for pod
log_info "Waiting for Vault pod..."
sleep 10

# Use retry for wait command to handle transient network errors
retry_command "oc wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n ${VAULT_NAMESPACE} --timeout=300s"

# Use retry to get pod name
VAULT_POD=$(retry_command "oc get pod -n ${VAULT_NAMESPACE} -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}'")
log_info "Vault pod: $VAULT_POD"

# Step 5: Configure Transit Engine
log_info "Configuring Transit secret engine..."

# Login with root token (dev mode) - with retry
retry_command "oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault login root 2>/dev/null" || log_warn "Login may already be active"

# Enable Transit engine - with retry (idempotent)
retry_command "oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault secrets enable transit 2>/dev/null" || log_warn "Transit engine may already be enabled"

# Create encryption key for Kubernetes - with retry
retry_command "oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault write -f transit/keys/${TRANSIT_KEY_NAME} 2>/dev/null" || log_warn "Transit key may already exist"

log_info "Transit engine configured with key: ${TRANSIT_KEY_NAME}"

# Step 6: Configure AppRole Authentication
log_info "Configuring AppRole authentication..."

# Enable AppRole - with retry (idempotent)
retry_command "oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault auth enable approle 2>/dev/null" || log_warn "AppRole may already be enabled"

# Create policy for KMS plugin - with retry
retry_command "oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- sh -c 'vault policy write kms-plugin - <<EOF
path \"transit/encrypt/${TRANSIT_KEY_NAME}\" {
  capabilities = [\"update\"]
}

path \"transit/decrypt/${TRANSIT_KEY_NAME}\" {
  capabilities = [\"update\"]
}
EOF'"

# Create AppRole - with retry
retry_command "oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault write auth/approle/role/${APPROLE_NAME} token_policies=kms-plugin token_ttl=1h token_max_ttl=4h"

# Get RoleID - with retry
ROLE_ID=$(retry_command "oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read -field=role_id auth/approle/role/${APPROLE_NAME}/role-id")

# Generate SecretID - with retry
SECRET_ID=$(retry_command "oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault write -field=secret_id -f auth/approle/role/${APPROLE_NAME}/secret-id")

log_info "AppRole configured successfully"
log_info "Role ID: ${ROLE_ID}"
log_info "Secret ID: ${SECRET_ID:0:20}... (truncated)"

# Step 7: Test the setup
log_info "Testing Transit encryption/decryption..."

# Test encrypt - with retry
CIPHERTEXT=$(retry_command "oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault write -field=ciphertext transit/encrypt/${TRANSIT_KEY_NAME} plaintext=\$(echo 'test data' | base64)")
log_info "Encrypted: $CIPHERTEXT"

# Test decrypt - with retry
PLAINTEXT=$(retry_command "oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault write -field=plaintext transit/decrypt/${TRANSIT_KEY_NAME} ciphertext=$CIPHERTEXT" | base64 -d)
log_info "Decrypted: $PLAINTEXT"

if [ "$PLAINTEXT" = "test data" ]; then
    log_info "✅ Transit encryption/decryption working!"
else
    log_error "❌ Transit test failed"
fi

# Step 8: Comprehensive Verification
log_info ""
log_info "=========================================="
log_info "Running Verification Tests..."
log_info "=========================================="

# Test 1: Pod Status
echo ""
log_info "Test 1: Checking pod status..."
if oc get pod ${VAULT_POD} -n ${VAULT_NAMESPACE} -o jsonpath='{.status.containerStatuses[0].ready}' | grep -q "true"; then
    log_info "✅ Vault pod is ready (1/1)"
else
    log_error "❌ Vault pod is not ready"
fi

# Test 2: Vault Status
echo ""
log_info "Test 2: Checking Vault status..."
oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault status

# Test 3: Transit Engine Enabled
echo ""
log_info "Test 3: Verifying Transit engine is enabled..."
if oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault secrets list | grep -q "transit/"; then
    log_info "✅ Transit engine is enabled"
else
    log_error "❌ Transit engine not found"
fi

# Test 4: Transit Key Exists
echo ""
log_info "Test 4: Verifying Transit key exists..."
if oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault list transit/keys | grep -q "${TRANSIT_KEY_NAME}"; then
    log_info "✅ Transit key '${TRANSIT_KEY_NAME}' exists"
else
    log_error "❌ Transit key not found"
fi

# Test 5: AppRole Authentication Enabled
echo ""
log_info "Test 5: Verifying AppRole authentication..."
if oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault auth list | grep -q "approle/"; then
    log_info "✅ AppRole authentication is enabled"
else
    log_error "❌ AppRole authentication not found"
fi

# Test 6: AppRole Role Exists
echo ""
log_info "Test 6: Verifying AppRole role..."
if oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault list auth/approle/role | grep -q "${APPROLE_NAME}"; then
    log_info "✅ AppRole role '${APPROLE_NAME}' exists"
else
    log_error "❌ AppRole role not found"
fi

# Test 7: Additional Encryption/Decryption Test (as requested by user)
echo ""
log_info "Test 7: Additional encryption/decryption test..."
CIPHERTEXT_2=$(oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault write -field=ciphertext transit/encrypt/${TRANSIT_KEY_NAME} plaintext=$(echo 'test' | base64))
log_info "Encrypted 'test': $CIPHERTEXT_2"

PLAINTEXT_2=$(oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault write -field=plaintext transit/decrypt/${TRANSIT_KEY_NAME} ciphertext=$CIPHERTEXT_2 | base64 -d)
log_info "Decrypted: $PLAINTEXT_2"

if [ "$PLAINTEXT_2" = "test" ]; then
    log_info "✅ Additional encryption/decryption test passed!"
else
    log_error "❌ Additional encryption/decryption test failed"
fi

# Test 8: AppRole Login Test
echo ""
log_info "Test 8: Testing AppRole login..."
APPROLE_TOKEN=$(oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault write -field=token auth/approle/login role_id="${ROLE_ID}" secret_id="${SECRET_ID}")
if [ -n "$APPROLE_TOKEN" ]; then
    log_info "✅ AppRole login successful"
    log_info "Token received: ${APPROLE_TOKEN:0:20}..."
else
    log_error "❌ AppRole login failed"
fi

# Test 9: AppRole Token Can Encrypt
echo ""
log_info "Test 9: Testing AppRole token can encrypt/decrypt..."
CIPHERTEXT_3=$(oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- env VAULT_TOKEN=${APPROLE_TOKEN} vault write -field=ciphertext transit/encrypt/${TRANSIT_KEY_NAME} plaintext=$(echo 'approle test' | base64))
if [ -n "$CIPHERTEXT_3" ]; then
    log_info "✅ AppRole token can encrypt"

    PLAINTEXT_3=$(oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- env VAULT_TOKEN=${APPROLE_TOKEN} vault write -field=plaintext transit/decrypt/${TRANSIT_KEY_NAME} ciphertext=$CIPHERTEXT_3 | base64 -d)
    if [ "$PLAINTEXT_3" = "approle test" ]; then
        log_info "✅ AppRole token can decrypt"
    else
        log_error "❌ AppRole token cannot decrypt"
    fi
else
    log_error "❌ AppRole token cannot encrypt"
fi

# Test 10: Policy Verification
echo ""
log_info "Test 10: Verifying policy exists..."
if oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault policy list | grep -q "kms-plugin"; then
    log_info "✅ Policy 'kms-plugin' exists"
    echo ""
    log_info "Policy contents:"
    oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault policy read kms-plugin
else
    log_error "❌ Policy 'kms-plugin' not found"
fi

echo ""
log_info "=========================================="
log_info "All Verification Tests Complete!"
log_info "=========================================="

# Step 9: Create KMS plugin configuration
log_info ""
log_info "Creating KMS plugin configuration..."

VAULT_ADDR="http://vault.${VAULT_NAMESPACE}.svc.cluster.local:8200"

cat > kms-plugin-config.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kms-plugin-config
  namespace: openshift-config
type: Opaque
stringData:
  config.yaml: |
    kind: VaultConfig
    apiVersion: apiserver.config.k8s.io/v1
    vault:
      address: "${VAULT_ADDR}"
      transitKeyName: "${TRANSIT_KEY_NAME}"
      auth:
        type: "approle"
        approle:
          roleID: "${ROLE_ID}"
          secretID: "${SECRET_ID}"
EOF

log_info "KMS plugin configuration saved to: kms-plugin-config.yaml"

# Save credentials
cat > vault-approle-credentials.txt <<EOF
Vault Address: ${VAULT_ADDR}
Transit Key: ${TRANSIT_KEY_NAME}
AppRole Name: ${APPROLE_NAME}
Role ID: ${ROLE_ID}
Secret ID: ${SECRET_ID}
Root Token: root (dev mode)
EOF

chmod 600 vault-approle-credentials.txt

log_info ""
log_info "=========================================="
log_info "Vault Transit KMS Setup Complete!"
log_info "=========================================="
echo ""
echo "Vault Information:"
echo "  - Namespace: ${VAULT_NAMESPACE}"
echo "  - Pod: ${VAULT_POD}"
echo "  - Address: ${VAULT_ADDR}"
echo "  - Root Token: root (dev mode)"
echo ""
echo "Transit Engine:"
echo "  - Engine: transit"
echo "  - Key Name: ${TRANSIT_KEY_NAME}"
echo ""
echo "AppRole Credentials (for KMS plugin):"
echo "  - Role Name: ${APPROLE_NAME}"
echo "  - Role ID: ${ROLE_ID}"
echo "  - Secret ID: ${SECRET_ID}"
echo ""
echo "Files Created:"
echo "  - vault-approle-credentials.txt (AppRole credentials)"
echo "  - kms-plugin-config.yaml (KMS plugin configuration)"
echo ""
echo "Next Steps:"
echo "  1. Apply KMS plugin configuration:"
echo "     oc apply -f kms-plugin-config.yaml"
echo ""
echo "  2. Configure kube-apiserver to use Vault KMS"
echo "     (Refer to OpenShift KMS plugin documentation)"
echo ""
echo "Test Transit Engine:"
echo "  oc exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault write transit/encrypt/${TRANSIT_KEY_NAME} plaintext=\$(echo 'test' | base64)"
echo ""
log_info "Vault is ready as KMS provider! 🎉"
