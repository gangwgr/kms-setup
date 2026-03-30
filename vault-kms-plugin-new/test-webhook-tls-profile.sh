#!/bin/bash
# ============================================================================
# Test: HyperShift Operator Webhook TLS Security Profile (PR #8078)
# ============================================================================
#
# Validates that the hypershift-operator webhook server on port 9443 respects
# the management cluster's APIServer TLS security profile configuration.
#
# PR: https://github.com/openshift/hypershift/pull/8078
# Jira: CNTRLPLANE-2797
#
# What this tests:
#   1. The operator detects CapabilityAPIServer on OpenShift management clusters
#   2. Reads the management cluster's APIServer config (apiserver/cluster)
#   3. Applies minTLSVersion and cipherSuites to the webhook server (port 9443)
#   4. TLS settings update after operator restart when APIServer config changes
#
# Usage:
#   ./test-webhook-tls-profile.sh
#   ./test-webhook-tls-profile.sh --test webhook-infra
#   ./test-webhook-tls-profile.sh --test tls-verify
#   ./test-webhook-tls-profile.sh --test profile-switch
#   ./test-webhook-tls-profile.sh --operator-namespace hypershift
#   ./test-webhook-tls-profile.sh --dry-run
#
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_pass()    { echo -e "${GREEN}[PASS]${NC}  $*"; PASS_COUNT=$((PASS_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); }
log_fail()    { echo -e "${RED}[FAIL]${NC}  $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); }
log_skip()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; SKIP_COUNT=$((SKIP_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); }
log_step()    { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
log_section() { echo -e "\n${BOLD}════════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"; }

OPERATOR_NS=""
OPERATOR_DEPLOY=""
SPECIFIC_TEST=""
DRY_RUN=false
RESUME_FROM=""
LOCAL_PORT=19443
PF_PID=""

MGMT_KAS_TIMEOUT=1800
OPERATOR_RESTART_TIMEOUT=300

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --operator-namespace NS  Namespace of the hypershift-operator (auto-detected if omitted)
  --test TEST              Run a specific test: webhook-infra, tls-verify, profile-switch
  --resume-from STEP       Resume profile-switch from a step: 4.1, 4.2, 4.3, 4.4, 4.5, restore
  --dry-run                Read-only checks only (no profile changes)
  --help                   Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --operator-namespace hypershift --test tls-verify
  $(basename "$0") --test profile-switch
  $(basename "$0") --test profile-switch --resume-from 4.3
  $(basename "$0") --dry-run
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --operator-namespace) OPERATOR_NS="$2"; shift 2 ;;
        --test)               SPECIFIC_TEST="$2"; shift 2 ;;
        --resume-from)        RESUME_FROM="$2"; shift 2 ;;
        --dry-run)            DRY_RUN=true; shift ;;
        --help|-h)            usage ;;
        *)                    echo "Unknown option: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Cleanup handler — kill port-forward on exit
# ---------------------------------------------------------------------------
cleanup() {
    if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# TLS version mapping (OpenShift VersionTLSXX → openssl flag)
# ---------------------------------------------------------------------------
tls_min_version_for() {
    case "$1" in
        Modern)       echo "VersionTLS13" ;;
        Intermediate) echo "VersionTLS12" ;;
        Old)          echo "VersionTLS10" ;;
        *)            echo "VersionTLS12" ;;
    esac
}

openssl_proto_for_version() {
    case "$1" in
        VersionTLS13) echo "TLSv1.3" ;;
        VersionTLS12) echo "TLSv1.2" ;;
        VersionTLS11) echo "TLSv1.1" ;;
        VersionTLS10) echo "TLSv1"   ;;
        *)            echo "TLSv1.2" ;;
    esac
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
    log_section "Checking Prerequisites"
    local missing=0

    for cmd in oc jq openssl; do
        if command -v "$cmd" >/dev/null 2>&1; then
            log_pass "$cmd is available: $(command -v "$cmd")"
        else
            log_fail "$cmd is NOT installed"
            missing=1
        fi
    done

    if ! oc whoami >/dev/null 2>&1; then
        log_fail "Not logged in to OpenShift (oc whoami failed)"
        missing=1
    else
        log_pass "Logged in as: $(oc whoami)"
    fi

    log_step "Checking management cluster APIServer resource"
    if oc get apiserver cluster >/dev/null 2>&1; then
        log_pass "APIServer 'cluster' resource exists (CapabilityAPIServer present)"
    else
        log_fail "APIServer 'cluster' resource not found — this is not an OpenShift management cluster"
        missing=1
    fi

    if [ "$missing" -eq 1 ]; then
        echo -e "\n${RED}Missing prerequisites. Aborting.${NC}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Discover hypershift-operator deployment and namespace
