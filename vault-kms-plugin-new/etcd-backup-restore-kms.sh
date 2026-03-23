#!/bin/bash
# ============================================================================
# etcd Backup and Restore Script for KMS-Encrypted OpenShift Clusters
# ============================================================================
#
# This script tests the etcd backup and restore scenario on an OpenShift
# cluster that uses KMS (Vault Transit) encryption for etcd secrets.
#
# It covers:
#   1. Pre-backup verification (KMS encryption is active, secrets are encrypted)
#   2. Creating test secrets to validate encryption
#   3. Taking an etcd snapshot backup
#   4. Simulating data loss (deleting test secrets)
#   5. Restoring etcd from backup
#   6. Post-restore verification (secrets are intact, KMS decryption works)
#
# Usage:
#   # Full backup and restore test
#   ./etcd-backup-restore-kms.sh --backup-and-restore
#
#   # Backup only
#   ./etcd-backup-restore-kms.sh --backup
#
#   # Restore from existing backup
#   ./etcd-backup-restore-kms.sh --restore --backup-dir /home/core/backup
#
#   # Verify KMS encryption status only
#   ./etcd-backup-restore-kms.sh --verify
#
#   # Cleanup test resources
#   ./etcd-backup-restore-kms.sh --cleanup
#
# Prerequisites:
#   - oc CLI logged into the cluster with cluster-admin
#   - KMS encryption enabled on the cluster
#   - KMS plugin pods running on control plane nodes
#   - Vault accessible and Transit engine working
#
# ============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
KMS_NAMESPACE="openshift-kms-plugin"
ETCD_NAMESPACE="openshift-etcd"
APISERVER_NAMESPACE="openshift-kube-apiserver"
TEST_NAMESPACE="kms-backup-test"
BACKUP_NODE=""          # Will be auto-detected
BACKUP_DIR=""           # Will be set based on action
ACTION=""
SKIP_RESTORE_PROMPT="false"

# Logging helpers
log_info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_success() { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
log_header()  { printf "\n${CYAN}============================================================${NC}\n"; printf "${CYAN}  %s${NC}\n" "$*"; printf "${CYAN}============================================================${NC}\n"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --backup-and-restore)
            ACTION="backup-and-restore"
            shift
            ;;
        --backup)
            ACTION="backup"
            shift
            ;;
        --restore)
            ACTION="restore"
            shift
            ;;
        --verify)
            ACTION="verify"
            shift
            ;;
        --cleanup)
            ACTION="cleanup"
            shift
            ;;
        --backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --backup-node)
            BACKUP_NODE="$2"
            shift 2
            ;;
        --yes|-y)
            SKIP_RESTORE_PROMPT="true"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [action] [options]"
            echo ""
            echo "Actions:"
            echo "  --backup-and-restore  Full test: verify → backup → delete test data → restore → verify"
            echo "  --backup              Take etcd backup only"
            echo "  --restore             Restore etcd from backup"
            echo "  --verify              Verify KMS encryption status only"
            echo "  --cleanup             Remove test resources"
            echo ""
            echo "Options:"
            echo "  --backup-dir PATH     Path to backup directory on the node (for --restore)"
            echo "  --backup-node NODE    Specific control plane node to use for backup/restore"
            echo "  --yes, -y             Skip confirmation prompts"
            echo "  --help, -h            Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 --backup-and-restore"
            echo "  $0 --backup"
            echo "  $0 --restore --backup-dir /home/core/assets/backup"
            echo "  $0 --verify"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ============================================================================
# Prerequisite Checks
# ============================================================================
check_prerequisites() {
    log_header "Checking Prerequisites"

    # Check oc CLI
    if ! command -v oc &>/dev/null; then
        log_error "oc CLI not found. Please install it first."
        exit 1
    fi
    log_success "oc CLI found"

    # Check cluster access
    if ! oc whoami &>/dev/null; then
        log_error "Not logged into OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    local user
    user=$(oc whoami 2>/dev/null)
    log_success "Logged in as: $user"

    # Check cluster-admin access
    if ! oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
        log_error "cluster-admin access required. Current user lacks permissions."
        exit 1
    fi
    log_success "cluster-admin access confirmed"

    # Check jq
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found. Some output formatting may be limited."
    else
        log_success "jq found"
    fi
}

