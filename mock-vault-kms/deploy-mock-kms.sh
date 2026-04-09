#!/bin/bash
# ============================================================================
# Deploy Mock KMS Plugin to OpenShift
# ============================================================================
#
# This script deploys the mock-vault-kms plugin as a static pod on control
# plane nodes. The mock plugin accepts all vault-kube-kms flags but ignores
# them, running a mock KMS v2 gRPC provider instead.
#
# For TechPreview v2, the plugin lifecycle controller manages the plugin
# automatically. This script is for manual testing when the lifecycle
# controller is not yet available.
#
# Usage:
#   ./deploy-mock-kms.sh
#   ./deploy-mock-kms.sh --image quay.io/yourorg/mock-kms-plugin:latest
#   ./deploy-mock-kms.sh --remove
#   ./deploy-mock-kms.sh --enable-encryption
#   ./deploy-mock-kms.sh --verify
#
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

KMS_IMAGE="${KMS_IMAGE:-quay.io/rhn_support_rgangwar/mock-kms-plugin-vault:latest}"
SOCKET_PATH="/var/run/kmsplugin/kms.sock"
MANIFEST_NAME="mock-vault-kms"
MANIFEST_PATH="/etc/kubernetes/manifests/${MANIFEST_NAME}.yaml"
ACTION="deploy"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --image IMAGE          Mock KMS plugin image (default: $KMS_IMAGE)
  --remove               Remove the mock KMS plugin from all control plane nodes
  --enable-encryption    Deploy plugin AND enable KMS encryption on the cluster
  --verify               Verify the mock KMS plugin is running and functional
  --status               Show current status of mock KMS plugin pods
  --help                 Show this help

Environment variables:
  KMS_IMAGE              Override the default mock KMS plugin image

Examples:
  $(basename "$0")
  $(basename "$0") --image quay.io/yourorg/mock-kms-plugin:v1
  $(basename "$0") --verify
  $(basename "$0") --remove
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image)        KMS_IMAGE="$2"; shift 2 ;;
        --remove)       ACTION="remove"; shift ;;
        --enable-encryption) ACTION="deploy-and-encrypt"; shift ;;
        --verify)       ACTION="verify"; shift ;;
        --status)       ACTION="status"; shift ;;
        --help|-h)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_step()  { echo -e "\n${BOLD}▶ $*${NC}"; }

get_control_plane_nodes() {
    oc get nodes -l node-role.kubernetes.io/master --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || \
    oc get nodes -l node-role.kubernetes.io/control-plane --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null
}

generate_static_pod_manifest() {
    cat <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ${MANIFEST_NAME}
  namespace: openshift-kms-plugin
  labels:
    app: mock-vault-kms
    tier: control-plane
spec:
  hostNetwork: false
  priorityClassName: system-node-critical
  containers:
  - name: mock-vault-kms
    image: ${KMS_IMAGE}
    imagePullPolicy: Always
    args:
    - "--listen-address=unix://${SOCKET_PATH}"
    - "--vault-address=https://mock.vault.local:8200"
    - "--vault-namespace=mock"
    - "--transit-mount=transit"
    - "--transit-key=kms-key"
    - "--log-level=info"
    volumeMounts:
    - name: kmsplugin
      mountPath: /var/run/kmsplugin
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
      limits:
        cpu: 100m
        memory: 64Mi
    securityContext:
      privileged: true
  volumes:
  - name: kmsplugin
    hostPath:
      path: /var/run/kmsplugin
      type: DirectoryOrCreate
MANIFEST
}