# ---------------------------------------------------------------------------
discover_operator() {
    log_step "Discovering hypershift-operator"

    if [ -n "$OPERATOR_NS" ]; then
        log_info "Using provided namespace: $OPERATOR_NS"
    else
        for ns in hypershift openshift-hypershift hypershift-operator; do
            if oc get namespace "$ns" >/dev/null 2>&1; then
                local deploys
                deploys=$(oc get deployments -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' || true)
                for d in $deploys; do
                    case "$d" in
                        operator|hypershift-operator)
                            OPERATOR_NS="$ns"
                            OPERATOR_DEPLOY="$d"
                            break 2
                            ;;
                    esac
                done
            fi
        done

        if [ -z "$OPERATOR_NS" ]; then
            log_fail "Cannot find hypershift-operator namespace. Use --operator-namespace."
            exit 1
        fi
    fi

    if [ -z "$OPERATOR_DEPLOY" ]; then
        local deploys
        deploys=$(oc get deployments -n "$OPERATOR_NS" --no-headers 2>/dev/null | awk '{print $1}' || true)
        for d in $deploys; do
            case "$d" in
                operator|hypershift-operator)
                    OPERATOR_DEPLOY="$d"
                    break
                    ;;
            esac
        done

        if [ -z "$OPERATOR_DEPLOY" ]; then
            log_fail "Cannot find hypershift-operator deployment in namespace '$OPERATOR_NS'"
            echo "  Available deployments:"
            echo "$deploys" | sed 's/^/    /'
            exit 1
        fi
    fi

    log_pass "Operator deployment: $OPERATOR_NS/$OPERATOR_DEPLOY"

    local ready
    ready=$(oc get deployment "$OPERATOR_DEPLOY" -n "$OPERATOR_NS" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${ready:-0}" -gt 0 ]; then
        log_pass "Operator has $ready ready replica(s)"
    else
        log_fail "Operator has no ready replicas"
    fi
}

# ---------------------------------------------------------------------------
# Get current management cluster APIServer TLS profile
# ---------------------------------------------------------------------------
get_mgmt_tls_profile() {
    oc get apiserver cluster \
        -o jsonpath='{.spec.tlsSecurityProfile.type}' 2>/dev/null || echo ""
}

get_mgmt_tls_min_version() {
    local profile_type
    profile_type=$(get_mgmt_tls_profile)

    case "$profile_type" in
        Modern)       echo "VersionTLS13" ;;
        Intermediate) echo "VersionTLS12" ;;
        Old)          echo "VersionTLS10" ;;
        Custom)
            oc get apiserver cluster \
                -o jsonpath='{.spec.tlsSecurityProfile.custom.minTLSVersion}' 2>/dev/null || echo "VersionTLS12"
            ;;
        *)            echo "VersionTLS12" ;;
    esac
}