# ============================================================================
# Get Control Plane Node
# ============================================================================
get_control_plane_node() {
    if [ -n "$BACKUP_NODE" ]; then
        log_info "Using specified node: $BACKUP_NODE"
        return
    fi

    log_info "Detecting control plane nodes..."
    local nodes
    nodes=$(oc get nodes -l node-role.kubernetes.io/master="" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || \
            oc get nodes -l node-role.kubernetes.io/control-plane="" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$nodes" ]; then
        log_error "No control plane nodes found"
        exit 1
    fi

    # Use the first control plane node
    BACKUP_NODE=$(echo "$nodes" | awk '{print $1}')
    log_success "Using control plane node: $BACKUP_NODE"

    # Show all control plane nodes
    echo "  All control plane nodes:"
    for n in $nodes; do
        echo "    - $n"
    done
}

# ============================================================================
# Step 1: Verify KMS Encryption Status
# ============================================================================
verify_kms_status() {
    log_header "Verifying KMS Encryption Status"

    local all_ok=true

    # 1. Check if KMS encryption is enabled on APIServer
    log_info "Checking APIServer encryption configuration..."
    local enc_type
    enc_type=$(oc get apiserver cluster -o jsonpath='{.spec.encryption.type}' 2>/dev/null || echo "none")
    if [ "$enc_type" = "KMS" ] || [ "$enc_type" = "kms" ]; then
        log_success "APIServer encryption type: $enc_type"
    else
        log_warn "APIServer encryption type: '$enc_type' (expected 'KMS')"
        log_warn "KMS encryption may not be enabled. Run:"
        echo "    oc patch apiserver cluster --type=merge -p '{\"spec\":{\"encryption\":{\"type\":\"KMS\"}}}'"
        all_ok=false
    fi

    # 2. Check KMS plugin pods
    log_info "Checking KMS plugin pods..."
    local kms_pods
    kms_pods=$(oc get pods -n "$KMS_NAMESPACE" -l app=vault-kube-kms --no-headers 2>/dev/null || echo "")
    if [ -n "$kms_pods" ]; then
        local running_count
        running_count=$(echo "$kms_pods" | grep -c "Running" || echo "0")
        local total_count
        total_count=$(echo "$kms_pods" | wc -l | tr -d ' ')
        if [ "$running_count" = "$total_count" ] && [ "$total_count" -gt 0 ]; then
            log_success "KMS plugin pods: $running_count/$total_count running"
        else
            log_warn "KMS plugin pods: $running_count/$total_count running"
            all_ok=false
        fi
        echo "$kms_pods" | while read -r line; do
            echo "    $line"
        done
    else
        log_warn "No KMS plugin pods found in namespace $KMS_NAMESPACE"
        all_ok=false
    fi

    # 3. Check KMS socket on control plane nodes
    log_info "Checking KMS socket on control plane nodes..."
    local nodes
    nodes=$(oc get nodes -l node-role.kubernetes.io/master="" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || \
            oc get nodes -l node-role.kubernetes.io/control-plane="" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    for node in $nodes; do
        local socket_exists
        socket_exists=$(oc debug node/"$node" -q -- chroot /host ls /var/run/kmsplugin/kms.sock 2>/dev/null || echo "missing")
        if echo "$socket_exists" | grep -q "kms.sock"; then
            log_success "KMS socket exists on $node"
        else
            log_warn "KMS socket NOT found on $node"
            all_ok=false
        fi
    done

    # 4. Check encryption status via kube-apiserver operator
    log_info "Checking encryption migration status..."
    local enc_conditions
    enc_conditions=$(oc get kubeapiserver cluster -o json 2>/dev/null | jq -r '.status.conditions[] | select(.type | contains("Encrypt")) | "\(.type): \(.status) - \(.message // "OK")"' 2>/dev/null || echo "Unable to query")
    if [ -n "$enc_conditions" ] && [ "$enc_conditions" != "Unable to query" ]; then
        echo "$enc_conditions" | while read -r line; do
            echo "    $line"
        done
    else
        log_info "No encryption conditions found (may be normal if encryption was recently enabled)"
    fi

    # 5. Check etcd pods
    log_info "Checking etcd pods..."
    local etcd_pods
    etcd_pods=$(oc get pods -n "$ETCD_NAMESPACE" -l app=etcd --no-headers 2>/dev/null || echo "")
    if [ -n "$etcd_pods" ]; then
        local etcd_running
        etcd_running=$(echo "$etcd_pods" | grep -c "Running" || echo "0")
        local etcd_total
        etcd_total=$(echo "$etcd_pods" | wc -l | tr -d ' ')
        log_success "etcd pods: $etcd_running/$etcd_total running"
    else
        log_error "No etcd pods found!"
        all_ok=false
    fi

    # 6. Check cluster operators
    log_info "Checking cluster operator health..."
    local degraded_ops
    degraded_ops=$(oc get clusteroperators --no-headers 2>/dev/null | awk '$5 == "True" {print $1}' || echo "")
    if [ -n "$degraded_ops" ]; then
        log_warn "Degraded cluster operators:"
        echo "$degraded_ops" | while read -r op; do
            echo "    - $op"
        done
        all_ok=false
    else
        log_success "No degraded cluster operators"
    fi

    # Summary
    echo ""
    if [ "$all_ok" = true ]; then
        log_success "All KMS verification checks passed"
    else
        log_warn "Some checks had warnings — review above before proceeding"
    fi
}

# ============================================================================
# Step 2: Create Test Data (Secrets)
# ============================================================================
create_test_data() {
    log_header "Creating Test Data for Backup/Restore Verification"

    # Create test namespace
    log_info "Creating test namespace: $TEST_NAMESPACE"
    oc create namespace "$TEST_NAMESPACE" --dry-run=client -o yaml | oc apply -f - 2>/dev/null

    # Create test secrets
    log_info "Creating test secrets..."

    # Secret 1: Simple key-value
    oc create secret generic kms-test-secret-1 \
        --from-literal=username=admin \
        --from-literal=password="KMS-Encrypted-P@ssw0rd-$(date +%s)" \
        -n "$TEST_NAMESPACE" \
        --dry-run=client -o yaml | oc apply -f -
    log_success "Created kms-test-secret-1"

    # Secret 2: Multi-value secret
    oc create secret generic kms-test-secret-2 \
        --from-literal=db-host=postgres.example.com \
        --from-literal=db-port="5432" \
        --from-literal=db-name=myapp \
        --from-literal=db-password="DB-Secret-$(date +%s)" \
        -n "$TEST_NAMESPACE" \
        --dry-run=client -o yaml | oc apply -f -
    log_success "Created kms-test-secret-2"

    # Secret 3: TLS-like secret
    oc create secret generic kms-test-secret-3 \
        --from-literal=tls.crt="FAKE-CERT-DATA-FOR-KMS-TESTING-$(date +%s)" \
        --from-literal=tls.key="FAKE-KEY-DATA-FOR-KMS-TESTING-$(date +%s)" \
        -n "$TEST_NAMESPACE" \
        --dry-run=client -o yaml | oc apply -f -
    log_success "Created kms-test-secret-3"

    # Secret 4: ConfigMap (not encrypted, for comparison)
    oc create configmap kms-test-config \
        --from-literal=app-mode=production \
        --from-literal=log-level=info \
        -n "$TEST_NAMESPACE" \
        --dry-run=client -o yaml | oc apply -f -
    log_success "Created kms-test-config (ConfigMap, for comparison)"

    # Record checksums of secret values for post-restore validation
    log_info "Recording secret checksums for post-restore validation..."
    local checksum_file="/tmp/kms-backup-checksums-$(date +%Y%m%d%H%M%S).txt"

    for i in 1 2 3; do
        local secret_data
        secret_data=$(oc get secret "kms-test-secret-$i" -n "$TEST_NAMESPACE" -o json 2>/dev/null | jq -S '.data' 2>/dev/null || echo "ERROR")
        echo "kms-test-secret-$i: $(echo "$secret_data" | sha256sum | awk '{print $1}')" >> "$checksum_file"
    done

    log_success "Checksums saved to: $checksum_file"
    echo ""
    echo "  Test secrets created in namespace: $TEST_NAMESPACE"
    oc get secrets -n "$TEST_NAMESPACE" --no-headers 2>/dev/null | grep "kms-test" | while read -r line; do
        echo "    $line"
    done

    # Export checksum file path for later use
    export KMS_CHECKSUM_FILE="$checksum_file"
}

# ============================================================================
# Step 3: Verify Secrets are Encrypted in etcd
# ============================================================================
verify_secrets_encrypted() {
    log_header "Verifying Secrets are Encrypted in etcd"

    # Get an etcd pod
    local etcd_pod
    etcd_pod=$(oc get pods -n "$ETCD_NAMESPACE" -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$etcd_pod" ]; then
        log_warn "Cannot find etcd pod — skipping direct etcd verification"
        log_info "You can verify encryption status via:"
        echo "    oc get openshiftapiserver -o=jsonpath='{range .items[0].status.conditions[?(@.type==\"Encrypted\")]}{.type}{\"\\t\"}{.status}{\"\\t\"}{.message}{\"\\n\"}{end}'"
        return
    fi

    log_info "Using etcd pod: $etcd_pod"

    for i in 1 2 3; do
        log_info "Checking encryption of kms-test-secret-$i..."

        # Read the raw secret from etcd
        local etcd_output
        etcd_output=$(oc exec -n "$ETCD_NAMESPACE" "$etcd_pod" -c etcd -- \
            etcdctl get "/kubernetes.io/secrets/$TEST_NAMESPACE/kms-test-secret-$i" \
            --cert /etc/kubernetes/pki/etcd-peer/peer.crt \
            --key /etc/kubernetes/pki/etcd-peer/peer.key \
            --cacert /etc/kubernetes/pki/etcd-peer/ca-bundle.crt \
            --print-value-only 2>/dev/null | head -c 200 || echo "ERROR_READING")

        if echo "$etcd_output" | grep -q "k8s:enc:kms"; then
            log_success "kms-test-secret-$i is KMS-encrypted in etcd (prefix: k8s:enc:kms:...)"
        elif echo "$etcd_output" | grep -q "k8s:enc:aescbc"; then
            log_warn "kms-test-secret-$i is encrypted with aescbc (not KMS)"
        elif echo "$etcd_output" | grep -q "k8s:enc:"; then
            log_info "kms-test-secret-$i is encrypted ($(echo "$etcd_output" | grep -oE 'k8s:enc:[^:]+' | head -1))"
        elif echo "$etcd_output" | grep -q "ERROR_READING"; then
            log_warn "Could not read kms-test-secret-$i from etcd (access denied or pod issue)"
        else
            log_warn "kms-test-secret-$i appears to be UNENCRYPTED in etcd!"
        fi
    done
}

# ============================================================================
# Step 4: Take etcd Backup
# ============================================================================
take_etcd_backup() {
    log_header "Taking etcd Backup"

    get_control_plane_node

    log_info "Taking etcd backup on node: $BACKUP_NODE"
    log_info "This uses the cluster-backup.sh script on the control plane node..."

    # The standard OpenShift etcd backup procedure
    local backup_timestamp
    backup_timestamp=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="/home/core/assets/backup_kms_${backup_timestamp}"

    log_info "Backup directory: $BACKUP_DIR"

    # Run the backup on the control plane node
    log_info "Executing backup (this may take a few minutes)..."
    local backup_output
    backup_output=$(oc debug node/"$BACKUP_NODE" -q -- chroot /host bash -c "
        /usr/local/bin/cluster-backup.sh $BACKUP_DIR 2>&1
    " 2>&1 || echo "BACKUP_COMMAND_FAILED")

    if echo "$backup_output" | grep -qi "error\|failed\|BACKUP_COMMAND_FAILED"; then
        # Check if it's just a warning vs actual failure
        if echo "$backup_output" | grep -qi "snapshot saved\|backup completed\|snapshot db"; then
            log_warn "Backup completed with warnings:"
            echo "$backup_output" | tail -10 | while read -r line; do
                echo "    $line"
            done
        else
            log_error "Backup may have failed:"
            echo "$backup_output" | tail -20 | while read -r line; do
                echo "    $line"
            done
            echo ""
            log_info "Trying alternative backup method..."
            take_etcd_backup_manual
            return
        fi
    else
        echo "$backup_output" | tail -10 | while read -r line; do
            echo "    $line"
        done
    fi

    # Verify backup files exist
    log_info "Verifying backup files..."
    local backup_files
    backup_files=$(oc debug node/"$BACKUP_NODE" -q -- chroot /host bash -c "
        ls -lh $BACKUP_DIR/ 2>/dev/null
    " 2>&1 || echo "")

    if [ -n "$backup_files" ]; then
        log_success "Backup files:"
        echo "$backup_files" | while read -r line; do
            echo "    $line"
        done
    else
        log_error "No backup files found at $BACKUP_DIR"
        exit 1
    fi

    # Save backup metadata
    log_info "Saving backup metadata..."
    oc debug node/"$BACKUP_NODE" -q -- chroot /host bash -c "
        echo 'Backup Metadata' > $BACKUP_DIR/kms-backup-info.txt
        echo '===============' >> $BACKUP_DIR/kms-backup-info.txt
        echo 'Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)' >> $BACKUP_DIR/kms-backup-info.txt
        echo 'Node: $BACKUP_NODE' >> $BACKUP_DIR/kms-backup-info.txt
        echo 'KMS Encryption: active' >> $BACKUP_DIR/kms-backup-info.txt
        echo 'Test Namespace: $TEST_NAMESPACE' >> $BACKUP_DIR/kms-backup-info.txt
        echo 'Cluster: $(hostname)' >> $BACKUP_DIR/kms-backup-info.txt
    " 2>/dev/null || true

    log_success "etcd backup completed successfully"
    echo ""
    echo "  Backup location: $BACKUP_NODE:$BACKUP_DIR"
    echo "  To restore later: $0 --restore --backup-dir $BACKUP_DIR --backup-node $BACKUP_NODE"
}

# ============================================================================
# Step 4b: Manual etcd Backup (fallback)
# ============================================================================
take_etcd_backup_manual() {
    log_info "Using manual etcdctl snapshot method..."

    local backup_timestamp
    backup_timestamp=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="/home/core/assets/backup_kms_${backup_timestamp}"

    # Get etcd pod and take snapshot directly
    local etcd_pod
    etcd_pod=$(oc get pods -n "$ETCD_NAMESPACE" -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$etcd_pod" ]; then
        log_error "No etcd pod found"
        exit 1
    fi

    log_info "Taking snapshot via etcd pod: $etcd_pod"

    # Create backup directory on the node
    oc debug node/"$BACKUP_NODE" -q -- chroot /host mkdir -p "$BACKUP_DIR" 2>/dev/null || true

    # Take etcd snapshot
    oc exec -n "$ETCD_NAMESPACE" "$etcd_pod" -c etcd -- \
        etcdctl snapshot save /var/lib/etcd/snapshot.db \
        --cert /etc/kubernetes/pki/etcd-peer/peer.crt \
        --key /etc/kubernetes/pki/etcd-peer/peer.key \
        --cacert /etc/kubernetes/pki/etcd-peer/ca-bundle.crt 2>&1 || true

    # Copy snapshot to backup directory
    oc debug node/"$BACKUP_NODE" -q -- chroot /host bash -c "
        cp /var/lib/etcd/snapshot.db $BACKUP_DIR/snapshot_$(date +%Y-%m-%d_%H%M%S).db 2>/dev/null || true
        # Also backup static pod resources
        cp -r /etc/kubernetes/manifests $BACKUP_DIR/manifests 2>/dev/null || true
        cp -r /etc/kubernetes/static-pod-resources $BACKUP_DIR/static-pod-resources 2>/dev/null || true
    " 2>/dev/null || true

    # Verify
    local backup_files
    backup_files=$(oc debug node/"$BACKUP_NODE" -q -- chroot /host ls -lh "$BACKUP_DIR/" 2>&1 || echo "")
    if [ -n "$backup_files" ]; then
        log_success "Manual backup completed:"
        echo "$backup_files" | while read -r line; do
            echo "    $line"
        done
    else
        log_error "Manual backup may have failed"
    fi
}

# ============================================================================
# Step 5: Simulate Data Loss (Delete Test Secrets)
# ============================================================================
simulate_data_loss() {
    log_header "Simulating Data Loss"

    log_warn "This will delete the test secrets to simulate data loss."
    log_warn "The etcd backup taken earlier should contain these secrets."

    # Record what exists before deletion
    log_info "Current test secrets:"
    oc get secrets -n "$TEST_NAMESPACE" --no-headers 2>/dev/null | grep "kms-test" | while read -r line; do
        echo "    $line"
    done

    # Read secret values before deletion for comparison
    log_info "Recording secret values before deletion..."
    for i in 1 2 3; do
        local val
        val=$(oc get secret "kms-test-secret-$i" -n "$TEST_NAMESPACE" -o jsonpath='{.data}' 2>/dev/null || echo "NOT_FOUND")
        echo "  kms-test-secret-$i data: $val"
    done

    # Delete test secrets
    echo ""
    log_info "Deleting test secrets..."
    for i in 1 2 3; do
        oc delete secret "kms-test-secret-$i" -n "$TEST_NAMESPACE" --ignore-not-found=true 2>/dev/null
        log_success "Deleted kms-test-secret-$i"
    done
    oc delete configmap kms-test-config -n "$TEST_NAMESPACE" --ignore-not-found=true 2>/dev/null
    log_success "Deleted kms-test-config"

    # Verify deletion
    echo ""
    log_info "Verifying deletion..."
    local remaining
    remaining=$(oc get secrets -n "$TEST_NAMESPACE" --no-headers 2>/dev/null | grep "kms-test" || echo "")
    if [ -z "$remaining" ]; then
        log_success "All test secrets deleted — data loss simulated"
    else
        log_warn "Some test secrets still exist:"
        echo "$remaining"
    fi
}

# ============================================================================
# Step 6: Restore etcd from Backup
# ============================================================================
restore_etcd() {
    log_header "Restoring etcd from Backup"

    if [ -z "$BACKUP_DIR" ]; then
        log_error "No backup directory specified. Use --backup-dir to provide the path."
        exit 1
    fi

    get_control_plane_node

    log_warn "=========================================================="
    log_warn "  WARNING: etcd RESTORE is a DISRUPTIVE operation!"
    log_warn "=========================================================="
    log_warn ""
    log_warn "This will:"
    log_warn "  1. Stop the etcd static pod on $BACKUP_NODE"
    log_warn "  2. Restore etcd data from: $BACKUP_DIR"
    log_warn "  3. Restart etcd and kube-apiserver"
    log_warn ""
    log_warn "The cluster API will be UNAVAILABLE during the restore."
    log_warn ""

    if [ "$SKIP_RESTORE_PROMPT" != "true" ]; then
        read -p "Are you sure you want to proceed? (type 'yes' to confirm): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Restore cancelled"
            return
        fi
    fi

    log_info "Starting etcd restore on node: $BACKUP_NODE"
    log_info "Backup directory: $BACKUP_DIR"

    # Verify backup exists on the node
    log_info "Verifying backup files on $BACKUP_NODE..."
    local backup_check
    backup_check=$(oc debug node/"$BACKUP_NODE" -q -- chroot /host bash -c "
        ls -la $BACKUP_DIR/*.db 2>/dev/null || echo 'NO_SNAPSHOT'
    " 2>&1)

    if echo "$backup_check" | grep -q "NO_SNAPSHOT"; then
        log_error "No snapshot .db file found in $BACKUP_DIR on $BACKUP_NODE"
        log_info "Available files:"
        oc debug node/"$BACKUP_NODE" -q -- chroot /host ls -la "$BACKUP_DIR/" 2>/dev/null || true
        exit 1
    fi

    log_success "Backup files verified"

    # Run the restore using the OpenShift cluster-restore script
    # Try multiple known script paths across OCP versions
    log_info "Running cluster restore (this will take several minutes)..."
    echo ""

    local restore_output
    restore_output=$(oc debug node/"$BACKUP_NODE" -q -- chroot /host bash -c "
        if [ -x /usr/local/bin/cluster-restore.sh ]; then
            /usr/local/bin/cluster-restore.sh $BACKUP_DIR 2>&1
        elif [ -x /usr/local/bin/cluster-restore-etcd.sh ]; then
            /usr/local/bin/cluster-restore-etcd.sh $BACKUP_DIR 2>&1
        else
            echo 'RESTORE_SCRIPT_NOT_FOUND'
            echo 'Searched: /usr/local/bin/cluster-restore.sh, /usr/local/bin/cluster-restore-etcd.sh'
            ls -la /usr/local/bin/cluster-restore* 2>/dev/null || echo 'No cluster-restore scripts found'
        fi
    " 2>&1 || echo "RESTORE_COMMAND_FAILED")

    echo "$restore_output" | while read -r line; do
        echo "    $line"
    done

    if echo "$restore_output" | grep -qi "RESTORE_COMMAND_FAILED\|RESTORE_SCRIPT_NOT_FOUND"; then
        log_error "Restore command failed. Trying manual restore..."
        restore_etcd_manual
        return
    fi

    log_success "etcd restore command completed"
    echo ""

    # Wait for cluster to come back
    wait_for_cluster_recovery
}

# ============================================================================
# Step 6b: Manual etcd Restore (fallback)
# ============================================================================
restore_etcd_manual() {
    log_info "Attempting manual etcd restore..."
    log_warn "Manual restore requires careful steps. Follow these:"
    echo ""
    echo "  1. SSH to the control plane node:"
    echo "     oc debug node/$BACKUP_NODE"
    echo "     chroot /host"
    echo ""
    echo "  2. Move current etcd data:"
    echo "     mv /var/lib/etcd/member /var/lib/etcd/member.bak"
    echo ""
    echo "  3. Restore from snapshot:"
    echo "     ETCDCTL_API=3 etcdctl snapshot restore $BACKUP_DIR/*.db \\"
    echo "       --data-dir /var/lib/etcd \\"
    echo "       --skip-hash-check"
    echo ""
    echo "  4. Fix permissions:"
    echo "     chown -R root:root /var/lib/etcd"
    echo "     restorecon -R /var/lib/etcd"
    echo ""
    echo "  5. Restart kubelet:"
    echo "     systemctl restart kubelet"
    echo ""
    log_warn "Refer to OpenShift documentation for the complete restore procedure:"
    echo "  https://docs.openshift.com/container-platform/latest/backup_and_restore/control_plane_backup_and_restore/disaster_recovery/scenario-2-restoring-cluster-state.html"
}

# ============================================================================
# Step 7: Wait for Cluster Recovery
# ============================================================================
wait_for_cluster_recovery() {
    log_header "Waiting for Cluster Recovery"

    log_info "Waiting for API server to become available..."
    local max_wait=300
    local waited=0
    local interval=10

    while [ $waited -lt $max_wait ]; do
        if oc get nodes &>/dev/null; then
            log_success "API server is responding"
            break
        fi
        printf "    Waiting... (%d/%d seconds)\r" "$waited" "$max_wait"
        sleep $interval
        waited=$((waited + interval))
    done

    if [ $waited -ge $max_wait ]; then
        log_warn "API server did not become available within ${max_wait}s"
        log_warn "The cluster may still be recovering. Check manually:"
        echo "    oc get nodes"
        echo "    oc get pods -n openshift-etcd"
        return
    fi

    # Wait for etcd pods
    log_info "Waiting for etcd pods..."
    oc wait --for=condition=Ready pod -l app=etcd -n "$ETCD_NAMESPACE" --timeout=300s 2>/dev/null || \
        log_warn "etcd pods may still be starting up"

    # Wait for kube-apiserver
    log_info "Waiting for kube-apiserver operator..."
    oc wait clusteroperator kube-apiserver \
        --for=condition=Available=True \
        --timeout=600s 2>/dev/null || \
        log_warn "kube-apiserver operator may still be rolling out"

    # Check KMS plugin pods
    log_info "Checking KMS plugin pods after restore..."
    sleep 10
    oc get pods -n "$KMS_NAMESPACE" --no-headers 2>/dev/null | while read -r line; do
        echo "    $line"
    done

    log_success "Cluster recovery checks complete"
}

# ============================================================================
# Step 8: Post-Restore Verification
# ============================================================================
verify_post_restore() {
    log_header "Post-Restore Verification"

    local all_ok=true

    # 1. Check if test secrets are restored
    log_info "Checking if test secrets are restored..."
    local restored_count=0
    for i in 1 2 3; do
        if oc get secret "kms-test-secret-$i" -n "$TEST_NAMESPACE" &>/dev/null; then
            log_success "kms-test-secret-$i: RESTORED"
            restored_count=$((restored_count + 1))
        else
            log_error "kms-test-secret-$i: MISSING (not restored)"
            all_ok=false
        fi
    done

    if [ "$restored_count" -eq 0 ]; then
        log_error "No test secrets were restored. The backup may not have included them."
        log_info "This can happen if the backup was taken before the test secrets were created."
        return
    fi

    # 2. Verify secret values can be decrypted (KMS is working)
    log_info "Verifying KMS decryption of restored secrets..."
    for i in 1 2 3; do
        local secret_data
        secret_data=$(oc get secret "kms-test-secret-$i" -n "$TEST_NAMESPACE" -o jsonpath='{.data}' 2>/dev/null || echo "ERROR")
        if [ "$secret_data" != "ERROR" ] && [ -n "$secret_data" ] && [ "$secret_data" != "{}" ]; then
            log_success "kms-test-secret-$i: Decryption successful (KMS working)"

            # Show decrypted values
            local keys
            keys=$(oc get secret "kms-test-secret-$i" -n "$TEST_NAMESPACE" -o json 2>/dev/null | jq -r '.data | keys[]' 2>/dev/null || echo "")
            for key in $keys; do
                local val
                val=$(oc get secret "kms-test-secret-$i" -n "$TEST_NAMESPACE" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || echo "DECRYPT_FAILED")
                echo "    $key = $val"
            done
        else
            log_error "kms-test-secret-$i: Decryption FAILED (KMS may not be working)"
            all_ok=false
        fi
    done

    # 3. Verify checksum integrity (if checksum file exists)
    if [ -n "${KMS_CHECKSUM_FILE:-}" ] && [ -f "$KMS_CHECKSUM_FILE" ]; then
        log_info "Verifying checksums..."
        local checksum_ok=true
        for i in 1 2 3; do
            local current_checksum
            current_checksum=$(oc get secret "kms-test-secret-$i" -n "$TEST_NAMESPACE" -o json 2>/dev/null | jq -S '.data' 2>/dev/null | sha256sum | awk '{print $1}')
            local saved_checksum
            saved_checksum=$(grep "kms-test-secret-$i" "$KMS_CHECKSUM_FILE" 2>/dev/null | awk '{print $2}' || echo "NONE")

            if [ "$current_checksum" = "$saved_checksum" ]; then
                log_success "kms-test-secret-$i: Checksum matches (data integrity verified)"
            else
                log_warn "kms-test-secret-$i: Checksum mismatch (saved: $saved_checksum, current: $current_checksum)"
                checksum_ok=false
            fi
        done
        if [ "$checksum_ok" = false ]; then
            all_ok=false
        fi
    fi

    # 4. Check ConfigMap
    if oc get configmap kms-test-config -n "$TEST_NAMESPACE" &>/dev/null; then
        log_success "kms-test-config (ConfigMap): RESTORED"
    else
        log_warn "kms-test-config (ConfigMap): Missing (may not have been in backup)"
    fi

    # 5. Create a NEW secret to verify KMS is still working for new writes
    log_info "Testing KMS encryption for new secrets (post-restore)..."
    local post_restore_secret="kms-post-restore-test-$(date +%s)"
    if oc create secret generic "$post_restore_secret" \
        --from-literal=test-key="post-restore-value-$(date +%s)" \
        -n "$TEST_NAMESPACE" &>/dev/null; then

        # Read it back
        local new_val
        new_val=$(oc get secret "$post_restore_secret" -n "$TEST_NAMESPACE" \
            -o jsonpath='{.data.test-key}' 2>/dev/null | base64 -d 2>/dev/null || echo "FAILED")

        if echo "$new_val" | grep -q "post-restore-value"; then
            log_success "New secret created and decrypted successfully — KMS is fully operational"
        else
            log_error "New secret decryption failed — KMS may have issues"
            all_ok=false
        fi

        # Clean up post-restore test secret
        oc delete secret "$post_restore_secret" -n "$TEST_NAMESPACE" --ignore-not-found=true &>/dev/null
    else
        log_error "Failed to create new secret after restore — API server or KMS issue"
        all_ok=false
    fi

    # 6. Verify KMS plugin pods are all running
    log_info "Verifying KMS plugin pods..."
    local kms_pods
    kms_pods=$(oc get pods -n "$KMS_NAMESPACE" -l app=vault-kube-kms --no-headers 2>/dev/null || echo "")
    if [ -n "$kms_pods" ]; then
        local running
        running=$(echo "$kms_pods" | grep -c "Running" || echo "0")
        local total
        total=$(echo "$kms_pods" | wc -l | tr -d ' ')
        if [ "$running" = "$total" ]; then
            log_success "KMS plugin pods: $running/$total running"
        else
            log_warn "KMS plugin pods: $running/$total running — some pods may need restart"
            all_ok=false
        fi
    fi

    # 7. Check cluster operators
    log_info "Checking cluster operator status..."
    local co_status
    co_status=$(oc get clusteroperators kube-apiserver etcd --no-headers 2>/dev/null || echo "")
    echo "$co_status" | while read -r line; do
        echo "    $line"
    done

    # Summary
    echo ""
    log_header "Backup & Restore Test Summary"
    if [ "$all_ok" = true ]; then
        printf "${GREEN}  RESULT: PASS${NC}\n"
        echo ""
        echo "  ✓ etcd backup was taken successfully"
        echo "  ✓ Test secrets were deleted (data loss simulated)"
        echo "  ✓ etcd was restored from backup"
        echo "  ✓ All test secrets were recovered"
        echo "  ✓ KMS decryption is working (secrets are readable)"
        echo "  ✓ New secrets can be created and encrypted with KMS"
        echo "  ✓ KMS plugin pods are healthy"
    else
        printf "${YELLOW}  RESULT: PARTIAL PASS (review warnings above)${NC}\n"
        echo ""
        echo "  Some checks had issues. Review the output above for details."
    fi
    echo ""
}

# ============================================================================
# Cleanup Test Resources
# ============================================================================
cleanup_test_resources() {
    log_header "Cleaning Up Test Resources"

    log_info "Deleting test namespace and all resources: $TEST_NAMESPACE"
    oc delete namespace "$TEST_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    log_success "Test namespace deleted"

    # Clean up checksum files
    rm -f /tmp/kms-backup-checksums-*.txt 2>/dev/null || true
    log_success "Temporary files cleaned up"

    log_info "Note: etcd backups on the control plane node are preserved."
    log_info "To remove them, SSH to the node and delete the backup directory."
}

# ============================================================================
# Action: Backup Only
# ============================================================================
action_backup() {
    check_prerequisites
    verify_kms_status
    create_test_data
    verify_secrets_encrypted
    take_etcd_backup

    echo ""
    log_header "Backup Complete"
    echo ""
    echo "  Backup saved on node: $BACKUP_NODE"
    echo "  Backup directory:     $BACKUP_DIR"
    echo ""
    echo "  To restore later:"
    echo "    $0 --restore --backup-dir $BACKUP_DIR --backup-node $BACKUP_NODE"
    echo ""
    echo "  To run full backup-and-restore test:"
    echo "    $0 --backup-and-restore"
}

# ============================================================================
# Action: Restore Only
# ============================================================================
action_restore() {
    check_prerequisites

    if [ -z "$BACKUP_DIR" ]; then
        log_error "Please specify --backup-dir with the path to the backup on the control plane node."
        echo ""
        echo "  Example: $0 --restore --backup-dir /home/core/assets/backup_kms_20260227 --backup-node <node>"
        exit 1
    fi

    restore_etcd
    verify_kms_status
    verify_post_restore
}

# ============================================================================
# Action: Full Backup and Restore Test
# ============================================================================
action_backup_and_restore() {
    check_prerequisites

    echo ""
    printf "${CYAN}  This will perform a FULL etcd backup and restore test:${NC}\n"
    echo "    1. Verify KMS encryption status"
    echo "    2. Create test secrets"
    echo "    3. Verify secrets are encrypted in etcd"
    echo "    4. Take etcd backup"
    echo "    5. Delete test secrets (simulate data loss)"
    echo "    6. Restore etcd from backup"
    echo "    7. Verify secrets are restored and KMS works"
    echo ""

    if [ "$SKIP_RESTORE_PROMPT" != "true" ]; then
        read -p "Proceed with full backup and restore test? [y/N]: " proceed
        if [ "$proceed" != "y" ] && [ "$proceed" != "Y" ]; then
            log_info "Cancelled"
            exit 0
        fi
    fi

    # Step 1: Verify KMS is active
    verify_kms_status

    # Step 2: Create test data
    create_test_data

    # Step 3: Verify encryption
    verify_secrets_encrypted

    # Step 4: Take backup
    take_etcd_backup

    # Step 5: Simulate data loss
    simulate_data_loss

    # Step 6: Restore
    echo ""
    log_warn "About to restore etcd. The cluster API will be briefly unavailable."
    if [ "$SKIP_RESTORE_PROMPT" != "true" ]; then
        read -p "Continue with etcd restore? (type 'yes' to confirm): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Restore cancelled. Backup is still available at:"
            echo "    Node: $BACKUP_NODE"
            echo "    Path: $BACKUP_DIR"
            exit 0
        fi
    fi
    restore_etcd

    # Step 7: Verify
    verify_post_restore
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    printf "${CYAN}============================================================${NC}\n"
    printf "${CYAN}  etcd Backup & Restore Test — KMS Encryption${NC}\n"
    printf "${CYAN}============================================================${NC}\n"

    if [ -z "$ACTION" ]; then
        echo ""
        echo "Choose an action:"
        echo "  1) Full backup and restore test"
        echo "  2) Backup only"
        echo "  3) Restore from existing backup"
        echo "  4) Verify KMS encryption status"
        echo "  5) Cleanup test resources"
        read -p "Enter choice [1-5]: " choice
        case $choice in
            1) ACTION="backup-and-restore" ;;
            2) ACTION="backup" ;;
            3) ACTION="restore" ;;
            4) ACTION="verify" ;;
            5) ACTION="cleanup" ;;
            *) echo "Invalid choice"; exit 1 ;;
        esac
    fi

    case $ACTION in
        backup-and-restore)
            action_backup_and_restore
            ;;
        backup)
            action_backup
            ;;
        restore)
            action_restore
            ;;
        verify)
            check_prerequisites
            verify_kms_status
            verify_secrets_encrypted
            ;;
        cleanup)
            cleanup_test_resources
            ;;
        *)
            log_error "Unknown action: $ACTION"
            exit 1
            ;;
    esac

    echo ""
}

main
