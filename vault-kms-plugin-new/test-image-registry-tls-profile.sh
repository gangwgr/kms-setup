#!/bin/bash
# ============================================================================
# Test: Image Registry Operator TLS Security Profile (HyperShift PR #8011)
# ============================================================================
#
# Validates that the cluster-image-registry-operator correctly receives and
# applies TLS security profile configuration from the HostedCluster resource.
#
# PR: https://github.com/openshift/hypershift/pull/8011
# Jira: IR-350
#
# Pattern: openshift-tests-private/test/extended/apiserverauth/apiserver_hypershift.go
#
# Usage:
#   ./test-image-registry-tls-profile.sh --hosted-cluster <name> --namespace <ns>
#   ./test-image-registry-tls-profile.sh --hosted-cluster <name> --namespace <ns> --test configmap
#   ./test-image-registry-tls-profile.sh --hosted-cluster <name> --namespace <ns> --test deployment
#   ./test-image-registry-tls-profile.sh --hosted-cluster <name> --namespace <ns> --test profile-switch
#   ./test-image-registry-tls-profile.sh --hosted-cluster <name> --namespace <ns> --dry-run
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

HOSTED_CLUSTER=""
HC_NAMESPACE=""
SPECIFIC_TEST=""
DRY_RUN=false
CONTROL_PLANE_NS=""

CONFIGMAP_NAME="image-registry-controller-config"
DEPLOYMENT_NAME="cluster-image-registry-operator"
CONFIG_KEY="config.yaml"
RESUME_FROM=""

DEFAULT_RESTORE_PATCH='{"spec": {"configuration": {"apiServer": null}}}'

tls_min_version_for() {
    case "$1" in
        Modern)       echo "VersionTLS13" ;;
        Intermediate) echo "VersionTLS12" ;;
        Old)          echo "VersionTLS10" ;;
        *)            echo "unknown" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --hosted-cluster NAME    Name of the HostedCluster resource
  --namespace NS           Namespace of the HostedCluster (management cluster)

Options:
  --test TEST              Run a specific test: configmap, deployment, profile-switch
  --resume-from STEP       Resume profile-switch from a step: 3.1, 3.2, 3.3, 3.4, 3.5, restore
  --dry-run                Read-only checks only (no profile changes)
  --help                   Show this help

Examples:
  $(basename "$0") --hosted-cluster hypershift-ci-372189 --namespace clusters
  $(basename "$0") --hosted-cluster hypershift-ci-372189 --namespace clusters --test configmap
  $(basename "$0") --hosted-cluster hypershift-ci-372189 --namespace clusters --test profile-switch --resume-from 3.3
  $(basename "$0") --hosted-cluster hypershift-ci-372189 --namespace clusters --dry-run
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --hosted-cluster)  HOSTED_CLUSTER="$2"; shift 2 ;;
        --namespace)       HC_NAMESPACE="$2"; shift 2 ;;
        --test)            SPECIFIC_TEST="$2"; shift 2 ;;
        --resume-from)     RESUME_FROM="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --help|-h)         usage ;;
        *)                 echo "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$HOSTED_CLUSTER" ] || [ -z "$HC_NAMESPACE" ]; then
    echo -e "${RED}Error: --hosted-cluster and --namespace are required${NC}"
    usage
fi

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
    log_section "Checking Prerequisites"
    local missing=0

    for cmd in oc jq python3; do
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

    if [ "$missing" -eq 1 ]; then
        echo -e "\n${RED}Missing prerequisites. Aborting.${NC}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Discover control plane namespace