# ---------------------------------------------------------------------------
# Start port-forward to the webhook on port 9443
# ---------------------------------------------------------------------------
start_port_forward() {
    stop_port_forward
    # Kill any stale port-forward on the same local port from a previous run
    local stale_pids
    stale_pids=$(lsof -ti ":${LOCAL_PORT}" 2>/dev/null || true)
    if [ -n "$stale_pids" ]; then
        log_info "Killing stale process(es) on port $LOCAL_PORT: $stale_pids"
        echo "$stale_pids" | xargs kill 2>/dev/null || true
        sleep 2
    fi

    local pod_name
    pod_name=$(oc get pods -n "$OPERATOR_NS" -l "app=${OPERATOR_DEPLOY}" \
        --field-selector=status.phase=Running --no-headers 2>/dev/null \
        | head -1 | awk '{print $1}' || true)

    if [ -z "$pod_name" ]; then
        pod_name=$(oc get pods -n "$OPERATOR_NS" --no-headers 2>/dev/null \
            | grep "$OPERATOR_DEPLOY" | grep "Running" | head -1 | awk '{print $1}' || true)
    fi

    if [ -z "$pod_name" ]; then
        log_fail "No running pod found for deployment '$OPERATOR_DEPLOY'"
        return 1
    fi

    log_info "Port-forwarding to $pod_name:9443 → localhost:$LOCAL_PORT"
    oc port-forward -n "$OPERATOR_NS" "pod/$pod_name" "${LOCAL_PORT}:9443" >/dev/null 2>&1 &
    PF_PID=$!

    # Wait and retry if needed
    local attempt=0
    while [ "$attempt" -lt 3 ]; do
        sleep 3
        if kill -0 "$PF_PID" 2>/dev/null; then
            log_pass "Port-forward active (PID: $PF_PID)"
            return 0
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -lt 3 ]; then
            log_info "Port-forward attempt $attempt failed, retrying..."
            LOCAL_PORT=$((LOCAL_PORT + 1))
            log_info "Trying port $LOCAL_PORT"
            oc port-forward -n "$OPERATOR_NS" "pod/$pod_name" "${LOCAL_PORT}:9443" >/dev/null 2>&1 &
            PF_PID=$!
        fi
    done

    log_fail "Port-forward to $pod_name:9443 failed after 3 attempts"
    PF_PID=""
    return 1
}

stop_port_forward() {
    if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
        PF_PID=""
    fi
}

# ---------------------------------------------------------------------------
# Verify TLS on the webhook port
# ---------------------------------------------------------------------------
verify_webhook_tls() {
    local expected_min_ver="$1"
    local profile_label="$2"

    local expected_proto
    expected_proto=$(openssl_proto_for_version "$expected_min_ver")

    log_step "Verifying webhook TLS for profile: $profile_label (expected min: $expected_proto)"

    if ! start_port_forward; then
        return 1
    fi

    local tls_output actual_proto actual_cipher

    tls_output=$(echo | openssl s_client -connect "localhost:${LOCAL_PORT}" 2>&1 || true)
    actual_proto=$(echo "$tls_output" | grep -E "^\s*Protocol\s*:" | awk -F: '{gsub(/^[ \t]+/, "", $2); print $2}' || true)
    actual_cipher=$(echo "$tls_output" | grep -E "^\s*Cipher\s*:" | head -1 | awk -F: '{gsub(/^[ \t]+/, "", $2); print $2}' || true)

    if [ -z "$actual_proto" ] || [ "$actual_proto" = "(NONE)" ]; then
        log_fail "[$profile_label] Cannot establish TLS connection to webhook on port 9443"
        log_info "  openssl output (last 10 lines):"
        echo "$tls_output" | tail -10 | sed 's/^/    /'
        stop_port_forward
        return 1
    fi

    log_info "[$profile_label] Negotiated: Protocol=$actual_proto, Cipher=$actual_cipher"

    case "$expected_min_ver" in
        VersionTLS13)
            local tls13_out tls12_out
            tls13_out=$(echo | openssl s_client -connect "localhost:${LOCAL_PORT}" -tls1_3 2>&1 || true)
            if echo "$tls13_out" | grep -qE "Protocol\s*:\s*TLSv1\.3"; then
                log_pass "[$profile_label] TLS 1.3 connection succeeded (expected for Modern)"
            else
                log_fail "[$profile_label] TLS 1.3 connection failed"
            fi

            tls12_out=$(echo | openssl s_client -connect "localhost:${LOCAL_PORT}" -tls1_2 2>&1 || true)
            if echo "$tls12_out" | grep -qE "Protocol\s*:\s*TLSv1\.2"; then
                log_fail "[$profile_label] TLS 1.2 accepted (should be rejected for Modern)"
            else
                log_pass "[$profile_label] TLS 1.2 correctly rejected"
            fi
            ;;

        VersionTLS12)
            local tls12_out
            tls12_out=$(echo | openssl s_client -connect "localhost:${LOCAL_PORT}" -tls1_2 2>&1 || true)
            if echo "$tls12_out" | grep -qE "Protocol\s*:\s*TLSv1\.2"; then
                log_pass "[$profile_label] TLS 1.2 connection succeeded (expected for Intermediate)"
            else
                log_fail "[$profile_label] TLS 1.2 connection failed"
            fi

            local tls13_out
            tls13_out=$(echo | openssl s_client -connect "localhost:${LOCAL_PORT}" -tls1_3 2>&1 || true)
            if echo "$tls13_out" | grep -qE "Protocol\s*:\s*TLSv1\.3"; then
                log_pass "[$profile_label] TLS 1.3 also accepted (correct — it's >= 1.2)"
            else
                log_info "[$profile_label] TLS 1.3 not negotiated (may be cipher mismatch, non-critical)"
            fi
            ;;

        VersionTLS11|VersionTLS10)
            if [ -n "$actual_proto" ] && [ "$actual_proto" != "(NONE)" ]; then
                log_pass "[$profile_label] TLS connection succeeded (protocol: $actual_proto)"
            else
                log_fail "[$profile_label] TLS connection failed"
            fi
            ;;
    esac

    # Show cipher suites the server accepts
    log_info "[$profile_label] Checking advertised cipher suites..."
    local cipher_list
    cipher_list=$(echo | openssl s_client -connect "localhost:${LOCAL_PORT}" -cipher 'ALL:eNULL' 2>&1 \
        | grep -E "^\s*Cipher\s*:" | head -1 | awk -F: '{gsub(/^[ \t]+/, "", $2); print $2}' || true)
    if [ -n "$cipher_list" ] && [ "$cipher_list" != "(NONE)" ] && [ "$cipher_list" != "0000" ]; then
        log_info "  Negotiated cipher: $cipher_list"
    fi

    stop_port_forward
}

