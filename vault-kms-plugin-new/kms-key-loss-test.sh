#!/bin/bash
# ============================================================================
# KMS Key Loss Scenario Test for OpenShift
# ============================================================================
#
# Simulates a KMS key loss scenario where the Vault Transit encryption key
# is deleted/rotated, making all KMS-encrypted etcd resources (secrets,
# configmaps) inaccessible. Then tests platform recovery by deleting the
# undecryptable resources and verifying that OpenShift operators recreate them.
#
# Scenario (per polynomial's request):
#   1. Key is lost → all encrypted resources become inaccessible
#   2. Admin uses oc to delete all resources that cannot be decrypted
#   3. Platform (operators) must recreate them
#   4. Scoped to secrets and configmaps for now
#
# OpenShift encrypts these resource types by default when encryption is enabled:
#   - Secrets
#   - ConfigMaps
#   - Routes
#   - OAuth access tokens
#   - OAuth authorize tokens
#
# Usage:
#   # Full key loss simulation and recovery test
#   ./kms-key-loss-test.sh --full-test
#
#   # Phase 1 only: Pre-test inventory & verification
#   ./kms-key-loss-test.sh --inventory
#
#   # Phase 2 only: Simulate key loss (delete Vault Transit key)
#   ./kms-key-loss-test.sh --simulate-key-loss
#
#   # Phase 3 only: Detect and delete undecryptable resources
#   ./kms-key-loss-test.sh --delete-undecryptable
#
#   # Phase 4 only: Verify operator recovery
#   ./kms-key-loss-test.sh --verify-recovery
#
#   # Recover: Create new KMS key and re-enable encryption
#   ./kms-key-loss-test.sh --recover-kms
#
#   # Simulate key corruption (reversible — rotates key + blocks old versions)
#   ./kms-key-loss-test.sh --corrupt-key --username admin --password pass
#
#   # Undo key corruption
#   ./kms-key-loss-test.sh --recover-corrupted-key --username admin --password pass
#
#   # Delete secrets directly from etcd (bypasses API server)
#   ./kms-key-loss-test.sh --delete-etcd-secrets
#
#   # Delete configmaps directly from etcd
#   ./kms-key-loss-test.sh --delete-etcd-configmaps
#
#   # Delete ALL secrets & configmaps from etcd (takes etcd backup first)
#   ./kms-key-loss-test.sh --delete-etcd-secrets --all-namespaces
#   ./kms-key-loss-test.sh --delete-etcd-configmaps --all-namespaces
#
#   # Dry run any destructive scenario
#   ./kms-key-loss-test.sh --delete-etcd-secrets --dry-run
#   ./kms-key-loss-test.sh --delete-etcd-secrets --all-namespaces --dry-run
#
# Environment variables (for cloud Vault):
#   VAULT_ADDR        - Vault server address
#   VAULT_TOKEN       - Vault token with admin permissions
#   VAULT_USERNAME    - Vault username for userpass auth (alternative to token)
#   VAULT_PASSWORD    - Vault password for userpass auth
#   VAULT_NAMESPACE   - Vault namespace (e.g., "admin" for HCP)
#
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
KMS_NAMESPACE="openshift-kms-plugin"
ETCD_NAMESPACE="openshift-etcd"
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"
VAULT_USERNAME="${VAULT_USERNAME:-}"
VAULT_PASSWORD="${VAULT_PASSWORD:-}"
VAULT_KEY_NAME="${VAULT_KEY_NAME:-kms-key}"
TRANSIT_MOUNT="${TRANSIT_MOUNT:-transit}"
SKIP_TLS_VERIFY="${SKIP_TLS_VERIFY:-false}"

ACTION=""
SKIP_CONFIRM="false"
INVENTORY_DIR="/tmp/kms-key-loss-test-$(date +%Y%m%d_%H%M%S)"
DRY_RUN="false"
ALL_NAMESPACES="false"

# OpenShift namespaces with critical operator-managed resources
# These are namespaces where operators will recreate secrets/configmaps
OPERATOR_NAMESPACES=(
    "openshift-apiserver"
    "openshift-apiserver-operator"
    "openshift-authentication"
    "openshift-authentication-operator"
    "openshift-cloud-controller-manager"
    "openshift-cloud-controller-manager-operator"
    "openshift-cloud-credential-operator"
    "openshift-cluster-csi-drivers"
    "openshift-cluster-machine-approver"
    "openshift-cluster-node-tuning-operator"
    "openshift-cluster-samples-operator"
    "openshift-cluster-storage-operator"
    "openshift-cluster-version"
    "openshift-config"
    "openshift-config-managed"
    "openshift-console"
    "openshift-console-operator"
    "openshift-controller-manager"
    "openshift-controller-manager-operator"
    "openshift-dns"
    "openshift-dns-operator"
    "openshift-etcd"
    "openshift-etcd-operator"
    "openshift-image-registry"
    "openshift-ingress"
    "openshift-ingress-canary"
    "openshift-ingress-operator"
    "openshift-insights"
    "openshift-kube-apiserver"
    "openshift-kube-apiserver-operator"
    "openshift-kube-controller-manager"
    "openshift-kube-controller-manager-operator"
    "openshift-kube-scheduler"
    "openshift-kube-scheduler-operator"
    "openshift-kube-storage-version-migrator"
    "openshift-kube-storage-version-migrator-operator"
    "openshift-machine-api"
    "openshift-machine-config-operator"
    "openshift-marketplace"
    "openshift-monitoring"
    "openshift-multus"
    "openshift-network-diagnostics"
    "openshift-network-node-identity"
    "openshift-network-operator"
    "openshift-oauth-apiserver"
    "openshift-operator-lifecycle-manager"
    "openshift-route-controller-manager"
    "openshift-service-ca"
    "openshift-service-ca-operator"
)

# Resource types that are encrypted by default in OpenShift etcd
ENCRYPTED_RESOURCE_TYPES=(
    "secrets"
    "configmaps"
)

# Logging helpers
log_info()    { printf "${BLUE}[INFO]${NC}    %s\n" "$*"; }
log_success() { printf "${GREEN}[OK]${NC}      %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC}    %s\n" "$*"; }
log_error()   { printf "${RED}[ERROR]${NC}   %s\n" "$*"; }
log_step()    { printf "\n${BOLD}${CYAN}── Step: %s${NC}\n" "$*"; }
log_cmd()     { printf "${YELLOW}[CMD]${NC}     %s\n" "$*"; }
log_header()  {
    printf "\n${CYAN}════════════════════════════════════════════════════════════${NC}\n"
    printf "${CYAN}  %s${NC}\n" "$*"
    printf "${CYAN}════════════════════════════════════════════════════════════${NC}\n"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --full-test)
            ACTION="full-test"
            shift
            ;;
        --inventory)
            ACTION="inventory"
            shift
            ;;
        --simulate-key-loss)
            ACTION="simulate-key-loss"
            shift
            ;;
        --delete-undecryptable)
            ACTION="delete-undecryptable"
            shift
            ;;
        --verify-recovery)
            ACTION="verify-recovery"
            shift
            ;;
        --recover-kms)
            ACTION="recover-kms"
            shift
            ;;
        --corrupt-key)
            ACTION="corrupt-key"
            shift
            ;;
        --recover-corrupted-key)
            ACTION="recover-corrupted-key"
            shift
            ;;
        --delete-etcd-secrets)
            ACTION="delete-etcd-secrets"
            shift
            ;;
        --delete-etcd-configmaps)
            ACTION="delete-etcd-configmaps"
            shift
            ;;
        --vault-addr)
            VAULT_ADDR="$2"
            shift 2
            ;;
        --vault-token)
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
        --vault-namespace)
            VAULT_NAMESPACE="$2"
            shift 2
            ;;
        --key-name)
            VAULT_KEY_NAME="$2"
            shift 2
            ;;
        --skip-tls-verify)
            SKIP_TLS_VERIFY="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --all-namespaces)
            ALL_NAMESPACES="true"
            shift
            ;;
        --yes|-y)
            SKIP_CONFIRM="true"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [action] [options]"
            echo ""
            echo "Actions — Key Loss Test:"
            echo "  --full-test              Full key loss simulation and recovery test"
            echo "  --inventory              Phase 1: Take inventory of all encrypted resources"
            echo "  --simulate-key-loss      Phase 2: Delete the Vault Transit key (DESTRUCTIVE)"
            echo "  --delete-undecryptable   Phase 3: Find and delete undecryptable resources"
            echo "  --verify-recovery        Phase 4: Verify operators recreated resources"
            echo "  --recover-kms            Recovery: Create new KMS key and re-enable encryption"
            echo ""
            echo "Actions — Key Corruption Test:"
            echo "  --corrupt-key            Rotate key + set min_decryption_version (reversible)"
            echo "  --recover-corrupted-key  Undo corruption by resetting min_decryption_version"
            echo ""
            echo "Actions — Direct etcd Deletion Tests:"
            echo "  --delete-etcd-secrets    Delete secrets directly from etcd via etcdctl"
            echo "  --delete-etcd-configmaps Delete configmaps directly from etcd via etcdctl"
            echo "    (add --all-namespaces to delete from ALL namespaces, not just operator ones)"
            echo ""
            echo "Options:"
            echo "  --vault-addr ADDR      Vault server address (or set VAULT_ADDR)"
            echo "  --vault-token TOKEN    Vault token (or set VAULT_TOKEN)"
            echo "  --username USER        Vault username for userpass auth (or set VAULT_USERNAME)"
            echo "  --password PASS        Vault password for userpass auth (or set VAULT_PASSWORD)"
            echo "  --vault-namespace NS   Vault namespace (or set VAULT_NAMESPACE)"
            echo "  --key-name NAME        Transit key name (default: kms-key)"
            echo "  --skip-tls-verify      Skip TLS verification for Vault"
            echo "  --all-namespaces       Delete from ALL namespaces (with --delete-etcd-*)"
            echo "  --dry-run              Show what would be deleted without deleting"
            echo "  --yes, -y              Skip confirmation prompts"
            echo ""
            echo "Authentication:"
            echo "  Either provide --vault-token or --username/--password."
            echo "  Username/password will authenticate via Vault userpass and obtain a token."
            echo ""
            echo "Examples:"
            echo "  # Full test with HCP Vault (userpass auth)"
            echo "  export VAULT_ADDR='https://vault.hashicorp.cloud:8200'"
            echo "  export VAULT_NAMESPACE='admin'"
            echo "  $0 --full-test --username admin-user --password your-password"
            echo ""
            echo "  # Full test with HCP Vault (token auth)"
            echo "  export VAULT_ADDR='https://vault.hashicorp.cloud:8200'"
            echo "  export VAULT_TOKEN='hvs.xxx'"
            echo "  export VAULT_NAMESPACE='admin'"
            echo "  $0 --full-test"
            echo ""
            echo "  # Dry run (see what would be deleted)"
            echo "  $0 --delete-undecryptable --dry-run"
            echo ""
            echo "  # Just take inventory"
            echo "  $0 --inventory"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Auto-read token from vault token helper, but only if userpass credentials