deploy_plugin() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Mock KMS Plugin Deployment${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  Image:  ${KMS_IMAGE}"
    echo -e "  Socket: ${SOCKET_PATH}"
    echo ""

    log_step "Checking prerequisites"
    command -v oc >/dev/null 2>&1 || { log_fail "oc is required"; exit 1; }
    command -v jq >/dev/null 2>&1 || { log_fail "jq is required"; exit 1; }

    if ! oc whoami >/dev/null 2>&1; then
        log_fail "Not logged in to OpenShift"
        exit 1
    fi
    log_pass "Logged in as: $(oc whoami)"

    log_step "Getting control plane nodes"
    local nodes
    nodes=$(get_control_plane_nodes)
    if [ -z "$nodes" ]; then
        log_fail "No control plane nodes found"
        exit 1
    fi
    local node_count
    node_count=$(echo "$nodes" | wc -l | tr -d ' ')
    log_pass "Found $node_count control plane node(s)"

    log_step "Creating namespace"
    oc create namespace openshift-kms-plugin 2>/dev/null || true
    oc label namespace openshift-kms-plugin \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        --overwrite 2>/dev/null || true
    log_pass "Namespace openshift-kms-plugin ready"

    log_step "Generating static pod manifest"
    local manifest
    manifest=$(generate_static_pod_manifest)
    local manifest_b64
    manifest_b64=$(echo "$manifest" | base64 | tr -d '\n')

    log_step "Deploying to control plane nodes"
    for node in $nodes; do
        log_info "Deploying to $node"
        oc debug "node/$node" -q -- chroot /host bash -c "
            mkdir -p /etc/kubernetes/manifests /var/run/kmsplugin
            echo '$manifest_b64' | base64 -d > ${MANIFEST_PATH}
            chmod 644 ${MANIFEST_PATH}
        " 2>&1 | grep -v "^$" || true

        local file_size
        file_size=$(oc debug "node/$node" -q -- chroot /host stat -c %s "${MANIFEST_PATH}" 2>/dev/null || echo "0")
        if [ "${file_size:-0}" -gt 100 ]; then
            log_pass "$node: manifest deployed (${file_size} bytes)"
        else
            log_warn "$node: manifest may not have been written correctly"
        fi
    done

    log_step "Waiting for static pods to appear"
    sleep 30

    local found=0
    for node in $nodes; do
        local node_short
        node_short=$(echo "$node" | cut -d'.' -f1)
        if oc get pods -n openshift-kms-plugin --no-headers 2>/dev/null | grep -q "$node_short"; then
            found=$((found + 1))
            log_pass "Pod running on $node_short"
        else
            log_warn "Pod not yet visible on $node_short (may take another 30-60s)"
        fi
    done

    echo ""
    if [ "$found" -gt 0 ]; then
        echo -e "${GREEN}Deployed $found mock KMS plugin pod(s)${NC}"
    else
        echo -e "${YELLOW}Pods not yet visible — wait 60s and check:${NC}"
        echo "  oc get pods -n openshift-kms-plugin -o wide"
    fi

    echo ""
    echo "Useful commands:"
    echo "  Status:      $(basename "$0") --status"
    echo "  Verify:      $(basename "$0") --verify"
    echo "  Remove:      $(basename "$0") --remove"
    echo "  Pod logs:    oc logs -n openshift-kms-plugin ${MANIFEST_NAME}-<node>"
}

remove_plugin() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Remove Mock KMS Plugin${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""

    local nodes
    nodes=$(get_control_plane_nodes)
    if [ -z "$nodes" ]; then
        log_fail "No control plane nodes found"
        exit 1
    fi

    for node in $nodes; do
        log_info "Removing from $node"
        oc debug "node/$node" -q -- chroot /host rm -f "${MANIFEST_PATH}" 2>&1 | grep -v "^$" || true
        log_pass "$node: manifest removed"
    done

    echo ""
    log_info "Waiting for pods to terminate..."
    sleep 15

    local remaining
    remaining=$(oc get pods -n openshift-kms-plugin --no-headers 2>/dev/null | grep "${MANIFEST_NAME}" | wc -l | tr -d ' ')
    if [ "${remaining:-0}" -eq 0 ]; then
        log_pass "All mock KMS plugin pods removed"
    else
        log_warn "$remaining pod(s) still terminating — they will disappear shortly"
    fi
}