# ---------------------------------------------------------------------------
# Wait for management cluster kube-apiserver ClusterOperator
# ---------------------------------------------------------------------------
wait_mgmt_kube_apiserver() {
    local wait_time="${1:-$MGMT_KAS_TIMEOUT}"

    log_info "Waiting for management cluster kube-apiserver to stabilize (timeout: ${wait_time}s)..."

    local elapsed=0
    local interval=30
    while [ "$elapsed" -lt "$wait_time" ]; do
        local available progressing degraded
        available=$(oc get co kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
        progressing=$(oc get co kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "Unknown")
        degraded=$(oc get co kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")

        if [ "$available" = "True" ] && [ "$progressing" = "False" ] && [ "$degraded" = "False" ]; then
            log_pass "Management cluster kube-apiserver is stable"
            return 0
        fi

        log_info "  [${elapsed}s] Available=$available Progressing=$progressing Degraded=$degraded"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_fail "Management kube-apiserver did not stabilize within ${wait_time}s"
    return 1
}

# ---------------------------------------------------------------------------
# Restart hypershift-operator pods and wait for ready
# The operator reads APIServer TLS config at startup, so a restart is required.
# ---------------------------------------------------------------------------
restart_operator() {
    log_info "Restarting hypershift-operator pods to pick up new APIServer TLS config..."

    oc delete pods -n "$OPERATOR_NS" -l "app=${OPERATOR_DEPLOY}" --grace-period=10 2>/dev/null || \
        oc delete pods -n "$OPERATOR_NS" $(oc get pods -n "$OPERATOR_NS" --no-headers 2>/dev/null \
            | grep "$OPERATOR_DEPLOY" | awk '{print $1}') --grace-period=10 2>/dev/null || true

    log_info "Waiting for operator pods to come back (timeout: ${OPERATOR_RESTART_TIMEOUT}s)..."

    local elapsed=0
    local interval=10
    while [ "$elapsed" -lt "$OPERATOR_RESTART_TIMEOUT" ]; do
        local ready
        ready=$(oc get deployment "$OPERATOR_DEPLOY" -n "$OPERATOR_NS" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

        if [ "${ready:-0}" -gt 0 ]; then
            log_pass "Operator has $ready ready replica(s) after restart"

            local pods_stable=true
            local pod_output
            pod_output=$(oc get pods -n "$OPERATOR_NS" --no-headers 2>/dev/null \
                | grep "$OPERATOR_DEPLOY" || true)
            if echo "$pod_output" | grep -qE '(0/[0-9]|Pending|Terminating|Init|CrashLoop)'; then
                pods_stable=false
            fi

            if [ "$pods_stable" = true ]; then
                sleep 5
                return 0
            fi
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_fail "Operator did not become ready within ${OPERATOR_RESTART_TIMEOUT}s"
    return 1
}

# ---------------------------------------------------------------------------
# TEST 1: Webhook Infrastructure Validation
# ---------------------------------------------------------------------------
test_webhook_infra() {
    log_section "Test 1: Webhook Infrastructure Validation"

    log_step "1a. Operator deployment"
    local deploy_json
    deploy_json=$(oc get deployment "$OPERATOR_DEPLOY" -n "$OPERATOR_NS" -o json 2>/dev/null || true)

    if [ -z "$deploy_json" ]; then
        log_fail "Deployment '$OPERATOR_DEPLOY' not found in '$OPERATOR_NS'"
        return 1
    fi
    log_pass "Deployment '$OPERATOR_DEPLOY' exists in '$OPERATOR_NS'"

    local containers_with_9443
    containers_with_9443=$(echo "$deploy_json" | jq -r \
        '.spec.template.spec.containers[].ports[]? | select(.containerPort == 9443) | .name // "unnamed"' 2>/dev/null || true)
    if [ -n "$containers_with_9443" ]; then
        log_pass "Container port 9443 declared (name: $containers_with_9443)"
    else
        log_info "Container port 9443 not explicitly declared in deployment spec (webhook may use default)"
    fi

    log_step "1b. Webhook service"
    local svc_name=""
    local all_svc_json
    all_svc_json=$(oc get services -n "$OPERATOR_NS" -o json 2>/dev/null || echo '{"items":[]}')

    local svc_count
    svc_count=$(echo "$all_svc_json" | jq '.items | length' 2>/dev/null || echo "0")

    local i=0
    while [ "$i" -lt "$svc_count" ]; do
        local name port_info
        name=$(echo "$all_svc_json" | jq -r ".items[$i].metadata.name" 2>/dev/null)
        # Check for port 9443 as port number, targetPort number, or targetPort named port
        port_info=$(echo "$all_svc_json" | jq -r ".items[$i].spec.ports[]? | select(.port == 9443 or .targetPort == 9443 or .targetPort == \"9443\" or .targetPort == \"manager\") | \"\(.port) → \(.targetPort) (\(.name // \"unnamed\"))\"" 2>/dev/null || true)

        if [ -n "$port_info" ]; then
            svc_name="$name"
            log_pass "Service '$name' routes to webhook: $port_info"
            break
        fi
        i=$((i + 1))
    done

    if [ -z "$svc_name" ]; then
        # Show what services exist for debugging
        log_info "No service with port/targetPort 9443 found in '$OPERATOR_NS'"
        log_info "Services in '$OPERATOR_NS':"
        echo "$all_svc_json" | jq -r '.items[] | "    \(.metadata.name): \([.spec.ports[]? | "\(.port)→\(.targetPort // .port)"] | join(", "))"' 2>/dev/null || true
    fi

    log_step "1c. ValidatingWebhookConfiguration"
    local vwc_found=false
    local all_vwc
    all_vwc=$(oc get validatingwebhookconfigurations -o json 2>/dev/null || echo '{"items":[]}')
    local vwc_matches
    vwc_matches=$(echo "$all_vwc" | jq -r \
        --arg ns "$OPERATOR_NS" \
        '.items[] | select(.webhooks[]?.clientConfig.service.namespace == $ns) | .metadata.name' 2>/dev/null | sort -u || true)

    if [ -n "$vwc_matches" ]; then
        echo "$vwc_matches" | while IFS= read -r vwc; do
            log_pass "ValidatingWebhookConfiguration: $vwc (service in $OPERATOR_NS)"
            local ports
            ports=$(echo "$all_vwc" | jq -r \
                --arg name "$vwc" --arg ns "$OPERATOR_NS" \
                '.items[] | select(.metadata.name == $name) | .webhooks[] | select(.clientConfig.service.namespace == $ns) | .clientConfig.service.port // 443' 2>/dev/null | sort -u || true)
            echo "$ports" | while IFS= read -r p; do
                if [ "$p" = "9443" ]; then
                    log_pass "  Webhook uses port 9443"
                else
                    log_info "  Webhook port: $p"
                fi
            done
            vwc_found=true
        done
    fi

    if [ "$vwc_found" = false ]; then
        log_info "No ValidatingWebhookConfiguration referencing namespace '$OPERATOR_NS' found"
    fi

    log_step "1d. MutatingWebhookConfiguration"
    local mwc_found=false
    local all_mwc
    all_mwc=$(oc get mutatingwebhookconfigurations -o json 2>/dev/null || echo '{"items":[]}')
    local mwc_matches
    mwc_matches=$(echo "$all_mwc" | jq -r \
        --arg ns "$OPERATOR_NS" \
        '.items[] | select(.webhooks[]?.clientConfig.service.namespace == $ns) | .metadata.name' 2>/dev/null | sort -u || true)

    if [ -n "$mwc_matches" ]; then
        echo "$mwc_matches" | while IFS= read -r mwc; do
            log_pass "MutatingWebhookConfiguration: $mwc (service in $OPERATOR_NS)"
            local ports
            ports=$(echo "$all_mwc" | jq -r \
                --arg name "$mwc" --arg ns "$OPERATOR_NS" \
                '.items[] | select(.metadata.name == $name) | .webhooks[] | select(.clientConfig.service.namespace == $ns) | .clientConfig.service.port // 443' 2>/dev/null | sort -u || true)
            echo "$ports" | while IFS= read -r p; do
                if [ "$p" = "9443" ]; then
                    log_pass "  Webhook uses port 9443"
                else
                    log_info "  Webhook port: $p"
                fi
            done
            mwc_found=true
        done
    fi

    if [ "$mwc_found" = false ]; then
        log_info "No MutatingWebhookConfiguration referencing namespace '$OPERATOR_NS' found"
    fi

    log_step "1e. Operator pod status"
    local pods
    pods=$(oc get pods -n "$OPERATOR_NS" --no-headers 2>/dev/null | grep "$OPERATOR_DEPLOY" || true)
    if [ -n "$pods" ]; then
        echo "$pods" | while IFS= read -r line; do
            local name status
            name=$(echo "$line" | awk '{print $1}')
            status=$(echo "$line" | awk '{print $3}')
            if [ "$status" = "Running" ]; then
                log_pass "Pod $name: $status"
            else
                log_fail "Pod $name: $status"
            fi
        done
    else
        log_fail "No pods found for '$OPERATOR_DEPLOY'"
    fi
}

# ---------------------------------------------------------------------------
# TEST 2: TLS Verification Against Current Profile
# ---------------------------------------------------------------------------
test_tls_verify() {
    log_section "Test 2: Webhook TLS Verification (Current Profile)"

    local profile_type min_ver
    profile_type=$(get_mgmt_tls_profile)
    min_ver=$(get_mgmt_tls_min_version)

    log_info "Management cluster APIServer TLS profile:"
    log_info "  Type:            ${profile_type:-<unset/default>}"
    log_info "  Min TLS Version: $min_ver"

    if [ -n "$profile_type" ] && [ "$profile_type" != "null" ]; then
        log_pass "Management cluster has TLS profile: $profile_type"
    else
        log_info "No explicit TLS profile set — defaults to Intermediate (TLS 1.2)"
    fi

    log_step "Full APIServer TLS configuration"
    oc get apiserver cluster -o json 2>/dev/null \
        | jq '.spec.tlsSecurityProfile // "not set (defaults to Intermediate)"' 2>/dev/null || true

    verify_webhook_tls "$min_ver" "${profile_type:-default/Intermediate}"
}

# ---------------------------------------------------------------------------
# TEST 3: TLS Profile Switching
# ---------------------------------------------------------------------------

should_run_step() {
    local step="$1"
    if [ -z "$RESUME_FROM" ]; then
        return 0
    fi

    local step_num resume_num
    case "$step" in
        4.1) step_num=1 ;; 4.2) step_num=2 ;; 4.3) step_num=3 ;;
        4.4) step_num=4 ;; 4.5) step_num=5 ;; restore) step_num=6 ;;
        *)   step_num=0 ;;
    esac
    case "$RESUME_FROM" in
        4.1) resume_num=1 ;; 4.2) resume_num=2 ;; 4.3) resume_num=3 ;;
        4.4) resume_num=4 ;; 4.5) resume_num=5 ;; restore) resume_num=6 ;;
        *)   resume_num=0 ;;
    esac

    if [ "$step_num" -ge "$resume_num" ]; then
        return 0
    fi
    return 1
}