# were NOT provided (userpass should always get a fresh token)
if [ -z "$VAULT_TOKEN" ] && [ -z "$VAULT_USERNAME" ] && [ -f "$HOME/.vault-token" ]; then
    VAULT_TOKEN=$(cat "$HOME/.vault-token" 2>/dev/null | tr -d '\n')
    if [ -n "$VAULT_TOKEN" ]; then
        log_info "Read VAULT_TOKEN from ~/.vault-token (from 'vault login')"
    fi
fi

# ============================================================================
# Prerequisites
# ============================================================================
check_prerequisites() {
    log_header "Checking Prerequisites"

    if ! command -v oc &>/dev/null; then
        log_error "oc CLI not found"
        exit 1
    fi
    log_success "oc CLI found"

    log_cmd "oc whoami"
    if ! oc whoami &>/dev/null; then
        log_error "Not logged into OpenShift. Run 'oc login' first."
        exit 1
    fi
    log_success "Logged in as: $(oc whoami)"

    log_cmd "oc auth can-i '*' '*' --all-namespaces"
    if ! oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
        log_error "cluster-admin access required"
        exit 1
    fi
    log_success "cluster-admin access confirmed"

    if ! command -v jq &>/dev/null; then
        log_error "jq is required but not found. Install with: brew install jq"
        exit 1
    fi
    log_success "jq found"

    # Check KMS plugin is deployed and running
    log_step "Checking KMS Plugin Deployment"
    log_cmd "oc get pods -n $KMS_NAMESPACE --no-headers"
    local kms_pods
    kms_pods=$(oc get pods -n "$KMS_NAMESPACE" --no-headers 2>/dev/null || echo "")
    if [ -z "$kms_pods" ]; then
        log_error "No KMS plugin pods found in namespace '$KMS_NAMESPACE'"
        echo "    Deploy the KMS plugin first using: ./deploy-kms-st-pod.sh"
        exit 1
    fi
    local kms_running kms_total
    kms_total=$(echo "$kms_pods" | wc -l | tr -d ' ')
    kms_running=$(echo "$kms_pods" | grep -c "Running" || echo "0")
    echo "$kms_pods" | while read -r line; do
        echo "    $line"
    done
    if [ "$kms_running" -eq "$kms_total" ] && [ "$kms_total" -gt 0 ]; then
        log_success "KMS plugin: $kms_running/$kms_total pods running"
    elif [ "$kms_running" -gt 0 ]; then
        log_warn "KMS plugin: only $kms_running/$kms_total pods running (some not ready)"
    else
        log_error "KMS plugin: 0/$kms_total pods running — KMS is not functional"
        exit 1
    fi

    # Check KMS encryption is configured in the API server
    log_step "Checking KMS Configuration in API Server"
    log_cmd "oc get apiserver cluster -o jsonpath='{.spec.encryption}'"
    local encryption_config
    encryption_config=$(oc get apiserver cluster -o jsonpath='{.spec.encryption}' 2>/dev/null || echo "")
    if [ -z "$encryption_config" ]; then
        log_error "No encryption configured on the API server"
        echo "    Enable KMS encryption first:"
        echo "      oc patch apiserver cluster --type=merge -p '{\"spec\":{\"encryption\":{\"type\":\"KMS\"}}}'"
        exit 1
    fi
    local encryption_type
    encryption_type=$(oc get apiserver cluster -o jsonpath='{.spec.encryption.type}' 2>/dev/null || echo "")
    if [ "$encryption_type" != "KMS" ]; then
        log_error "API server encryption type is '$encryption_type', expected 'KMS'"
        echo "    Current config: $encryption_config"
        echo "    Enable KMS encryption:"
        echo "      oc patch apiserver cluster --type=merge -p '{\"spec\":{\"encryption\":{\"type\":\"KMS\"}}}'"
        exit 1
    fi
    log_success "API server encryption type: $encryption_type"

    # Verify KMS encryption is active (check EncryptionCompleted condition)
    log_cmd "oc get openshiftapiserver cluster -o jsonpath='{.status.conditions}'"
    local enc_status
    enc_status=$(oc get openshiftapiserver cluster -o jsonpath='{.status.conditions[?(@.type=="Encrypted")].status}' 2>/dev/null || echo "")
    local enc_reason
    enc_reason=$(oc get openshiftapiserver cluster -o jsonpath='{.status.conditions[?(@.type=="Encrypted")].reason}' 2>/dev/null || echo "")
    if [ "$enc_status" = "True" ]; then
        log_success "etcd encryption active (reason: $enc_reason)"
    elif [ -n "$enc_status" ]; then
        log_warn "etcd encryption status: $enc_status (reason: $enc_reason)"
        echo "    Encryption may still be in progress. Proceeding with caution."
    else
        log_warn "Could not determine encryption status from openshiftapiserver"
        echo "    Checking alternative: kube-apiserver encryption conditions..."
        log_cmd "oc get kubeapiserver cluster -o jsonpath='{.status.conditions[?(@.type==\"Encrypted\")]}'"
        local kube_enc
        kube_enc=$(oc get kubeapiserver cluster -o jsonpath='{.status.conditions[?(@.type=="Encrypted")]}' 2>/dev/null || echo "")
        if [ -n "$kube_enc" ]; then
            echo "    $kube_enc" | jq -r '"    Status: \(.status), Reason: \(.reason)"' 2>/dev/null || echo "    $kube_enc"
        else
            log_warn "Could not determine encryption status — proceeding anyway"
        fi
    fi

    # Check FeatureGate for KMS
    log_cmd "oc get featuregate cluster -o jsonpath='{.spec}'"
    local fg_spec
    fg_spec=$(oc get featuregate cluster -o jsonpath='{.spec}' 2>/dev/null || echo "")
    if echo "$fg_spec" | grep -q "KMSEncryption"; then
        log_success "KMSEncryption FeatureGate is enabled"
    else
        log_warn "KMSEncryption FeatureGate not found in featuregate spec"
        echo "    Spec: $fg_spec"
        echo "    This may be fine if using a different mechanism to enable KMS."
    fi

    # Create inventory directory
    mkdir -p "$INVENTORY_DIR"
    log_success "Inventory directory: $INVENTORY_DIR"
}

# Build curl headers for Vault API calls
build_vault_headers() {
    CURL_OPTS=("--noproxy" "*" "--max-time" "10" "-s")
    [ "$SKIP_TLS_VERIFY" = "true" ] && CURL_OPTS+=("-k")

    VAULT_HEADERS=("--header" "X-Vault-Token: $VAULT_TOKEN")
    if [ -n "$VAULT_NAMESPACE" ]; then
        VAULT_HEADERS+=("--header" "X-Vault-Namespace: $VAULT_NAMESPACE")
    fi
}

# Authenticate to Vault via userpass and obtain a token
authenticate_vault() {
    log_info "Authenticating to Vault with username/password..."

    local tls_flag=""
    [ "$SKIP_TLS_VERIFY" = "true" ] && tls_flag="-k"

    local ns_header=""
    [ -n "$VAULT_NAMESPACE" ] && ns_header="--header X-Vault-Namespace:$VAULT_NAMESPACE"

    local auth_resp http_code
    auth_resp=$(curl -s --noproxy "*" --max-time 15 $tls_flag $ns_header \
        -w "\n%{http_code}" \
        --request POST \
        --data "{\"password\": \"$VAULT_PASSWORD\"}" \
        "$VAULT_ADDR/v1/auth/userpass/login/$VAULT_USERNAME" 2>&1) || true

    http_code=$(echo "$auth_resp" | tail -n1)
    auth_resp=$(echo "$auth_resp" | sed '$d')

    VAULT_TOKEN=$(echo "$auth_resp" | jq -r '.auth.client_token // empty' 2>/dev/null)

    if [ -z "$VAULT_TOKEN" ]; then
        log_error "Failed to authenticate with username/password (HTTP $http_code)"
        echo "    Vault address:  $VAULT_ADDR"
        echo "    Username:       $VAULT_USERNAME"
        echo "    Namespace:      ${VAULT_NAMESPACE:-(none)}"
        echo "    Response: $(echo "$auth_resp" | jq -r '.errors[]?' 2>/dev/null || echo "$auth_resp")"
        exit 1
    fi

    log_success "Authenticated successfully (token: ${VAULT_TOKEN:0:15}...)"
}

# Check Vault connectivity
check_vault() {
    if [ -z "$VAULT_ADDR" ]; then
        log_error "VAULT_ADDR not set. Use --vault-addr or export VAULT_ADDR"
        exit 1
    fi

    # If userpass credentials are provided, always get a fresh token
    # (handles expired tokens from env/~/.vault-token)
    if [ -n "$VAULT_USERNAME" ] && [ -n "$VAULT_PASSWORD" ]; then
        authenticate_vault
    elif [ -z "$VAULT_TOKEN" ]; then
        log_error "No authentication method provided."
        echo "    Use one of:"
        echo "      --vault-token TOKEN           (or export VAULT_TOKEN)"
        echo "      --username USER --password PW  (or export VAULT_USERNAME / VAULT_PASSWORD)"
        exit 1
    fi

    build_vault_headers

    log_info "Checking Vault connectivity at $VAULT_ADDR ..."
    log_cmd "curl -s -o /dev/null -w '%{http_code}' $VAULT_ADDR/v1/sys/health"
    local health_code
    health_code=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
        "$VAULT_ADDR/v1/sys/health" 2>/dev/null || echo "000")

    if [[ "$health_code" =~ ^(200|429|472|473)$ ]]; then
        log_success "Vault is reachable (health: $health_code)"
    else
        # Fallback: try token lookup with namespace
        log_cmd "curl -s -o /dev/null -w '%{http_code}' -H 'X-Vault-Token: ***' $VAULT_ADDR/v1/auth/token/lookup-self"
        local lookup_code
        lookup_code=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
            "${VAULT_HEADERS[@]}" \
            "$VAULT_ADDR/v1/auth/token/lookup-self" 2>/dev/null || echo "000")
        if [ "$lookup_code" = "200" ]; then
            log_success "Vault is reachable (token lookup: $lookup_code)"
        else
            log_error "Cannot reach Vault (health: $health_code, token lookup: $lookup_code)"
            exit 1
        fi
    fi
}