# ---------------------------------------------------------------------------
discover_control_plane_ns() {
    log_step "Discovering control plane namespace"
    CONTROL_PLANE_NS="${HC_NAMESPACE}-${HOSTED_CLUSTER}"

    if oc get namespace "$CONTROL_PLANE_NS" >/dev/null 2>&1; then
        log_pass "Control plane namespace: $CONTROL_PLANE_NS"
    else
        log_fail "Control plane namespace '$CONTROL_PLANE_NS' not found"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Wait for deployment rollout (polls until no Pending/Terminating/Init pods)
# Mirrors waitApiserverRestartOfHypershift from apiserver_util.go
# ---------------------------------------------------------------------------
wait_pod_restart() {
    local app_label="$1"
    local ns="$2"
    local wait_time="${3:-480}"

    log_info "Waiting for $app_label pods to stabilize (timeout: ${wait_time}s)..."

    local elapsed=0
    local interval=10
    while [ "$elapsed" -lt "$wait_time" ]; do
        local pod_output
        pod_output=$(oc get pods -l "app=$app_label" --no-headers -n "$ns" 2>/dev/null || true)

        if echo "$pod_output" | grep -qE '(0/[0-9]|Pending|Terminating|Init)'; then
            log_info "  $app_label is restarting..."
            sleep "$interval"
            elapsed=$((elapsed + interval))
            continue
        fi

        # Triple recheck for stability (same as Go test)
        local stable=true
        local recheck
        for recheck in 1 2 3; do
            sleep 10
            elapsed=$((elapsed + 10))
            pod_output=$(oc get pods -l "app=$app_label" --no-headers -n "$ns" 2>/dev/null || true)
            if echo "$pod_output" | grep -qE '(0/[0-9]|Pending|Terminating|Init)'; then
                stable=false
                break
            fi
        done

        if [ "$stable" = true ]; then
            log_pass "$app_label pods are stable"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_fail "$app_label did not stabilize within ${wait_time}s"
    return 1
}

# ---------------------------------------------------------------------------
# Wait for image-registry ConfigMap to reflect expected minTLSVersion.
# Polls every 15s since control-plane-operator reconciliation can be slow.
# ---------------------------------------------------------------------------
wait_image_registry_rollout() {
    local ns="$1"
    local wait_time="${2:-300}"
    local expected_ver="${3:-}"

    log_info "Waiting for $DEPLOYMENT_NAME reconciliation (timeout: ${wait_time}s)..."

    if [ -n "$expected_ver" ]; then
        local elapsed=0
        while [ "$elapsed" -lt "$wait_time" ]; do
            local cm_content
            cm_content=$(oc get configmap "$CONFIGMAP_NAME" -n "$ns" -o json 2>/dev/null \
                | jq -r ".data[\"$CONFIG_KEY\"] // empty" 2>/dev/null || true)

            if echo "$cm_content" | grep -q "$expected_ver"; then
                log_pass "ConfigMap updated: found $expected_ver (after ${elapsed}s)"
                return 0
            fi

            log_info "  [${elapsed}s] Waiting for $expected_ver in ConfigMap..."
            sleep 15
            elapsed=$((elapsed + 15))
        done

        log_fail "ConfigMap did not reflect $expected_ver within ${wait_time}s"
        return 1
    fi

    # Fallback: just wait for rollout
    local rollout_status
    rollout_status=$(oc rollout status "deployment/$DEPLOYMENT_NAME" \
        -n "$ns" --timeout="${wait_time}s" 2>&1 || true)

    if echo "$rollout_status" | grep -qi "successfully rolled out"; then
        log_pass "$DEPLOYMENT_NAME rollout complete"
    else
        log_info "  Rollout status: $rollout_status"
        wait_pod_restart "$DEPLOYMENT_NAME" "$ns" "$wait_time"
    fi
}

# ---------------------------------------------------------------------------
# Extract cipherSuites + minTLSVersion from image-registry ConfigMap
# Returns: '["cipher1","cipher2",...] VersionTLSXX' or empty
# ---------------------------------------------------------------------------
get_image_registry_cipher_info() {
    local ns="$1"

    local config_data
    config_data=$(oc get configmap "$CONFIGMAP_NAME" -n "$ns" \
        -o json 2>/dev/null | jq -r ".data[\"$CONFIG_KEY\"] // empty" 2>/dev/null || true)

    if [ -z "$config_data" ]; then
        echo ""
        return
    fi

    python3 -c "
import sys, yaml, json
data = yaml.safe_load(sys.stdin)
si = data.get('servingInfo', {})
ciphers = si.get('cipherSuites', [])
min_ver = si.get('minTLSVersion', '')
print(json.dumps(ciphers), min_ver)
" <<< "$config_data" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Verify image-registry ciphers match expected values
# ---------------------------------------------------------------------------
verify_image_registry_ciphers() {
    local expected_min_ver="$1"
    local expected_has_ciphers="$2"  # "yes" or "no"
    local ns="$3"
    local profile_name="$4"

    local ir_config
    ir_config=$(oc get configmap "$CONFIGMAP_NAME" -n "$ns" \
        -o json 2>/dev/null | jq -r ".data[\"$CONFIG_KEY\"] // empty" 2>/dev/null || true)

    if [ -z "$ir_config" ]; then
        log_fail "[$profile_name] image-registry ConfigMap '$CONFIGMAP_NAME' has no $CONFIG_KEY"
        return 1
    fi

    # Extract servingInfo fields
    local actual_min_ver actual_bind actual_cipher_count actual_ciphers
    eval "$(python3 -c "
import sys, yaml, json
data = yaml.safe_load(sys.stdin)
si = data.get('servingInfo', {})
print('actual_min_ver=\"%s\"' % si.get('minTLSVersion', 'NOT_SET'))
print('actual_bind=\"%s\"' % si.get('bindAddress', 'NOT_SET'))
ciphers = si.get('cipherSuites', [])
print('actual_cipher_count=\"%d\"' % len(ciphers))
print('actual_ciphers=\"%s\"' % json.dumps(ciphers))
" <<< "$ir_config" 2>/dev/null)"

    # Check bindAddress
    if [ "$actual_bind" = ":60000" ]; then
        log_pass "[$profile_name] image-registry bindAddress: :60000"
    else
        log_fail "[$profile_name] image-registry bindAddress: $actual_bind (expected :60000)"
    fi

    # Check minTLSVersion
    if [ "$actual_min_ver" = "$expected_min_ver" ]; then
        log_pass "[$profile_name] image-registry minTLSVersion: $actual_min_ver"
    else
        log_fail "[$profile_name] image-registry minTLSVersion: $actual_min_ver (expected $expected_min_ver)"
    fi

    # Check cipherSuites
    if [ "$expected_has_ciphers" = "yes" ]; then
        if [ "$actual_cipher_count" -gt 0 ] 2>/dev/null; then
            log_pass "[$profile_name] image-registry has $actual_cipher_count cipher suites"
            log_info "  Ciphers: $actual_ciphers"
        else
            log_fail "[$profile_name] image-registry has no cipher suites (expected some for $profile_name)"
        fi
    else
        if [ "$actual_cipher_count" -eq 0 ] 2>/dev/null || [ "$actual_cipher_count" = "0" ]; then
            log_pass "[$profile_name] image-registry has no cipher suites (correct for Modern — TLS 1.3)"
        else
            log_info "[$profile_name] image-registry has $actual_cipher_count cipher suites"
        fi
    fi

    # Print full config for reference
    log_info "  Full servingInfo:"
    echo "$ir_config" | grep -A 20 "servingInfo" | head -20 | sed 's/^/    /'
}

# ---------------------------------------------------------------------------
# Get current TLS profile
# ---------------------------------------------------------------------------
get_current_tls_profile() {
    local profile
    profile=$(oc get hostedcluster "$HOSTED_CLUSTER" -n "$HC_NAMESPACE" \
        -o jsonpath='{.spec.configuration.apiServer.tlsSecurityProfile.type}' 2>/dev/null || true)
    echo "${profile:-<unset>}"
}

# ---------------------------------------------------------------------------
# Get observedGeneration for KubeAPIServerAvailable
# ---------------------------------------------------------------------------
get_observed_generation() {
    oc get hostedcluster "$HOSTED_CLUSTER" -n "$HC_NAMESPACE" \
        -o 'jsonpath={.status.conditions[?(@.type=="KubeAPIServerAvailable")].observedGeneration}' 2>/dev/null || echo "0"
}

# ---------------------------------------------------------------------------
# TEST 1: ConfigMap Validation
# ---------------------------------------------------------------------------
test_configmap() {
    log_section "Test 1: Image Registry ConfigMap Validation"
    log_info "Checking ConfigMap '$CONFIGMAP_NAME' in namespace '$CONTROL_PLANE_NS'"

    log_step "1a. ConfigMap existence"
    if ! oc get configmap "$CONFIGMAP_NAME" -n "$CONTROL_PLANE_NS" >/dev/null 2>&1; then
        log_fail "ConfigMap '$CONFIGMAP_NAME' does not exist in '$CONTROL_PLANE_NS'"
        echo "  This ConfigMap should be created by the control-plane-operator."
        echo "  Verify the HyperShift operator includes PR #8011 changes."
        return 1
    fi
    log_pass "ConfigMap '$CONFIGMAP_NAME' exists"

    log_step "1b. config.yaml key present"
    local config_data
    config_data=$(oc get configmap "$CONFIGMAP_NAME" -n "$CONTROL_PLANE_NS" \
        -o json 2>/dev/null | jq -r ".data[\"$CONFIG_KEY\"] // empty" 2>/dev/null || true)

    if [ -z "$config_data" ]; then
        log_fail "ConfigMap has no '$CONFIG_KEY' key"
        echo "  Available keys:"
        oc get configmap "$CONFIGMAP_NAME" -n "$CONTROL_PLANE_NS" -o json | jq -r '.data | keys[]' 2>/dev/null || true
        return 1
    fi
    log_pass "ConfigMap contains '$CONFIG_KEY' key"

    log_step "1c. Verify image-registry TLS settings"
    local current_profile
    current_profile=$(get_current_tls_profile)
    log_info "Current HostedCluster TLS profile: $current_profile"

    local expected_min_ver="VersionTLS12"
    local expected_has_ciphers="yes"
    if [ "$current_profile" != "<unset>" ]; then
        expected_min_ver=$(tls_min_version_for "$current_profile")
        if [ "$current_profile" = "Modern" ]; then
            expected_has_ciphers="no"
        fi
    fi

    verify_image_registry_ciphers "$expected_min_ver" "$expected_has_ciphers" "$CONTROL_PLANE_NS" "${current_profile:-default}"
}

# ---------------------------------------------------------------------------
# TEST 2: Deployment Validation
# ---------------------------------------------------------------------------
test_deployment() {
    log_section "Test 2: Image Registry Deployment Validation"
    log_info "Checking Deployment '$DEPLOYMENT_NAME' in namespace '$CONTROL_PLANE_NS'"

    log_step "2a. Deployment existence"
    if ! oc get deployment "$DEPLOYMENT_NAME" -n "$CONTROL_PLANE_NS" >/dev/null 2>&1; then
        log_fail "Deployment '$DEPLOYMENT_NAME' does not exist"
        return 1
    fi
    log_pass "Deployment '$DEPLOYMENT_NAME' exists"

    local deploy_json
    deploy_json=$(oc get deployment "$DEPLOYMENT_NAME" -n "$CONTROL_PLANE_NS" -o json 2>/dev/null)

    log_step "2b. ConfigMap volume"
    local volume_name
    volume_name=$(echo "$deploy_json" | jq -r \
        ".spec.template.spec.volumes[]? | select(.configMap.name == \"$CONFIGMAP_NAME\") | .name" 2>/dev/null || true)

    if [ -n "$volume_name" ]; then
        log_pass "Volume '$volume_name' references ConfigMap '$CONFIGMAP_NAME'"
    else
        log_fail "No volume references ConfigMap '$CONFIGMAP_NAME'"
        echo "  Existing volumes:"
        echo "$deploy_json" | jq -r '.spec.template.spec.volumes[]? | "\(.name): \(.configMap.name // .secret.secretName // "other")"' 2>/dev/null || true
        return 1
    fi

    log_step "2c. Volume mount in operator container"
    local mount_path
    mount_path=$(echo "$deploy_json" | jq -r \
        ".spec.template.spec.containers[0].volumeMounts[]? | select(.name == \"$volume_name\") | .mountPath" 2>/dev/null || true)

    if [ -n "$mount_path" ]; then
        log_pass "Volume '$volume_name' mounted at: $mount_path"
    else
        log_fail "Volume '$volume_name' is not mounted in the operator container"
        echo "  Existing mounts:"
        echo "$deploy_json" | jq -r '.spec.template.spec.containers[0].volumeMounts[]? | "\(.name) → \(.mountPath)"' 2>/dev/null || true
    fi

    log_step "2d. --config argument"
    local all_args
    all_args=$(echo "$deploy_json" | jq -r '
        ((.spec.template.spec.containers[0].command // []) + (.spec.template.spec.containers[0].args // []))
        | .[]' 2>/dev/null || true)

    if echo "$all_args" | grep -q -- "--config"; then
        local config_value
        config_value=$(echo "$all_args" | grep -A1 -- "--config" | tail -1 || true)
        log_pass "--config flag present (value: $config_value)"
    else
        log_fail "--config flag not found in container args"
        echo "  Container args:"
        echo "$all_args" | sed 's/^/    /'
    fi

    log_step "2e. --files argument"
    if echo "$all_args" | grep -q -- "--files"; then
        log_pass "--files flag present"
    else
        log_info "--files flag not found (may be embedded in --config path)"
    fi

    log_step "2f. Image Registry operator pod status"
    local pods
    pods=$(oc get pods -n "$CONTROL_PLANE_NS" --no-headers 2>/dev/null | grep "$DEPLOYMENT_NAME" || true)

    if [ -n "$pods" ]; then
        echo "$pods" | while read -r line; do
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
        log_fail "No pods found for deployment '$DEPLOYMENT_NAME'"
    fi
}

# ---------------------------------------------------------------------------
# TEST 3: TLS Profile Switching — focused on image-registry
# Patches HostedCluster, waits for image-registry operator rollout,
# verifies image-registry ConfigMap reflects new TLS settings.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Helper: run a single profile switch step
# ---------------------------------------------------------------------------
run_profile_step() {
    local step_name="$1"
    local profile_label="$2"
    local patch="$3"
    local expected_ver="$4"
    local expect_ciphers="$5"

    log_step "$step_name) Patching HostedCluster → $profile_label TLS profile"
    local old_ver
    old_ver=$(get_observed_generation)
    log_info "observedGeneration before: $old_ver"

    # Reset first to clear leftover fields, then apply
    oc patch hostedcluster "$HOSTED_CLUSTER" -n "$HC_NAMESPACE" --type=merge -p \
        "$DEFAULT_RESTORE_PATCH" 2>/dev/null || true
    oc patch hostedcluster "$HOSTED_CLUSTER" -n "$HC_NAMESPACE" --type=merge -p "$patch"
    log_pass "Patched HostedCluster → $profile_label"

    log_info "Waiting for kube-apiserver rollout, then checking ConfigMap..."
    wait_pod_restart "kube-apiserver" "$CONTROL_PLANE_NS" 1200
    wait_image_registry_rollout "$CONTROL_PLANE_NS" 1200 "$expected_ver"

    local new_ver
    new_ver=$(get_observed_generation)
    log_info "observedGeneration after: $new_ver"
    if [ "$new_ver" -gt "$old_ver" ] 2>/dev/null; then
        log_pass "observedGeneration increased: $old_ver → $new_ver"
    fi

    verify_image_registry_ciphers "$expected_ver" "$expect_ciphers" "$CONTROL_PLANE_NS" "$profile_label"
}

# ---------------------------------------------------------------------------
# Check if a step should run based on --resume-from
# Steps are ordered: 3.1 < 3.2 < 3.3 < 3.4 < 3.5 < restore
# ---------------------------------------------------------------------------
should_run_step() {
    local step="$1"
    if [ -z "$RESUME_FROM" ]; then
        return 0
    fi

    # Map step names to numbers for comparison
    local step_num resume_num
    case "$step" in
        3.1) step_num=1 ;; 3.2) step_num=2 ;; 3.3) step_num=3 ;;
        3.4) step_num=4 ;; 3.5) step_num=5 ;; restore) step_num=6 ;;
        *)   step_num=0 ;;
    esac
    case "$RESUME_FROM" in
        3.1) resume_num=1 ;; 3.2) resume_num=2 ;; 3.3) resume_num=3 ;;
        3.4) resume_num=4 ;; 3.5) resume_num=5 ;; restore) resume_num=6 ;;
        *)   resume_num=0 ;;
    esac

    if [ "$step_num" -ge "$resume_num" ]; then
        return 0
    fi
    return 1
}