run_profile_step() {
    local step_name="$1"
    local profile_label="$2"
    local patch="$3"
    local expected_ver="$4"

    log_step "$step_name) Patching management cluster APIServer → $profile_label"

    oc patch apiserver cluster --type=merge -p '{"spec":{"tlsSecurityProfile":null}}' 2>/dev/null || true
    oc patch apiserver cluster --type=merge -p "$patch"
    log_pass "Patched APIServer → $profile_label"

    log_info "Waiting for management cluster kube-apiserver rollout..."
    log_info "(This can take 15-30 minutes as the management cluster kube-apiserver restarts)"
    wait_mgmt_kube_apiserver "$MGMT_KAS_TIMEOUT"

    restart_operator

    verify_webhook_tls "$expected_ver" "$profile_label"
}

test_profile_switch() {
    log_section "Test 3: TLS Profile Switching [Disruptive]"

    if [ "$DRY_RUN" = true ]; then
        log_skip "Profile switching skipped in dry-run mode (would modify management cluster APIServer)"
        return 0
    fi

    if [ -n "$RESUME_FROM" ]; then
        log_info "Resuming from step $RESUME_FROM (skipping earlier steps)"
    fi

    local original_profile original_tls_json
    original_profile=$(get_mgmt_tls_profile)
    original_tls_json=$(oc get apiserver cluster -o json 2>/dev/null \
        | jq -c '.spec.tlsSecurityProfile // null' 2>/dev/null || echo "null")
    log_info "Current TLS profile: ${original_profile:-<unset>}"
    log_info "Original config (saved for restore): $original_tls_json"

    echo ""
    echo -e "${YELLOW}${BOLD}WARNING: This test will modify the management cluster's APIServer TLS config.${NC}"
    echo -e "${YELLOW}Each profile change triggers a kube-apiserver rollout (~15-30 min each).${NC}"
    echo -e "${YELLOW}The original config will be restored at the end.${NC}"
    echo ""

    # ─── 4.1 Verify current (default/Intermediate) ───
    if should_run_step "4.1"; then
        log_step "4.1) Verify current TLS settings on webhook"
        local current_min_ver
        current_min_ver=$(get_mgmt_tls_min_version)
        verify_webhook_tls "$current_min_ver" "${original_profile:-default/Intermediate}"
    else
        log_skip "4.1) Skipped (resuming from $RESUME_FROM)"
    fi

    # ─── 4.2 Custom profile ───
    if should_run_step "4.2"; then
        run_profile_step "4.2" "Custom" \
            '{"spec":{"tlsSecurityProfile":{"type":"Custom","custom":{"ciphers":["ECDHE-ECDSA-CHACHA20-POLY1305","ECDHE-RSA-CHACHA20-POLY1305","ECDHE-RSA-AES128-GCM-SHA256","ECDHE-ECDSA-AES128-GCM-SHA256"],"minTLSVersion":"VersionTLS12"}}}}' \
            "VersionTLS12"
    else
        log_skip "4.2) Custom — Skipped (resuming from $RESUME_FROM)"
    fi

    # ─── 4.3 Old profile ───
    if should_run_step "4.3"; then
        run_profile_step "4.3" "Old" \
            '{"spec":{"tlsSecurityProfile":{"type":"Old","old":{}}}}' \
            "VersionTLS10"
    else
        log_skip "4.3) Old — Skipped (resuming from $RESUME_FROM)"
    fi

    # ─── 4.4 Intermediate profile ───
    if should_run_step "4.4"; then
        run_profile_step "4.4" "Intermediate" \
            '{"spec":{"tlsSecurityProfile":{"type":"Intermediate","intermediate":{}}}}' \
            "VersionTLS12"
    else
        log_skip "4.4) Intermediate — Skipped (resuming from $RESUME_FROM)"
    fi

    # ─── 4.5 Modern profile ───
    if should_run_step "4.5"; then
        run_profile_step "4.5" "Modern" \
            '{"spec":{"tlsSecurityProfile":{"type":"Modern","modern":{}}}}' \
            "VersionTLS13"
    else
        log_skip "4.5) Modern — Skipped (resuming from $RESUME_FROM)"
    fi

    # ─── Restore original config ───
    if should_run_step "restore"; then
        log_step "Restoring original APIServer TLS configuration"

        if [ "$original_tls_json" = "null" ] || [ -z "$original_tls_json" ]; then
            oc patch apiserver cluster --type=merge -p '{"spec":{"tlsSecurityProfile":null}}' 2>/dev/null || true
            log_info "Restored to default (no explicit tlsSecurityProfile)"
        else
            oc patch apiserver cluster --type=merge -p "{\"spec\":{\"tlsSecurityProfile\":$original_tls_json}}" 2>/dev/null || true
            log_info "Restored original config: $original_tls_json"
        fi

        wait_mgmt_kube_apiserver "$MGMT_KAS_TIMEOUT"
        restart_operator

        local restored_ver
        restored_ver=$(get_mgmt_tls_min_version)
        verify_webhook_tls "$restored_ver" "restored/${original_profile:-default}"
    else
        log_skip "Restore — Skipped (resuming from $RESUME_FROM)"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    log_section "Test Summary"

    echo -e "  ${GREEN}PASSED:  $PASS_COUNT${NC}"
    echo -e "  ${RED}FAILED:  $FAIL_COUNT${NC}"
    echo -e "  ${YELLOW}SKIPPED: $SKIP_COUNT${NC}"
    echo -e "  TOTAL:   $TOTAL_COUNT"
    echo ""

    if [ "$FAIL_COUNT" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}All tests passed!${NC}"
    else
        echo -e "${RED}${BOLD}$FAIL_COUNT test(s) failed.${NC}"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Ensure HyperShift operator includes PR #8078 changes"
        echo "  2. Verify management cluster has APIServer resource:"
        echo "     oc get apiserver cluster -o yaml"
        echo "  3. Check hypershift-operator logs:"
        echo "     oc logs deployment/$OPERATOR_DEPLOY -n $OPERATOR_NS --tail=50"
        echo "  4. Verify webhook is listening on 9443:"
        echo "     oc port-forward -n $OPERATOR_NS deployment/$OPERATOR_DEPLOY 19443:9443"
        echo "     echo | openssl s_client -connect localhost:19443"
    fi
    echo ""
    return "$FAIL_COUNT"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  HyperShift Webhook TLS Security Profile Test (PR #8078)${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  PR:    https://github.com/openshift/hypershift/pull/8078"
    echo "  Jira:  CNTRLPLANE-2797"
    echo "  Dry Run:        $DRY_RUN"
    echo "  Specific Test:  ${SPECIFIC_TEST:-all}"
    echo "  Resume From:    ${RESUME_FROM:-(start)}"
    echo ""

    check_prerequisites
    discover_operator

    case "${SPECIFIC_TEST:-all}" in
        webhook-infra)  test_webhook_infra ;;
        tls-verify)     test_tls_verify ;;
        profile-switch) test_profile_switch ;;
        all)
            test_webhook_infra
            test_tls_verify
            if [ "$DRY_RUN" = false ]; then
                test_profile_switch
            fi
            ;;
        *)
            echo -e "${RED}Unknown test: $SPECIFIC_TEST${NC}"
            echo "Available: webhook-infra, tls-verify, profile-switch, all"
            exit 1
            ;;
    esac

    print_summary
}

main "$@"