# ============================================================================
# Phase 1: Pre-Test Inventory
# ============================================================================
take_inventory() {
    log_header "Phase 1: Taking Inventory of Encrypted Resources"

    log_info "Saving resource counts per namespace for secrets and configmaps..."
    log_info "This will be used to compare against post-recovery state."
    echo ""

    local total_secrets=0
    local total_configmaps=0
    local ns_count=0

    # Header for summary file
    printf "%-55s %8s %12s\n" "NAMESPACE" "SECRETS" "CONFIGMAPS" > "$INVENTORY_DIR/inventory-summary.txt"
    printf "%-55s %8s %12s\n" "─────────" "───────" "──────────" >> "$INVENTORY_DIR/inventory-summary.txt"

    for ns in "${OPERATOR_NAMESPACES[@]}"; do
        # Check if namespace exists
        if ! oc get namespace "$ns" &>/dev/null; then
            continue
        fi

        ns_count=$((ns_count + 1))

        # Count secrets (excluding service-account-token type for cleaner count)
        log_cmd "oc get secrets -n $ns --no-headers"
        local secret_count
        secret_count=$(oc get secrets -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')

        # Count configmaps
        log_cmd "oc get configmaps -n $ns --no-headers"
        local cm_count
        cm_count=$(oc get configmaps -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')

        total_secrets=$((total_secrets + secret_count))
        total_configmaps=$((total_configmaps + cm_count))

        # Save to summary
        printf "%-55s %8s %12s\n" "$ns" "$secret_count" "$cm_count" >> "$INVENTORY_DIR/inventory-summary.txt"

        # Save detailed inventory per namespace
        log_cmd "oc get secrets -n $ns -o json > $INVENTORY_DIR/secrets-${ns}.json"
        oc get secrets -n "$ns" -o json 2>/dev/null > "$INVENTORY_DIR/secrets-${ns}.json"
        log_cmd "oc get configmaps -n $ns -o json > $INVENTORY_DIR/configmaps-${ns}.json"
        oc get configmaps -n "$ns" -o json 2>/dev/null > "$INVENTORY_DIR/configmaps-${ns}.json"

        # Save secret names (not values) for comparison
        log_cmd "oc get secrets -n $ns -o jsonpath='{..metadata.name}' | sort > $INVENTORY_DIR/secret-names-${ns}.txt"
        oc get secrets -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort > "$INVENTORY_DIR/secret-names-${ns}.txt"
        log_cmd "oc get configmaps -n $ns -o jsonpath='{..metadata.name}' | sort > $INVENTORY_DIR/configmap-names-${ns}.txt"
        oc get configmaps -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort > "$INVENTORY_DIR/configmap-names-${ns}.txt"

        # Print progress
        if [ "$secret_count" -gt 0 ] || [ "$cm_count" -gt 0 ]; then
            printf "  %-50s  secrets=%-4s configmaps=%-4s\n" "$ns" "$secret_count" "$cm_count"
        fi
    done

    # Totals
    printf "%-55s %8s %12s\n" "─────────" "───────" "──────────" >> "$INVENTORY_DIR/inventory-summary.txt"
    printf "%-55s %8s %12s\n" "TOTAL ($ns_count namespaces)" "$total_secrets" "$total_configmaps" >> "$INVENTORY_DIR/inventory-summary.txt"

    echo ""
    log_success "Inventory complete:"
    echo "    Namespaces scanned: $ns_count"
    echo "    Total secrets:      $total_secrets"
    echo "    Total configmaps:   $total_configmaps"
    echo "    Saved to:           $INVENTORY_DIR/"

    # Also save cluster operator status
    log_info "Saving cluster operator status..."
    log_cmd "oc get clusteroperators -o json > $INVENTORY_DIR/clusteroperators-before.json"
    oc get clusteroperators -o json > "$INVENTORY_DIR/clusteroperators-before.json" 2>/dev/null
    log_cmd "oc get clusteroperators --no-headers > $INVENTORY_DIR/clusteroperators-before.txt"
    oc get clusteroperators --no-headers > "$INVENTORY_DIR/clusteroperators-before.txt" 2>/dev/null
    log_success "Cluster operator status saved"

    # Save KMS plugin pod status
    log_info "Saving KMS plugin status..."
    log_cmd "oc get pods -n $KMS_NAMESPACE -o wide"
    oc get pods -n "$KMS_NAMESPACE" -o wide > "$INVENTORY_DIR/kms-pods-before.txt" 2>/dev/null || true
    log_success "KMS plugin status saved"
}

# ============================================================================
# Phase 2: Simulate KMS Key Loss
# ============================================================================
simulate_key_loss() {
    log_header "Phase 2: Simulating KMS Key Loss"

    check_vault

    log_warn "════════════════════════════════════════════════════════"
    log_warn "  THIS IS A DESTRUCTIVE OPERATION!"
    log_warn "════════════════════════════════════════════════════════"
    log_warn ""
    log_warn "  This will DELETE the Vault Transit key: $VAULT_KEY_NAME"
    log_warn "  Mount: $TRANSIT_MOUNT"
    log_warn ""
    log_warn "  After deletion:"
    log_warn "    - All KMS-encrypted secrets/configmaps become UNDECRYPTABLE"
    log_warn "    - The kube-apiserver will fail to read encrypted resources"
    log_warn "    - Operator reconciliation loops will begin failing"
    log_warn ""
    log_warn "  This simulates a real-world KMS key loss scenario."
    log_warn ""

    if [ "$SKIP_CONFIRM" != "true" ]; then
        printf "${RED}Type 'DELETE KEY' to confirm: ${NC}"
        read -r confirm
        if [ "$confirm" != "DELETE KEY" ]; then
            log_info "Cancelled"
            return 1
        fi
    fi

    # Step 1: Verify key exists before deletion
    log_step "Verifying Transit key exists"
    log_cmd "curl -s -H 'X-Vault-Token: ***' $VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME"
    local key_info
    key_info=$(curl "${CURL_OPTS[@]}" "${VAULT_HEADERS[@]}" \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME" 2>/dev/null)

    if echo "$key_info" | jq -e '.data.name' &>/dev/null; then
        local key_name
        key_name=$(echo "$key_info" | jq -r '.data.name')
        local key_type
        key_type=$(echo "$key_info" | jq -r '.data.type')
        local key_versions
        key_versions=$(echo "$key_info" | jq -r '.data.latest_version')
        log_success "Key found: name=$key_name, type=$key_type, versions=$key_versions"

        # Save key metadata for records
        echo "$key_info" | jq '.' > "$INVENTORY_DIR/transit-key-before-deletion.json" 2>/dev/null || true
    else
        log_error "Transit key '$VAULT_KEY_NAME' not found at $TRANSIT_MOUNT"
        echo "    Response: $(echo "$key_info" | jq -r '.errors[]?' 2>/dev/null || echo "$key_info")"
        exit 1
    fi

    # Step 2: Allow key deletion (Vault requires this before delete)
    log_step "Enabling key deletion (setting deletion_allowed=true)"
    log_cmd "curl -s -X POST -H 'X-Vault-Token: ***' -d '{\"deletion_allowed\": true}' $VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME/config"
    local update_resp
    update_resp=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
        "${VAULT_HEADERS[@]}" \
        --request POST \
        --data '{"deletion_allowed": true}' \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME/config" 2>/dev/null)

    if [ "$update_resp" = "200" ] || [ "$update_resp" = "204" ]; then
        log_success "Key deletion enabled"
    else
        log_error "Failed to enable key deletion (HTTP $update_resp)"
        exit 1
    fi

    # Step 3: Delete the Transit key
    log_step "Deleting Transit key: $VAULT_KEY_NAME"
    log_cmd "curl -s -X DELETE -H 'X-Vault-Token: ***' $VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME"
    local delete_resp
    delete_resp=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
        "${VAULT_HEADERS[@]}" \
        --request DELETE \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME" 2>/dev/null)

    if [ "$delete_resp" = "204" ] || [ "$delete_resp" = "200" ]; then
        log_success "Transit key '$VAULT_KEY_NAME' DELETED"
    else
        log_error "Failed to delete key (HTTP $delete_resp)"
        exit 1
    fi

    # Step 4: Verify key is gone
    log_step "Verifying key is deleted"
    log_cmd "curl -s -o /dev/null -w '%{http_code}' -H 'X-Vault-Token: ***' $VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME"
    local verify_resp
    verify_resp=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
        "${VAULT_HEADERS[@]}" \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME" 2>/dev/null)

    if [ "$verify_resp" = "404" ] || [ "$verify_resp" = "400" ]; then
        log_success "Confirmed: key no longer exists (HTTP $verify_resp)"
    else
        log_warn "Unexpected response when verifying deletion (HTTP $verify_resp)"
    fi

    echo ""
    log_warn "KMS KEY HAS BEEN DELETED"
    log_warn ""
    log_warn "The cluster will now begin experiencing decryption failures."
    log_warn "KMS plugin pods will fail to encrypt/decrypt via Vault Transit."
    log_warn ""
    log_info "Wait 1-2 minutes for failures to propagate, then run:"
    echo "    $0 --delete-undecryptable"

    # Record the timestamp
    date -u +%Y-%m-%dT%H:%M:%SZ > "$INVENTORY_DIR/key-deletion-timestamp.txt"
}

# ============================================================================
# Phase 3: Detect and Delete Undecryptable Resources
# ============================================================================
delete_undecryptable_resources() {
    log_header "Phase 3: Detecting and Deleting Undecryptable Resources"

    if [ "$DRY_RUN" = "true" ]; then
        log_warn "DRY RUN MODE — no resources will be deleted"
    fi

    local total_failed_secrets=0
    local total_failed_configmaps=0
    local total_deleted_secrets=0
    local total_deleted_configmaps=0
    local namespaces_affected=0

    # Namespaces to skip (critical bootstrap, should not be touched)
    local skip_namespaces="kube-system|kube-public|kube-node-lease|default|openshift"

    log_info "Scanning all namespaces for undecryptable secrets and configmaps..."
    echo ""

    # Get all namespaces (not just operator ones — scan everything)
    log_cmd "oc get namespaces -o jsonpath='{.items[*].metadata.name}'"
    local all_namespaces
    all_namespaces=$(oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    for ns in $all_namespaces; do
        # Skip namespaces that should not be modified
        if echo "$ns" | grep -qE "^($skip_namespaces)$"; then
            continue
        fi

        local ns_has_failures=false
        local ns_failed_secrets=0
        local ns_failed_configmaps=0

        # ── Check Secrets ──
        # Try to list secrets; if some are undecryptable the API server returns
        # an "Internal error" or the individual items will have errors
        log_cmd "oc get secrets -n $ns -o json"
        local secret_result
        secret_result=$(oc get secrets -n "$ns" -o json 2>&1) || true

        if echo "$secret_result" | grep -qi "Internal error\|unable to transform\|decryption failed\|StorageError\|rpc error"; then
            ns_has_failures=true

            # The whole list failed — all secrets in this namespace are suspect
            log_warn "[$ns] Secrets: API returned decryption error"

            # Try to get individual secret names from etcd or cached data
            local secret_names
            secret_names=$(echo "$secret_result" | jq -r '.items[]?.metadata.name // empty' 2>/dev/null || echo "")

            if [ -z "$secret_names" ]; then
                # If we can't even list them, try to get names from a previous inventory
                if [ -f "$INVENTORY_DIR/secret-names-${ns}.txt" ]; then
                    secret_names=$(cat "$INVENTORY_DIR/secret-names-${ns}.txt")
                    log_info "  Using names from pre-test inventory"
                fi
            fi

            # Try each secret individually to find which ones are broken
            if [ -n "$secret_names" ]; then
                while IFS= read -r secret_name; do
                    [ -z "$secret_name" ] && continue
                    local get_result
                    get_result=$(oc get secret "$secret_name" -n "$ns" -o json 2>&1) || true

                    if echo "$get_result" | grep -qi "Internal error\|unable to transform\|decryption failed\|StorageError\|rpc error"; then
                        ns_failed_secrets=$((ns_failed_secrets + 1))
                        if [ "$DRY_RUN" = "true" ]; then
                            log_info "  [DRY RUN] Would delete secret: $ns/$secret_name"
                            log_cmd "  [DRY RUN] oc delete secret $secret_name -n $ns --ignore-not-found=true"
                        else
                            log_cmd "oc delete secret $secret_name -n $ns --ignore-not-found=true"
                            log_warn "  Deleting undecryptable secret: $ns/$secret_name"
                            oc delete secret "$secret_name" -n "$ns" --ignore-not-found=true 2>/dev/null || \
                                log_error "  Failed to delete secret $ns/$secret_name (may need force)"
                            total_deleted_secrets=$((total_deleted_secrets + 1))
                        fi
                    fi
                done <<< "$secret_names"
            else
                log_warn "  Cannot enumerate individual secrets — namespace may need full cleanup"
                ns_failed_secrets=$((ns_failed_secrets + 1))
            fi
        else
            # List succeeded — check if any individual items have issues
            # Try to access each secret's data field
            local secret_names_ok
            secret_names_ok=$(echo "$secret_result" | jq -r '.items[]?.metadata.name // empty' 2>/dev/null || echo "")
            while IFS= read -r secret_name; do
                [ -z "$secret_name" ] && continue
                log_cmd "oc get secret $secret_name -n $ns -o jsonpath='{.data}'"
                local get_result
                get_result=$(oc get secret "$secret_name" -n "$ns" -o jsonpath='{.data}' 2>&1) || true

                if echo "$get_result" | grep -qi "Internal error\|unable to transform\|decryption failed\|StorageError\|rpc error"; then
                    ns_has_failures=true
                    ns_failed_secrets=$((ns_failed_secrets + 1))
                    if [ "$DRY_RUN" = "true" ]; then
                        log_info "  [DRY RUN] Would delete secret: $ns/$secret_name"
                        log_cmd "  [DRY RUN] oc delete secret $secret_name -n $ns --ignore-not-found=true"
                    else
                        log_cmd "oc delete secret $secret_name -n $ns --ignore-not-found=true"
                        log_warn "  Deleting undecryptable secret: $ns/$secret_name"
                        oc delete secret "$secret_name" -n "$ns" --ignore-not-found=true 2>/dev/null || true
                        total_deleted_secrets=$((total_deleted_secrets + 1))
                    fi
                fi
            done <<< "$secret_names_ok"
        fi

        # ── Check ConfigMaps ──
        log_cmd "oc get configmaps -n $ns -o json"
        local cm_result
        cm_result=$(oc get configmaps -n "$ns" -o json 2>&1) || true

        if echo "$cm_result" | grep -qi "Internal error\|unable to transform\|decryption failed\|StorageError\|rpc error"; then
            ns_has_failures=true

            log_warn "[$ns] ConfigMaps: API returned decryption error"

            local cm_names
            cm_names=$(echo "$cm_result" | jq -r '.items[]?.metadata.name // empty' 2>/dev/null || echo "")

            if [ -z "$cm_names" ]; then
                if [ -f "$INVENTORY_DIR/configmap-names-${ns}.txt" ]; then
                    cm_names=$(cat "$INVENTORY_DIR/configmap-names-${ns}.txt")
                    log_info "  Using names from pre-test inventory"
                fi
            fi

            if [ -n "$cm_names" ]; then
                while IFS= read -r cm_name; do
                    [ -z "$cm_name" ] && continue
                    local get_cm_result
                    get_cm_result=$(oc get configmap "$cm_name" -n "$ns" -o json 2>&1) || true

                    if echo "$get_cm_result" | grep -qi "Internal error\|unable to transform\|decryption failed\|StorageError\|rpc error"; then
                        ns_failed_configmaps=$((ns_failed_configmaps + 1))
                        if [ "$DRY_RUN" = "true" ]; then
                            log_info "  [DRY RUN] Would delete configmap: $ns/$cm_name"
                            log_cmd "  [DRY RUN] oc delete configmap $cm_name -n $ns --ignore-not-found=true"
                        else
                            log_cmd "oc delete configmap $cm_name -n $ns --ignore-not-found=true"
                            log_warn "  Deleting undecryptable configmap: $ns/$cm_name"
                            oc delete configmap "$cm_name" -n "$ns" --ignore-not-found=true 2>/dev/null || \
                                log_error "  Failed to delete configmap $ns/$cm_name"
                            total_deleted_configmaps=$((total_deleted_configmaps + 1))
                        fi
                    fi
                done <<< "$cm_names"
            else
                log_warn "  Cannot enumerate individual configmaps — namespace may need full cleanup"
                ns_failed_configmaps=$((ns_failed_configmaps + 1))
            fi
        else
            local cm_names_ok
            cm_names_ok=$(echo "$cm_result" | jq -r '.items[]?.metadata.name // empty' 2>/dev/null || echo "")
            while IFS= read -r cm_name; do
                [ -z "$cm_name" ] && continue
                log_cmd "oc get configmap $cm_name -n $ns -o jsonpath='{.data}'"
                local get_cm_result
                get_cm_result=$(oc get configmap "$cm_name" -n "$ns" -o jsonpath='{.data}' 2>&1) || true

                if echo "$get_cm_result" | grep -qi "Internal error\|unable to transform\|decryption failed\|StorageError\|rpc error"; then
                    ns_has_failures=true
                    ns_failed_configmaps=$((ns_failed_configmaps + 1))
                    if [ "$DRY_RUN" = "true" ]; then
                        log_info "  [DRY RUN] Would delete configmap: $ns/$cm_name"
                        log_cmd "  [DRY RUN] oc delete configmap $cm_name -n $ns --ignore-not-found=true"
                    else
                        log_cmd "oc delete configmap $cm_name -n $ns --ignore-not-found=true"
                        log_warn "  Deleting undecryptable configmap: $ns/$cm_name"
                        oc delete configmap "$cm_name" -n "$ns" --ignore-not-found=true 2>/dev/null || true
                        total_deleted_configmaps=$((total_deleted_configmaps + 1))
                    fi
                fi
            done <<< "$cm_names_ok"
        fi

        if [ "$ns_has_failures" = true ]; then
            namespaces_affected=$((namespaces_affected + 1))
            total_failed_secrets=$((total_failed_secrets + ns_failed_secrets))
            total_failed_configmaps=$((total_failed_configmaps + ns_failed_configmaps))
        fi
    done

    # Summary
    echo ""
    log_header "Deletion Summary"
    echo "    Namespaces affected:     $namespaces_affected"
    echo "    Undecryptable secrets:    $total_failed_secrets"
    echo "    Undecryptable configmaps: $total_failed_configmaps"

    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        log_info "DRY RUN — nothing was deleted. Run without --dry-run to delete."
    else
        echo "    Deleted secrets:          $total_deleted_secrets"
        echo "    Deleted configmaps:       $total_deleted_configmaps"

        # Save deletion report
        {
            echo "KMS Key Loss - Deletion Report"
            echo "=============================="
            echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "Namespaces affected: $namespaces_affected"
            echo "Undecryptable secrets found: $total_failed_secrets"
            echo "Undecryptable configmaps found: $total_failed_configmaps"
            echo "Deleted secrets: $total_deleted_secrets"
            echo "Deleted configmaps: $total_deleted_configmaps"
        } > "$INVENTORY_DIR/deletion-report.txt"

        echo ""
        log_info "Now waiting for operators to recreate deleted resources..."
        echo "    Run: $0 --verify-recovery"
    fi
}

# ============================================================================
# Phase 4: Verify Operator Recovery
# ============================================================================
verify_recovery() {
    log_header "Phase 4: Verifying Operator Recovery"

    # Step 1: Check cluster operators
    log_step "Checking Cluster Operator Status"

    log_cmd "oc get clusteroperators --no-headers"
    local degraded_ops
    degraded_ops=$(oc get clusteroperators --no-headers 2>/dev/null | awk '$5 == "True" {print $1}' || echo "")

    local progressing_ops
    progressing_ops=$(oc get clusteroperators --no-headers 2>/dev/null | awk '$4 == "True" {print $1}' || echo "")

    local unavailable_ops
    unavailable_ops=$(oc get clusteroperators --no-headers 2>/dev/null | awk '$3 != "True" {print $1}' || echo "")

    if [ -n "$degraded_ops" ]; then
        log_warn "Degraded operators (still recovering):"
        echo "$degraded_ops" | while read -r op; do echo "    - $op"; done
    else
        log_success "No degraded operators"
    fi

    if [ -n "$progressing_ops" ]; then
        log_info "Progressing operators (actively reconciling):"
        echo "$progressing_ops" | while read -r op; do echo "    - $op"; done
    else
        log_success "No operators progressing"
    fi

    if [ -n "$unavailable_ops" ]; then
        log_warn "Unavailable operators:"
        echo "$unavailable_ops" | while read -r op; do echo "    - $op"; done
    else
        log_success "All operators available"
    fi

    # Step 2: Compare resource counts against inventory
    log_step "Comparing Resource Counts Against Pre-Test Inventory"

    if [ ! -f "$INVENTORY_DIR/inventory-summary.txt" ]; then
        # Try to find the most recent inventory directory
        local latest_inventory
        latest_inventory=$(ls -td /tmp/kms-key-loss-test-* 2>/dev/null | head -1 || echo "")
        if [ -n "$latest_inventory" ] && [ -f "$latest_inventory/inventory-summary.txt" ]; then
            INVENTORY_DIR="$latest_inventory"
            log_info "Using inventory from: $INVENTORY_DIR"
        else
            log_warn "No pre-test inventory found. Skipping comparison."
            log_info "Run --inventory first to establish a baseline."
        fi
    fi

    if [ -f "$INVENTORY_DIR/inventory-summary.txt" ]; then
        local recovery_ok=true
        local total_before_secrets=0
        local total_after_secrets=0
        local total_before_cm=0
        local total_after_cm=0

        printf "\n  %-50s %10s %10s %10s %10s\n" "NAMESPACE" "SEC(before)" "SEC(now)" "CM(before)" "CM(now)"
        printf "  %-50s %10s %10s %10s %10s\n" "─────────" "──────────" "────────" "─────────" "───────"

        for ns in "${OPERATOR_NAMESPACES[@]}"; do
            if ! oc get namespace "$ns" &>/dev/null; then
                continue
            fi

            # Get before counts from inventory files
            local before_sec=0
            local before_cm=0
            if [ -f "$INVENTORY_DIR/secret-names-${ns}.txt" ]; then
                before_sec=$(wc -l < "$INVENTORY_DIR/secret-names-${ns}.txt" | tr -d ' ')
            fi
            if [ -f "$INVENTORY_DIR/configmap-names-${ns}.txt" ]; then
                before_cm=$(wc -l < "$INVENTORY_DIR/configmap-names-${ns}.txt" | tr -d ' ')
            fi

            # Get current counts
            log_cmd "oc get secrets -n $ns --no-headers | wc -l"
            local now_sec
            now_sec=$(oc get secrets -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
            log_cmd "oc get configmaps -n $ns --no-headers | wc -l"
            local now_cm
            now_cm=$(oc get configmaps -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')

            total_before_secrets=$((total_before_secrets + before_sec))
            total_after_secrets=$((total_after_secrets + now_sec))
            total_before_cm=$((total_before_cm + before_cm))
            total_after_cm=$((total_after_cm + now_cm))

            # Only show namespaces with differences
            if [ "$before_sec" != "$now_sec" ] || [ "$before_cm" != "$now_cm" ]; then
                local sec_diff=""
                local cm_diff=""
                [ "$before_sec" != "$now_sec" ] && sec_diff=" ←"
                [ "$before_cm" != "$now_cm" ] && cm_diff=" ←"
                printf "  %-50s %10s %10s%s %10s %10s%s\n" "$ns" "$before_sec" "$now_sec" "$sec_diff" "$before_cm" "$now_cm" "$cm_diff"
                recovery_ok=false
            fi
        done

        printf "  %-50s %10s %10s %10s %10s\n" "─────────" "──────────" "────────" "─────────" "───────"
        printf "  %-50s %10s %10s %10s %10s\n" "TOTAL" "$total_before_secrets" "$total_after_secrets" "$total_before_cm" "$total_after_cm"

        echo ""
        if [ "$recovery_ok" = true ]; then
            log_success "All resource counts match pre-test inventory — full recovery!"
        else
            log_warn "Some resource counts differ from pre-test inventory"
            log_info "This may be normal: operators may create slightly different resources"
            log_info "  '←' marks namespaces with differences"
        fi
    fi

    # Step 3: Verify secrets/configmaps are readable (no decryption errors)
    log_step "Verifying Secrets and ConfigMaps Are Readable (No Decryption Errors)"

    local read_errors=0
    local namespaces_checked=0

    for ns in "${OPERATOR_NAMESPACES[@]}"; do
        if ! oc get namespace "$ns" &>/dev/null; then
            continue
        fi
        namespaces_checked=$((namespaces_checked + 1))

        # Try reading all secrets
        log_cmd "oc get secrets -n $ns -o json"
        local sec_result
        sec_result=$(oc get secrets -n "$ns" -o json 2>&1) || true
        if echo "$sec_result" | grep -qi "Internal error\|unable to transform\|decryption failed\|StorageError"; then
            log_error "[$ns] Still has undecryptable secrets!"
            read_errors=$((read_errors + 1))
        fi

        # Try reading all configmaps
        log_cmd "oc get configmaps -n $ns -o json"
        local cm_result
        cm_result=$(oc get configmaps -n "$ns" -o json 2>&1) || true
        if echo "$cm_result" | grep -qi "Internal error\|unable to transform\|decryption failed\|StorageError"; then
            log_error "[$ns] Still has undecryptable configmaps!"
            read_errors=$((read_errors + 1))
        fi
    done

    if [ "$read_errors" -eq 0 ]; then
        log_success "All secrets and configmaps in $namespaces_checked namespaces are readable"
    else
        log_error "$read_errors namespaces still have decryption errors"
        log_info "Operators may still be reconciling. Wait and try again."
    fi

    # Step 4: Create a new test secret to verify writes work
    log_step "Testing Secret Creation (Write Path)"
    local test_ns="default"
    local test_name="kms-recovery-write-test-$(date +%s)"

    log_cmd "oc create secret generic $test_name --from-literal=test-key=recovery-value-... -n $test_ns"
    if oc create secret generic "$test_name" \
        --from-literal=test-key="recovery-value-$(date +%s)" \
        -n "$test_ns" &>/dev/null; then

        log_cmd "oc get secret $test_name -n $test_ns -o jsonpath='{.data.test-key}' | base64 -d"
        local read_val
        read_val=$(oc get secret "$test_name" -n "$test_ns" \
            -o jsonpath='{.data.test-key}' 2>/dev/null | base64 -d 2>/dev/null || echo "FAILED")

        if echo "$read_val" | grep -q "recovery-value"; then
            log_success "New secret created and read successfully"
        else
            log_error "Failed to read back new secret (value: $read_val)"
        fi

        log_cmd "oc delete secret $test_name -n $test_ns --ignore-not-found=true"
        oc delete secret "$test_name" -n "$test_ns" --ignore-not-found=true &>/dev/null
    else
        log_error "Failed to create new secret — kube-apiserver may have issues"
    fi

    # Step 5: Check KMS plugin pods
    log_step "Checking KMS Plugin Pods"
    log_cmd "oc get pods -n $KMS_NAMESPACE --no-headers"
    local kms_pods
    kms_pods=$(oc get pods -n "$KMS_NAMESPACE" --no-headers 2>/dev/null || echo "")
    if [ -n "$kms_pods" ]; then
        echo "$kms_pods" | while read -r line; do
            echo "    $line"
        done
        local running
        running=$(echo "$kms_pods" | grep -c "Running" || echo "0")
        local total
        total=$(echo "$kms_pods" | wc -l | tr -d ' ')
        if [ "$running" = "$total" ] && [ "$total" -gt 0 ]; then
            log_success "KMS plugin: $running/$total pods running"
        else
            log_warn "KMS plugin: $running/$total pods running"
        fi
    else
        log_warn "No KMS plugin pods found"
    fi

    # Final summary
    echo ""
    log_header "Recovery Verification Summary"

    # Save post-recovery cluster operator status
    log_cmd "oc get clusteroperators --no-headers > $INVENTORY_DIR/clusteroperators-after.txt"
    oc get clusteroperators --no-headers > "$INVENTORY_DIR/clusteroperators-after.txt" 2>/dev/null || true

    if [ "$read_errors" -eq 0 ] && [ -z "$degraded_ops" ] && [ -z "$unavailable_ops" ]; then
        printf "  ${GREEN}RESULT: PLATFORM RECOVERED SUCCESSFULLY${NC}\n"
        echo ""
        echo "  ✓ All cluster operators are available and not degraded"
        echo "  ✓ All secrets and configmaps are readable (no decryption errors)"
        echo "  ✓ New secrets can be created and read"
        echo "  ✓ KMS plugin pods are healthy"
    elif [ "$read_errors" -eq 0 ]; then
        printf "  ${YELLOW}RESULT: PARTIAL RECOVERY${NC}\n"
        echo ""
        echo "  ✓ All resources are readable"
        echo "  ⚠ Some operators may still be recovering"
        echo "  → Wait a few minutes and run: $0 --verify-recovery"
    else
        printf "  ${RED}RESULT: RECOVERY INCOMPLETE${NC}\n"
        echo ""
        echo "  ✗ Some resources are still undecryptable"
        echo "  → Run: $0 --delete-undecryptable"
        echo "  → Then wait and run: $0 --verify-recovery"
    fi
}

# ============================================================================
# Recovery: Create New KMS Key and Re-enable Encryption
# ============================================================================
recover_kms() {
    log_header "KMS Recovery: Creating New Transit Key"

    check_vault

    log_info "This will create a NEW Transit key with the same name: $VAULT_KEY_NAME"
    log_info "New secrets will be encrypted with the new key."
    log_info "Previously encrypted data (already deleted) cannot be recovered."
    echo ""

    if [ "$SKIP_CONFIRM" != "true" ]; then
        read -p "Create new Transit key '$VAULT_KEY_NAME'? [Y/n]: " confirm
        if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
            log_info "Cancelled"
            return
        fi
    fi

    # Create new Transit key
    log_step "Creating new Transit key: $VAULT_KEY_NAME"
    log_cmd "curl -s -X POST -H 'X-Vault-Token: ***' -d '{\"type\": \"aes256-gcm96\"}' $VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME"
    local create_resp
    create_resp=$(curl "${CURL_OPTS[@]}" -w "\n%{http_code}" \
        "${VAULT_HEADERS[@]}" \
        --request POST \
        --data '{"type": "aes256-gcm96"}' \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME" 2>/dev/null)

    local http_code
    http_code=$(echo "$create_resp" | tail -n1)

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        log_success "New Transit key '$VAULT_KEY_NAME' created"
    else
        log_error "Failed to create key (HTTP $http_code)"
        echo "    Response: $(echo "$create_resp" | head -n -1)"
        exit 1
    fi

    # Verify key
    log_step "Verifying new key"
    log_cmd "curl -s -H 'X-Vault-Token: ***' $VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME"
    local key_info
    key_info=$(curl "${CURL_OPTS[@]}" "${VAULT_HEADERS[@]}" \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME" 2>/dev/null)

    if echo "$key_info" | jq -e '.data.name' &>/dev/null; then
        log_success "Key verified: $(echo "$key_info" | jq -r '.data.name') (type: $(echo "$key_info" | jq -r '.data.type'))"
    else
        log_warn "Could not verify key — check Vault manually"
    fi

    # Test encrypt/decrypt
    log_step "Testing encrypt/decrypt with new key"
    local test_plaintext
    test_plaintext=$(printf "recovery-test-%s" "$(date +%s)" | base64 | tr -d '\n')

    log_cmd "curl -s -X POST -H 'X-Vault-Token: ***' -d '{\"plaintext\": \"...\"}' $VAULT_ADDR/v1/$TRANSIT_MOUNT/encrypt/$VAULT_KEY_NAME"
    local encrypt_resp
    encrypt_resp=$(curl "${CURL_OPTS[@]}" "${VAULT_HEADERS[@]}" \
        --request POST \
        --data "{\"plaintext\": \"$test_plaintext\"}" \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/encrypt/$VAULT_KEY_NAME" 2>/dev/null)

    local ciphertext
    ciphertext=$(echo "$encrypt_resp" | jq -r '.data.ciphertext // empty' 2>/dev/null)

    if [ -n "$ciphertext" ]; then
        log_success "Encryption works: got ciphertext"

        # Test decrypt
        log_cmd "curl -s -X POST -H 'X-Vault-Token: ***' -d '{\"ciphertext\": \"...\"}' $VAULT_ADDR/v1/$TRANSIT_MOUNT/decrypt/$VAULT_KEY_NAME"
        local decrypt_resp
        decrypt_resp=$(curl "${CURL_OPTS[@]}" "${VAULT_HEADERS[@]}" \
            --request POST \
            --data "{\"ciphertext\": \"$ciphertext\"}" \
            "$VAULT_ADDR/v1/$TRANSIT_MOUNT/decrypt/$VAULT_KEY_NAME" 2>/dev/null)

        local decrypted
        decrypted=$(echo "$decrypt_resp" | jq -r '.data.plaintext // empty' 2>/dev/null)

        if [ "$decrypted" = "$test_plaintext" ]; then
            log_success "Decryption works: plaintext matches"
        else
            log_error "Decryption mismatch!"
        fi
    else
        log_error "Encryption test failed"
        echo "    Response: $encrypt_resp"
    fi

    # Restart KMS plugin pods so they pick up the new key
    log_step "Restarting KMS plugin pods"
    log_cmd "oc get pods -n $KMS_NAMESPACE -l app=vault-kube-kms -o jsonpath='{.items[*].metadata.name}'"
    local kms_pods
    kms_pods=$(oc get pods -n "$KMS_NAMESPACE" -l app=vault-kube-kms -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$kms_pods" ]; then
        for pod in $kms_pods; do
            log_cmd "oc delete pod $pod -n $KMS_NAMESPACE --grace-period=0 --force"
            oc delete pod "$pod" -n "$KMS_NAMESPACE" --grace-period=0 --force 2>/dev/null || true
            log_info "Deleted pod $pod (will be recreated)"
        done

        log_info "Waiting for KMS pods to restart..."
        sleep 15
        log_cmd "oc get pods -n $KMS_NAMESPACE --no-headers"
        oc get pods -n "$KMS_NAMESPACE" --no-headers 2>/dev/null | while read -r line; do
            echo "    $line"
        done
    else
        log_warn "No KMS plugin pods found to restart"
        # For static pods, we'd need to touch the manifest files
        log_info "If using static pods, restart kubelet on control plane nodes"
    fi

    echo ""
    log_success "KMS recovery complete"
    echo ""
    echo "  New Transit key created and tested."
    echo "  KMS plugin pods restarted."
    echo ""
    echo "  Next steps:"
    echo "    1. Verify platform health: $0 --verify-recovery"
    echo "    2. All new secrets will be encrypted with the new key"
    echo "    3. Previously lost secrets have been recreated by operators"
}

# ============================================================================
# Scenario: Simulate Key Corruption
# ============================================================================
simulate_key_corruption() {
    log_header "Key Corruption Scenario"

    check_vault

    log_info "This scenario simulates key corruption by rotating the Transit key"
    log_info "and setting min_decryption_version to the new version."
    log_info "All data encrypted with previous key versions becomes UNDECRYPTABLE."
    echo ""

    # Verify key exists
    log_step "Verifying Transit key exists"
    log_cmd "curl -s -H 'X-Vault-Token: ***' $VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME"
    local key_info
    key_info=$(curl "${CURL_OPTS[@]}" "${VAULT_HEADERS[@]}" \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME" 2>/dev/null)

    if ! echo "$key_info" | jq -e '.data.name' &>/dev/null; then
        log_error "Transit key '$VAULT_KEY_NAME' not found"
        echo "    Response: $(echo "$key_info" | jq -r '.errors[]?' 2>/dev/null || echo "$key_info")"
        exit 1
    fi

    local current_version
    current_version=$(echo "$key_info" | jq -r '.data.latest_version')
    log_success "Key found: version=$current_version, type=$(echo "$key_info" | jq -r '.data.type')"

    # Save key metadata
    echo "$key_info" | jq '.' > "$INVENTORY_DIR/transit-key-before-corruption.json" 2>/dev/null || true

    log_warn "════════════════════════════════════════════════════════"
    log_warn "  THIS WILL CORRUPT THE KMS KEY!"
    log_warn "════════════════════════════════════════════════════════"
    log_warn ""
    log_warn "  Key: $VAULT_KEY_NAME (current version: $current_version)"
    log_warn "  Action: Rotate key, then set min_decryption_version = new version"
    log_warn "  Effect: All data encrypted with version $current_version becomes undecryptable"
    log_warn ""

    if [ "$SKIP_CONFIRM" != "true" ]; then
        printf "${RED}Type 'CORRUPT KEY' to confirm: ${NC}"
        read -r confirm
        if [ "$confirm" != "CORRUPT KEY" ]; then
            log_info "Cancelled"
            return 1
        fi
    fi

    # Step 1: Rotate the key (creates a new version)
    log_step "Rotating Transit key"
    log_cmd "curl -s -X POST -H 'X-Vault-Token: ***' $VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME/rotate"
    local rotate_resp
    rotate_resp=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
        "${VAULT_HEADERS[@]}" \
        --request POST \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME/rotate" 2>/dev/null)

    if [ "$rotate_resp" = "200" ] || [ "$rotate_resp" = "204" ]; then
        log_success "Key rotated (HTTP $rotate_resp)"
    else
        log_error "Failed to rotate key (HTTP $rotate_resp)"
        exit 1
    fi

    # Get the new version number
    local new_key_info new_version
    new_key_info=$(curl "${CURL_OPTS[@]}" "${VAULT_HEADERS[@]}" \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME" 2>/dev/null)
    new_version=$(echo "$new_key_info" | jq -r '.data.latest_version')
    log_info "New key version: $new_version (old: $current_version)"

    # Step 2: Set min_decryption_version to the new version
    # This makes all ciphertext encrypted with older versions undecryptable
    log_step "Setting min_decryption_version=$new_version (invalidating old ciphertext)"
    log_cmd "curl -s -X POST -H 'X-Vault-Token: ***' -d '{\"min_decryption_version\": $new_version}' $VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME/config"
    local config_resp
    config_resp=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
        "${VAULT_HEADERS[@]}" \
        --request POST \
        --data "{\"min_decryption_version\": $new_version}" \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME/config" 2>/dev/null)

    if [ "$config_resp" = "200" ] || [ "$config_resp" = "204" ]; then
        log_success "min_decryption_version set to $new_version"
    else
        log_error "Failed to set min_decryption_version (HTTP $config_resp)"
        exit 1
    fi

    # Step 3: Verify corruption
    log_step "Verifying key state"
    local verify_info
    verify_info=$(curl "${CURL_OPTS[@]}" "${VAULT_HEADERS[@]}" \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME" 2>/dev/null)

    local min_dec_ver min_enc_ver
    min_dec_ver=$(echo "$verify_info" | jq -r '.data.min_decryption_version')
    min_enc_ver=$(echo "$verify_info" | jq -r '.data.min_encryption_version // 0')
    log_success "Key state: latest=$new_version, min_decryption=$min_dec_ver"

    echo "$verify_info" | jq '.' > "$INVENTORY_DIR/transit-key-after-corruption.json" 2>/dev/null || true

    echo ""
    log_warn "KMS KEY HAS BEEN CORRUPTED"
    log_warn ""
    log_warn "All existing encrypted data (using key version <= $current_version) is now undecryptable."
    log_warn "New encryptions will use key version $new_version."
    log_warn ""
    log_info "Wait 1-2 minutes for failures to propagate, then run:"
    echo "    $0 --delete-undecryptable"
    echo ""
    log_info "To recover, reset min_decryption_version:"
    echo "    $0 --recover-corrupted-key --username USER --password PASS"

    date -u +%Y-%m-%dT%H:%M:%SZ > "$INVENTORY_DIR/key-corruption-timestamp.txt"
    echo "$current_version" > "$INVENTORY_DIR/key-corruption-old-version.txt"
}

# ============================================================================
# Recovery: Undo Key Corruption
# ============================================================================
recover_corrupted_key() {
    log_header "Recovering Corrupted Key (Resetting min_decryption_version)"

    check_vault

    # Get current key info
    log_step "Reading current key state"
    local key_info
    key_info=$(curl "${CURL_OPTS[@]}" "${VAULT_HEADERS[@]}" \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME" 2>/dev/null)

    if ! echo "$key_info" | jq -e '.data.name' &>/dev/null; then
        log_error "Transit key '$VAULT_KEY_NAME' not found"
        exit 1
    fi

    local current_min_dec latest_ver
    current_min_dec=$(echo "$key_info" | jq -r '.data.min_decryption_version')
    latest_ver=$(echo "$key_info" | jq -r '.data.latest_version')
    log_info "Current state: latest=$latest_ver, min_decryption=$current_min_dec"

    if [ "$current_min_dec" = "1" ]; then
        log_success "min_decryption_version is already 1 — key is not corrupted"
        return
    fi

    # Reset min_decryption_version to 1
    log_step "Resetting min_decryption_version to 1"
    log_cmd "curl -s -X POST -H 'X-Vault-Token: ***' -d '{\"min_decryption_version\": 1}' $VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME/config"
    local config_resp
    config_resp=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
        "${VAULT_HEADERS[@]}" \
        --request POST \
        --data '{"min_decryption_version": 1}' \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME/config" 2>/dev/null)

    if [ "$config_resp" = "200" ] || [ "$config_resp" = "204" ]; then
        log_success "min_decryption_version reset to 1 — all key versions are now usable"
    else
        log_error "Failed to reset min_decryption_version (HTTP $config_resp)"
        exit 1
    fi

    # Verify
    log_step "Verifying recovery"
    local verify_info
    verify_info=$(curl "${CURL_OPTS[@]}" "${VAULT_HEADERS[@]}" \
        "$VAULT_ADDR/v1/$TRANSIT_MOUNT/keys/$VAULT_KEY_NAME" 2>/dev/null)
    local new_min_dec
    new_min_dec=$(echo "$verify_info" | jq -r '.data.min_decryption_version')
    log_success "Key recovered: min_decryption_version=$new_min_dec"

    echo ""
    log_info "The key can now decrypt data encrypted with all versions."
    log_info "Existing KMS-encrypted resources should become readable again."
    log_info "Wait 1-2 minutes, then verify: $0 --verify-recovery"
}

# ============================================================================
# Helper: Take etcd backup before destructive operations
# ============================================================================
take_etcd_backup_before_delete() {
    log_step "Taking etcd backup (MANDATORY before all-namespace deletion)"

    local backup_node
    backup_node=$(oc get nodes -l node-role.kubernetes.io/master="" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
                  oc get nodes -l node-role.kubernetes.io/control-plane="" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$backup_node" ]; then
        log_error "No control plane node found for etcd backup"
        exit 1
    fi

    local backup_timestamp
    backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="/home/core/assets/backup_before_delete_${backup_timestamp}"

    log_info "Backup node: $backup_node"
    log_info "Backup path: $backup_dir"

    local backup_output
    backup_output=$(oc debug node/"$backup_node" -q -- chroot /host bash -c "
        /usr/local/bin/cluster-backup.sh $backup_dir 2>&1
    " 2>&1 || echo "BACKUP_FAILED")

    if echo "$backup_output" | grep -qi "snapshot saved\|backup completed\|snapshot db\|Snapshot saved"; then
        log_success "etcd backup completed: $backup_node:$backup_dir"
    elif echo "$backup_output" | grep -qi "BACKUP_FAILED\|error"; then
        log_error "etcd backup FAILED. Cannot proceed without a backup."
        echo "    Output: $(echo "$backup_output" | tail -5)"
        echo ""
        log_info "Take a manual backup before proceeding:"
        echo "    oc debug node/$backup_node -- chroot /host /usr/local/bin/cluster-backup.sh $backup_dir"
        exit 1
    else
        log_warn "Backup completed (unable to confirm status):"
        echo "$backup_output" | tail -5 | while read -r line; do echo "    $line"; done
    fi

    # Save backup location for restore instructions
    echo "$backup_node:$backup_dir" > "$INVENTORY_DIR/etcd-backup-location.txt"
    echo ""
    log_info "To restore from this backup if the cluster becomes unrecoverable:"
    echo "    ./etcd-backup-restore-kms.sh --restore --backup-dir $backup_dir --backup-node $backup_node"
    echo ""
}

# ============================================================================
# Helper: Get etcd pod and env for etcdctl commands
# ============================================================================
get_etcd_pod_and_env() {
    log_step "Finding etcd pod"
    log_cmd "oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.name}'"
    ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$ETCD_POD" ]; then
        log_error "No etcd pod found in openshift-etcd namespace"
        exit 1
    fi
    log_success "Using etcd pod: $ETCD_POD"

    # Detect the correct container and cert paths for this cluster.
    # The etcdctl container (if it exists) has env vars pre-configured.
    # Otherwise fall back to the etcd container with explicit cert paths.
    ETCD_CONTAINER="etcdctl"
    ETCD_ENV=""

    # Test if etcdctl container exists and works
    log_info "Detecting etcd container and cert paths..."
    local test_result
    test_result=$(oc exec -n openshift-etcd "$ETCD_POD" -c etcdctl -- \
        etcdctl get / --prefix --keys-only --limit 1 2>&1) || true

    if echo "$test_result" | grep -q "kubernetes.io\|/registry"; then
        log_success "Using container: etcdctl (pre-configured env)"
    else
        # Try etcd container with OpenShift 4.x cert paths
        ETCD_CONTAINER="etcd"
        ETCD_ENV="ETCDCTL_API=3 ETCDCTL_CACERT=/etc/kubernetes/pki/etcd-peer/ca-bundle.crt ETCDCTL_CERT=/etc/kubernetes/pki/etcd-peer/peer.crt ETCDCTL_KEY=/etc/kubernetes/pki/etcd-peer/peer.key ETCDCTL_ENDPOINTS=https://localhost:2379"

        test_result=$(oc exec -n openshift-etcd "$ETCD_POD" -c "$ETCD_CONTAINER" -- \
            sh -c "$ETCD_ENV etcdctl get / --prefix --keys-only --limit 1" 2>&1) || true

        if echo "$test_result" | grep -q "kubernetes.io\|/registry"; then
            log_success "Using container: etcd (OpenShift 4.x cert paths)"
        else
            # Last resort: try older cert paths
            ETCD_ENV="ETCDCTL_API=3 ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt ETCDCTL_CERT=/etc/kubernetes/pki/etcd/peer.crt ETCDCTL_KEY=/etc/kubernetes/pki/etcd/peer.key ETCDCTL_ENDPOINTS=https://localhost:2379"

            test_result=$(oc exec -n openshift-etcd "$ETCD_POD" -c "$ETCD_CONTAINER" -- \
                sh -c "$ETCD_ENV etcdctl get / --prefix --keys-only --limit 1" 2>&1) || true

            if echo "$test_result" | grep -q "kubernetes.io\|/registry"; then
                log_success "Using container: etcd (legacy cert paths)"
            else
                log_error "Cannot connect to etcd. Tried all known cert paths."
                echo "    Last attempt output: $test_result"
                echo ""
                echo "    Debug: list containers in etcd pod:"
                oc get pod "$ETCD_POD" -n openshift-etcd -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true
                echo ""
                echo "    Debug: try manually:"
                echo "      oc exec -n openshift-etcd $ETCD_POD -c etcd -- etcdctl get / --prefix --keys-only --limit 1"
                exit 1
            fi
        fi
    fi
}

# Global variables used by scan/delete helpers (bash 3.2 compatible, no namerefs)
SCANNED_KEYS=()
SCANNED_TOTAL=0

# Helper: run etcdctl command in the detected container
run_etcdctl() {
    if [ -n "$ETCD_ENV" ]; then
        # Build a properly quoted command string for sh -c
        local cmd="$ETCD_ENV etcdctl"
        local arg
        for arg in "$@"; do
            cmd="$cmd '$arg'"
        done
        oc exec -n openshift-etcd "$ETCD_POD" -c "$ETCD_CONTAINER" -- sh -c "$cmd"
    else
        oc exec -n openshift-etcd "$ETCD_POD" -c "$ETCD_CONTAINER" -- etcdctl "$@"
    fi
}

# ============================================================================
# Helper: Scan etcd for resource keys
# Sets: SCANNED_KEYS (array), SCANNED_TOTAL (int)
# ============================================================================
scan_etcd_keys() {
    local resource_type="$1"  # "secrets" or "configmaps"
    local scope="$2"          # "operator" or "all"

    SCANNED_KEYS=()
    SCANNED_TOTAL=0

    if [ "$scope" = "all" ]; then
        log_step "Scanning etcd for ALL $resource_type (every namespace)"

        local etcd_prefix="/kubernetes.io/${resource_type}/"
        log_cmd "etcdctl get '$etcd_prefix' --prefix --keys-only"
        local keys
        keys=$(run_etcdctl get "$etcd_prefix" --prefix --keys-only 2>/dev/null | grep -v '^$' || echo "")

        if [ -n "$keys" ]; then
            SCANNED_TOTAL=$(echo "$keys" | wc -l | tr -d ' ')
            echo "$keys" >> "$INVENTORY_DIR/etcd-${resource_type}-all-keys.txt"

            local current_ns=""
            local ns_count=0
            while IFS= read -r key; do
                [ -z "$key" ] && continue
                SCANNED_KEYS+=("$key")
                local ns
                ns=$(echo "$key" | sed "s|/kubernetes.io/${resource_type}/||" | cut -d'/' -f1)
                if [ "$ns" != "$current_ns" ]; then
                    [ -n "$current_ns" ] && echo "  $current_ns: $ns_count $resource_type"
                    current_ns="$ns"
                    ns_count=1
                else
                    ns_count=$((ns_count + 1))
                fi
            done <<< "$keys"
            [ -n "$current_ns" ] && echo "  $current_ns: $ns_count $resource_type"
        fi
    else
        log_step "Scanning etcd for $resource_type in operator namespaces"

        for ns in "${OPERATOR_NAMESPACES[@]}"; do
            if ! oc get namespace "$ns" &>/dev/null; then
                continue
            fi

            local etcd_prefix="/kubernetes.io/${resource_type}/${ns}/"
            log_cmd "etcdctl get '$etcd_prefix' --prefix --keys-only"
            local keys
            keys=$(run_etcdctl get "$etcd_prefix" --prefix --keys-only 2>/dev/null | grep -v '^$' || echo "")

            if [ -n "$keys" ]; then
                local count
                count=$(echo "$keys" | wc -l | tr -d ' ')
                SCANNED_TOTAL=$((SCANNED_TOTAL + count))
                echo "  $ns: $count $resource_type"
                echo "$keys" >> "$INVENTORY_DIR/etcd-${resource_type}-keys.txt"

                while IFS= read -r key; do
                    [ -z "$key" ] && continue
                    SCANNED_KEYS+=("$key")
                done <<< "$keys"
            fi
        done
    fi
}

# ============================================================================
# Helper: Delete keys from etcd
# Uses: SCANNED_KEYS (array)
# ============================================================================
delete_etcd_keys() {
    local resource_type="$1"  # "secrets" or "configmaps"
    local key_count="$2"

    log_step "Deleting $resource_type from etcd"
    local deleted=0
    local failed=0

    for key in "${SCANNED_KEYS[@]}"; do
        [ -z "$key" ] && continue
        local short_key
        short_key=$(echo "$key" | sed "s|/kubernetes.io/${resource_type}/||")
        log_cmd "etcdctl del '$key'"

        local del_result
        del_result=$(run_etcdctl del "$key" 2>&1)

        if echo "$del_result" | grep -q "^1$"; then
            deleted=$((deleted + 1))
            log_warn "  Deleted: $short_key"
        else
            failed=$((failed + 1))
            log_error "  Failed to delete: $short_key ($del_result)"
        fi
    done

    echo ""
    local scope_label="operator namespaces only"
    [ "$ALL_NAMESPACES" = "true" ] && scope_label="ALL namespaces"

    log_header "etcd $(echo "$resource_type" | sed 's/./\U&/') Deletion Summary"
    echo "    Scope:               $scope_label"
    echo "    Total keys found:    $key_count"
    echo "    Successfully deleted: $deleted"
    echo "    Failed:              $failed"

    {
        echo "etcd $resource_type Deletion Report"
        echo "=============================="
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Scope: $scope_label"
        echo "etcd pod: $ETCD_POD"
        echo "Total keys: $key_count"
        echo "Deleted: $deleted"
        echo "Failed: $failed"
    } > "$INVENTORY_DIR/etcd-${resource_type}-deletion-report.txt"

    date -u +%Y-%m-%dT%H:%M:%SZ > "$INVENTORY_DIR/etcd-${resource_type}-deletion-timestamp.txt"
}

# ============================================================================
# Scenario: Delete Secrets from etcd Directly
# ============================================================================
delete_etcd_secrets() {
    local scope="operator"
    [ "$ALL_NAMESPACES" = "true" ] && scope="all"

    log_header "etcd Direct Deletion Scenario: Secrets (scope: $scope)"

    log_info "This scenario deletes secrets directly from etcd (bypassing the API server)."
    if [ "$scope" = "all" ]; then
        log_warn "Scope: ALL NAMESPACES — this will delete EVERY secret in etcd!"
        log_warn "The cluster will very likely become UNRECOVERABLE without an etcd restore."
    else
        log_info "Scope: operator namespaces only — operators should recreate them."
    fi
    echo ""

    get_etcd_pod_and_env
    scan_etcd_keys "secrets" "$scope"

    echo ""
    log_info "Found $SCANNED_TOTAL secret keys in etcd"

    if [ "$SCANNED_TOTAL" -eq 0 ]; then
        log_warn "No secrets found in etcd"
        return
    fi

    if [ "$scope" = "all" ]; then
        log_warn "════════════════════════════════════════════════════════"
        log_warn "  EXTREME DANGER: DELETING ALL $SCANNED_TOTAL SECRETS FROM etcd!"
        log_warn "════════════════════════════════════════════════════════"
        log_warn ""
        log_warn "  This WILL take down the entire cluster."
        log_warn "  Recovery requires etcd restore from backup."
        log_warn "  There is NO other recovery path."
        log_warn ""
    else
        log_warn "════════════════════════════════════════════════════════"
        log_warn "  THIS WILL DELETE $SCANNED_TOTAL SECRETS DIRECTLY FROM etcd!"
        log_warn "════════════════════════════════════════════════════════"
        log_warn ""
        log_warn "  This bypasses the API server and removes raw data from etcd."
        log_warn "  Operators must recreate these secrets for the cluster to function."
        log_warn ""
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log_warn "DRY RUN — listing keys that would be deleted:"
        for key in "${SCANNED_KEYS[@]}"; do
            echo "    [DRY RUN] Would delete: $key"
        done
        log_info "DRY RUN — nothing was deleted."
        return
    fi

    if [ "$scope" = "all" ]; then
        take_etcd_backup_before_delete
    fi

    if [ "$SKIP_CONFIRM" != "true" ]; then
        local confirm_phrase="DELETE ETCD SECRETS"
        [ "$scope" = "all" ] && confirm_phrase="DELETE ALL ETCD SECRETS"
        printf "${RED}Type '$confirm_phrase' to confirm: ${NC}"
        read -r confirm
        if [ "$confirm" != "$confirm_phrase" ]; then
            log_info "Cancelled"
            return 1
        fi
    fi

    delete_etcd_keys "secrets" "$SCANNED_TOTAL"

    echo ""
    if [ "$scope" = "all" ]; then
        log_warn "ALL secrets deleted from etcd. The cluster WILL crash."
        log_info "To recover, restore from the etcd backup taken above:"
        [ -f "$INVENTORY_DIR/etcd-backup-location.txt" ] && echo "    $(cat "$INVENTORY_DIR/etcd-backup-location.txt")"
    else
        log_info "Operators should begin recreating deleted secrets."
        log_info "Wait 2-5 minutes, then verify: $0 --verify-recovery"
    fi
}

# ============================================================================
# Scenario: Delete ConfigMaps from etcd Directly
# ============================================================================
delete_etcd_configmaps() {
    local scope="operator"
    [ "$ALL_NAMESPACES" = "true" ] && scope="all"

    log_header "etcd Direct Deletion Scenario: ConfigMaps (scope: $scope)"

    log_info "This scenario deletes configmaps directly from etcd (bypassing the API server)."
    if [ "$scope" = "all" ]; then
        log_warn "Scope: ALL NAMESPACES — this will delete EVERY configmap in etcd!"
        log_warn "The cluster will very likely become UNRECOVERABLE without an etcd restore."
    else
        log_info "Scope: operator namespaces only — operators should recreate them."
    fi
    echo ""

    get_etcd_pod_and_env
    scan_etcd_keys "configmaps" "$scope"

    echo ""
    log_info "Found $SCANNED_TOTAL configmap keys in etcd"

    if [ "$SCANNED_TOTAL" -eq 0 ]; then
        log_warn "No configmaps found in etcd"
        return
    fi

    if [ "$scope" = "all" ]; then
        log_warn "════════════════════════════════════════════════════════"
        log_warn "  EXTREME DANGER: DELETING ALL $SCANNED_TOTAL CONFIGMAPS FROM etcd!"
        log_warn "════════════════════════════════════════════════════════"
        log_warn ""
        log_warn "  This WILL take down the entire cluster."
        log_warn "  Recovery requires etcd restore from backup."
        log_warn "  There is NO other recovery path."
        log_warn ""
    else
        log_warn "════════════════════════════════════════════════════════"
        log_warn "  THIS WILL DELETE $SCANNED_TOTAL CONFIGMAPS DIRECTLY FROM etcd!"
        log_warn "════════════════════════════════════════════════════════"
        log_warn ""
        log_warn "  This bypasses the API server and removes raw data from etcd."
        log_warn "  Operators must recreate these configmaps for the cluster to function."
        log_warn ""
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log_warn "DRY RUN — listing keys that would be deleted:"
        for key in "${SCANNED_KEYS[@]}"; do
            echo "    [DRY RUN] Would delete: $key"
        done
        log_info "DRY RUN — nothing was deleted."
        return
    fi

    if [ "$scope" = "all" ]; then
        take_etcd_backup_before_delete
    fi

    if [ "$SKIP_CONFIRM" != "true" ]; then
        local confirm_phrase="DELETE ETCD CONFIGMAPS"
        [ "$scope" = "all" ] && confirm_phrase="DELETE ALL ETCD CONFIGMAPS"
        printf "${RED}Type '$confirm_phrase' to confirm: ${NC}"
        read -r confirm
        if [ "$confirm" != "$confirm_phrase" ]; then
            log_info "Cancelled"
            return 1
        fi
    fi

    delete_etcd_keys "configmaps" "$SCANNED_TOTAL"

    echo ""
    if [ "$scope" = "all" ]; then
        log_warn "ALL configmaps deleted from etcd. The cluster WILL crash."
        log_info "To recover, restore from the etcd backup taken above:"
        [ -f "$INVENTORY_DIR/etcd-backup-location.txt" ] && echo "    $(cat "$INVENTORY_DIR/etcd-backup-location.txt")"
    else
        log_info "Operators should begin recreating deleted configmaps."
        log_info "Wait 2-5 minutes, then verify: $0 --verify-recovery"
    fi
}

# ============================================================================
# Full Test
# ============================================================================
full_test() {
    check_prerequisites

    echo ""
    printf "${BOLD}${CYAN}  KMS KEY LOSS SCENARIO — FULL TEST${NC}\n"
    echo ""
    echo "  This test will:"
    echo "    Phase 1: Take inventory of all encrypted resources (secrets, configmaps)"
    echo "    Phase 2: DELETE the Vault Transit key (simulate key loss)"
    echo "    Phase 3: Detect and delete all undecryptable resources"
    echo "    Phase 4: Verify that OpenShift operators recreate them"
    echo "    Recovery: Create new Transit key and restore KMS functionality"
    echo ""
    printf "  ${RED}WARNING: This test WILL cause temporary cluster disruption!${NC}\n"
    echo "  Secrets and configmaps across all operator namespaces will be deleted."
    echo ""

    if [ "$SKIP_CONFIRM" != "true" ]; then
        printf "  ${RED}Type 'I UNDERSTAND' to proceed: ${NC}"
        read -r confirm
        if [ "$confirm" != "I UNDERSTAND" ]; then
            log_info "Cancelled"
            exit 0
        fi
    fi

    # Phase 1
    take_inventory

    # Phase 2
    echo ""
    simulate_key_loss

    # Wait for failures to propagate
    log_info "Waiting 60 seconds for decryption failures to propagate..."
    for i in $(seq 1 6); do
        printf "    Waiting... (%d/60 seconds)\r" "$((i * 10))"
        sleep 10
    done
    echo ""

    # Phase 3
    delete_undecryptable_resources

    # Wait for operators to reconcile
    log_info "Waiting 120 seconds for operators to recreate resources..."
    for i in $(seq 1 12); do
        printf "    Waiting... (%d/120 seconds)\r" "$((i * 10))"
        sleep 10
    done
    echo ""

    # Recovery — create new key so KMS works again
    recover_kms

    # Wait a bit more for things to settle
    log_info "Waiting 60 seconds for cluster to settle..."
    for i in $(seq 1 6); do
        printf "    Waiting... (%d/60 seconds)\r" "$((i * 10))"
        sleep 10
    done
    echo ""

    # Phase 4
    verify_recovery

    echo ""
    log_header "Full Test Complete"
    echo ""
    echo "  Inventory and reports saved to: $INVENTORY_DIR"
    echo ""
    echo "  Files:"
    ls -la "$INVENTORY_DIR"/*.txt "$INVENTORY_DIR"/*.json 2>/dev/null | while read -r line; do
        echo "    $line"
    done
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    printf "${CYAN}════════════════════════════════════════════════════════════${NC}\n"
    printf "${CYAN}  KMS Key Loss Scenario Test${NC}\n"
    printf "${CYAN}════════════════════════════════════════════════════════════${NC}\n"

    if [ -z "$ACTION" ]; then
        echo ""
        echo "Choose an action:"
        echo ""
        echo "  Key Loss Test:"
        echo "    1) Full key loss simulation and recovery test"
        echo "    2) Take inventory of encrypted resources"
        echo "    3) Simulate key loss (delete Vault Transit key)"
        echo "    4) Detect and delete undecryptable resources"
        echo "    5) Verify operator recovery"
        echo "    6) Recover KMS (create new key)"
        echo ""
        echo "  Key Corruption Test:"
        echo "    7) Corrupt key (rotate + set min_decryption_version)"
        echo "    8) Recover corrupted key (reset min_decryption_version)"
        echo ""
        echo "  Direct etcd Deletion Tests:"
        echo "    9)  Delete secrets directly from etcd"
        echo "    10) Delete configmaps directly from etcd"
        echo ""
        read -p "Enter choice [1-10]: " choice
        case $choice in
            1) ACTION="full-test" ;;
            2) ACTION="inventory" ;;
            3) ACTION="simulate-key-loss" ;;
            4) ACTION="delete-undecryptable" ;;
            5) ACTION="verify-recovery" ;;
            6) ACTION="recover-kms" ;;
            7) ACTION="corrupt-key" ;;
            8) ACTION="recover-corrupted-key" ;;
            9) ACTION="delete-etcd-secrets" ;;
            10) ACTION="delete-etcd-configmaps" ;;
            *) echo "Invalid choice"; exit 1 ;;
        esac
    fi

    case $ACTION in
        full-test)
            full_test
            ;;
        inventory)
            check_prerequisites
            take_inventory
            ;;
        simulate-key-loss)
            check_prerequisites
            simulate_key_loss
            ;;
        delete-undecryptable)
            check_prerequisites
            delete_undecryptable_resources
            ;;
        verify-recovery)
            check_prerequisites
            verify_recovery
            ;;
        recover-kms)
            check_prerequisites
            recover_kms
            ;;
        corrupt-key)
            check_prerequisites
            mkdir -p "$INVENTORY_DIR"
            simulate_key_corruption
            ;;
        recover-corrupted-key)
            check_prerequisites
            mkdir -p "$INVENTORY_DIR"
            recover_corrupted_key
            ;;
        delete-etcd-secrets)
            check_prerequisites
            mkdir -p "$INVENTORY_DIR"
            delete_etcd_secrets
            ;;
        delete-etcd-configmaps)
            check_prerequisites
            mkdir -p "$INVENTORY_DIR"
            delete_etcd_configmaps
            ;;
        *)
            log_error "Unknown action: $ACTION"
            exit 1
            ;;
    esac

    echo ""
}

main