test_profile_switch() {
    log_section "Test 3: Image Registry TLS Profile Switching [Disruptive]"

    if [ "$DRY_RUN" = true ]; then
        log_skip "Profile switching skipped in dry-run mode (would modify HostedCluster)"
        return 0
    fi

    if [ -n "$RESUME_FROM" ]; then
        log_info "Resuming from step $RESUME_FROM (skipping earlier steps)"
    fi

    local original_profile
    original_profile=$(get_current_tls_profile)
    log_info "Current TLS profile: $original_profile"

    # ─── 3.1 Check default (Intermediate) ciphers on image-registry ───
    if should_run_step "3.1"; then
        log_step "3.1) Check default image-registry TLS settings"
        verify_image_registry_ciphers "VersionTLS12" "yes" "$CONTROL_PLANE_NS" "default/Intermediate"
    else
        log_skip "3.1) Skipped (resuming from $RESUME_FROM)"
    fi

    # ─── 3.2 Custom profile ───
    if should_run_step "3.2"; then
        run_profile_step "3.2" "Custom" \
            '{"spec": {"configuration": {"apiServer": {"tlsSecurityProfile":{"custom":{"ciphers":["ECDHE-ECDSA-CHACHA20-POLY1305","ECDHE-RSA-CHACHA20-POLY1305","ECDHE-RSA-AES128-GCM-SHA256","ECDHE-ECDSA-AES128-GCM-SHA256"],"minTLSVersion":"VersionTLS11"},"type":"Custom"}}}}}' \
            "VersionTLS11" "yes"
    else
        log_skip "3.2) Custom — Skipped (resuming from $RESUME_FROM)"
    fi

    # ─── 3.3 Old profile ───
    if should_run_step "3.3"; then
        run_profile_step "3.3" "Old" \
            '{"spec": {"configuration": {"apiServer": {"tlsSecurityProfile":{"old":{},"type":"Old"}}}}}' \
            "VersionTLS10" "yes"
    else
        log_skip "3.3) Old — Skipped (resuming from $RESUME_FROM)"
    fi

    # ─── 3.4 Intermediate profile ───
    if should_run_step "3.4"; then
        run_profile_step "3.4" "Intermediate" \
            '{"spec": {"configuration": {"apiServer": {"tlsSecurityProfile":{"intermediate":{},"type":"Intermediate"}}}}}' \
            "VersionTLS12" "yes"
    else
        log_skip "3.4) Intermediate — Skipped (resuming from $RESUME_FROM)"
    fi

    # ─── 3.5 Modern profile ───
    if should_run_step "3.5"; then
        run_profile_step "3.5" "Modern" \
            '{"spec": {"configuration": {"apiServer": {"tlsSecurityProfile":{"modern":{},"type":"Modern"}}}}}' \
            "VersionTLS13" "no"
    else
        log_skip "3.5) Modern — Skipped (resuming from $RESUME_FROM)"
    fi

    # ─── Restore defaults ───
    if should_run_step "restore"; then
        log_step "Restoring cluster defaults"
        oc patch hostedcluster "$HOSTED_CLUSTER" -n "$HC_NAMESPACE" \
            --type=merge -p "$DEFAULT_RESTORE_PATCH" 2>/dev/null || true
        log_info "Restored apiServer config to null (default)"

        wait_pod_restart "kube-apiserver" "$CONTROL_PLANE_NS" 1200
        wait_image_registry_rollout "$CONTROL_PLANE_NS" 1200 "VersionTLS12"

        log_step "Verifying default image-registry TLS settings restored"
        verify_image_registry_ciphers "VersionTLS12" "yes" "$CONTROL_PLANE_NS" "default/restored"
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
        echo "  1. Ensure HyperShift operator includes PR #8011 changes"
        echo "  2. Check control-plane-operator logs:"
        echo "     oc logs deployment/control-plane-operator -n $CONTROL_PLANE_NS --tail=50"
        echo "  3. Check image-registry-operator logs:"
        echo "     oc logs deployment/$DEPLOYMENT_NAME -n $CONTROL_PLANE_NS --tail=50"
    fi
    echo ""
    return "$FAIL_COUNT"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Image Registry TLS Security Profile Test (PR #8011)${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  HostedCluster:  $HOSTED_CLUSTER"
    echo "  Namespace:      $HC_NAMESPACE"
    echo "  Dry Run:        $DRY_RUN"
    echo "  Specific Test:  ${SPECIFIC_TEST:-all}"
    echo "  Resume From:    ${RESUME_FROM:-(start)}"
    echo ""

    check_prerequisites
    discover_control_plane_ns

    case "${SPECIFIC_TEST:-all}" in
        configmap)      test_configmap ;;
        deployment)     test_deployment ;;
        profile-switch) test_profile_switch ;;
        all)
            test_configmap
            test_deployment
            if [ "$DRY_RUN" = false ]; then
                test_profile_switch
            fi
            ;;
        *)
            echo -e "${RED}Unknown test: $SPECIFIC_TEST${NC}"
            echo "Available: configmap, deployment, profile-switch, all"
            exit 1
            ;;
    esac

    print_summary
}

main "$@"