verify_plugin() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Verify Mock KMS Plugin${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""

    log_step "Checking pods"
    local pods
    pods=$(oc get pods -n openshift-kms-plugin --no-headers 2>/dev/null | grep "${MANIFEST_NAME}" || true)
    if [ -z "$pods" ]; then
        log_fail "No mock KMS plugin pods found"
        echo "  Deploy first: $(basename "$0")"
        return 1
    fi

    local total running
    total=$(echo "$pods" | wc -l | tr -d ' ')
    running=$(echo "$pods" | grep -c "Running" || true)
    log_pass "$running/$total pod(s) running"
    echo "$pods" | sed 's/^/  /'
    echo ""

    log_step "Checking logs for successful startup"
    local first_pod
    first_pod=$(echo "$pods" | head -1 | awk '{print $1}')
    local logs
    logs=$(oc logs -n openshift-kms-plugin "$first_pod" --tail=10 2>/dev/null || true)

    if echo "$logs" | grep -q "KMS v2 plugin listening"; then
        log_pass "Plugin started successfully"
    elif echo "$logs" | grep -q "mock mode"; then
        log_pass "Plugin running in mock mode"
    else
        log_warn "Could not confirm startup from logs"
    fi

    if [ -n "$logs" ]; then
        log_info "Recent logs from $first_pod:"
        echo "$logs" | tail -5 | sed 's/^/    /'
    fi

    log_step "Checking KMS health via kube-apiserver"
    local kms_health
    kms_health=$(oc get --raw /readyz/kms-providers 2>/dev/null || echo "failed")
    if [ "$kms_health" = "ok" ]; then
        log_pass "kube-apiserver /readyz/kms-providers: ok"
    else
        log_warn "kube-apiserver /readyz/kms-providers: $kms_health (may still be rolling out)"
    fi

    log_step "Checking encryption status"
    local enc_type
    enc_type=$(oc get apiserver cluster -o jsonpath='{.spec.encryption.type}' 2>/dev/null || echo "none")
    log_info "Current encryption type: ${enc_type:-identity (default)}"

    if [ "$enc_type" = "KMS" ]; then
        log_pass "KMS encryption is enabled"
        local enc_status
        enc_status=$(oc get kubeapiserver cluster -o json 2>/dev/null \
            | jq -r '.status.conditions[] | select(.type | contains("Encrypt")) | "\(.type): \(.status) - \(.message // "ok")"' 2>/dev/null || true)
        if [ -n "$enc_status" ]; then
            log_info "Encryption conditions:"
            echo "$enc_status" | sed 's/^/    /'
        fi
    else
        log_info "KMS encryption not yet enabled. To enable:"
        echo "    $(basename "$0") --enable-encryption"
        echo "    # or manually:"
        echo "    oc patch apiserver cluster --type=merge -p '{\"spec\":{\"encryption\":{\"type\":\"KMS\"}}}'"
    fi
}

show_status() {
    echo -e "${BOLD}Mock KMS Plugin Status${NC}"
    echo ""
    oc get pods -n openshift-kms-plugin -o wide 2>/dev/null || echo "  No pods found in openshift-kms-plugin namespace"
    echo ""

    local enc_type
    enc_type=$(oc get apiserver cluster -o jsonpath='{.spec.encryption.type}' 2>/dev/null || echo "none")
    echo "Encryption type: ${enc_type:-identity (default)}"

    local fg
    fg=$(oc get featuregate cluster -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo "none")
    echo "FeatureGate:     ${fg:-Default}"
}

enable_encryption() {
    deploy_plugin

    echo ""
    log_step "Enabling TechPreviewNoUpgrade FeatureGate"
    local current_fg
    current_fg=$(oc get featuregate cluster -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo "")
    if [ "$current_fg" = "TechPreviewNoUpgrade" ]; then
        log_pass "TechPreviewNoUpgrade already enabled"
    else
        log_warn "This enables all tech preview features and prevents minor version upgrades"
        oc patch featuregate/cluster --type=merge -p '{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'
        log_pass "TechPreviewNoUpgrade FeatureGate applied"

        log_info "Waiting for cluster to stabilize..."
        oc adm wait-for-stable-cluster --timeout=30m || {
            log_warn "Timeout waiting for stable cluster — check: oc get co"
        }
    fi

    log_step "Enabling KMS encryption"
    oc patch apiserver cluster --type=merge -p '{"spec":{"encryption":{"type":"KMS"}}}'
    log_pass "KMS encryption patch applied"

    log_info "Waiting for cluster to stabilize after encryption change..."
    oc adm wait-for-stable-cluster --timeout=30m || {
        log_warn "Timeout waiting for stable cluster — check: oc get co"
    }

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Mock KMS plugin deployed and encryption enabled${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Verify with:"
    echo "  $(basename "$0") --verify"
}

# Main
case "$ACTION" in
    deploy)             deploy_plugin ;;
    remove)             remove_plugin ;;
    deploy-and-encrypt) enable_encryption ;;
    verify)             verify_plugin ;;
    status)             show_status ;;
esac
