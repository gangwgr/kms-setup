#!/bin/bash
# ============================================================================
# Build & Deploy HyperShift Operator from a PR Branch
# ============================================================================
#
# Builds the hypershift-operator image from a specific PR, pushes it to
# a container registry, and patches the management cluster's operator
# deployment to use the new image.
#
# Usage:
#   ./deploy-hypershift-pr.sh --pr 8078
#   ./deploy-hypershift-pr.sh --pr 8078 --registry quay.io/myorg/hypershift-operator
#   ./deploy-hypershift-pr.sh --pr 8078 --skip-build --image quay.io/myorg/hypershift-operator:pr-8078
#   ./deploy-hypershift-pr.sh --rollback
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

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_pass()    { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_step()    { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
log_section() { echo -e "\n${BOLD}════════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"; }

PR_NUMBER=""
REGISTRY="${REGISTRY:-quay.io/rhn_support_rgangwar/hypershift-operator}"
OPERATOR_NS="${OPERATOR_NS:-hypershift}"
OPERATOR_DEPLOY="${OPERATOR_DEPLOY:-operator}"
CLONE_DIR="${CLONE_DIR:-/tmp/hypershift-pr-build}"
SKIP_BUILD=false
CUSTOM_IMAGE=""
ROLLBACK=false
CONTAINER_RUNTIME=""
DOCKERFILE="Dockerfile"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required (unless --rollback or --skip-build --image):
  --pr NUMBER              PR number to build from (e.g., 8078)

Options:
  --registry REPO          Container registry to push to
                           (default: quay.io/rhn_support_rgangwar/hypershift-operator)
  --clone-dir DIR          Directory to clone hypershift repo into
                           (default: /tmp/hypershift-pr-build)
  --skip-build             Skip build, just deploy an existing image
  --image IMAGE            Full image reference to deploy (use with --skip-build)
  --operator-namespace NS  Namespace of the hypershift-operator (default: hypershift)
  --rollback               Rollback to the original operator image
  --help                   Show this help

Examples:
  # Build and deploy PR #8078
  $(basename "$0") --pr 8078

  # Use custom registry
  $(basename "$0") --pr 8078 --registry quay.io/myorg/hypershift-operator

  # Deploy a pre-built image (skip build)
  $(basename "$0") --skip-build --image registry.ci.openshift.org/ocp/hypershift-operator:pr-8078

  # Rollback to original image
  $(basename "$0") --rollback
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pr)                 PR_NUMBER="$2"; shift 2 ;;
        --registry)           REGISTRY="$2"; shift 2 ;;
        --clone-dir)          CLONE_DIR="$2"; shift 2 ;;
        --skip-build)         SKIP_BUILD=true; shift ;;
        --image)              CUSTOM_IMAGE="$2"; shift 2 ;;
        --operator-namespace) OPERATOR_NS="$2"; shift 2 ;;
        --rollback)           ROLLBACK=true; shift ;;
        --help|-h)            usage ;;
        *)                    echo "Unknown option: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Detect container runtime
# ---------------------------------------------------------------------------
detect_runtime() {
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_RUNTIME="podman"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_RUNTIME="docker"
    else
        log_fail "No container runtime found (podman or docker required)"
        exit 1
    fi
    log_info "Container runtime: $CONTAINER_RUNTIME"
}

# ---------------------------------------------------------------------------
# Save the current operator image for rollback
# ---------------------------------------------------------------------------
BACKUP_FILE="/tmp/hypershift-operator-original-image.txt"

save_original_image() {
    local current_image
    current_image=$(oc get deployment "$OPERATOR_DEPLOY" -n "$OPERATOR_NS" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

    if [ -n "$current_image" ] && [ ! -f "$BACKUP_FILE" ]; then
        echo "$current_image" > "$BACKUP_FILE"
        log_info "Saved original image for rollback: $current_image"
    elif [ -f "$BACKUP_FILE" ]; then
        log_info "Original image already saved: $(cat "$BACKUP_FILE")"
    fi
}

# ---------------------------------------------------------------------------
# Rollback to original image
# ---------------------------------------------------------------------------
do_rollback() {
    log_section "Rolling back operator to original image"

    if [ ! -f "$BACKUP_FILE" ]; then
        log_fail "No backup found at $BACKUP_FILE"
        echo "  The original image was not saved. You can manually set it:"
        echo "  oc set image deployment/$OPERATOR_DEPLOY -n $OPERATOR_NS operator=<original-image>"
        exit 1
    fi

    local original_image
    original_image=$(cat "$BACKUP_FILE")
    log_info "Original image: $original_image"

    oc set image "deployment/$OPERATOR_DEPLOY" -n "$OPERATOR_NS" \
        "operator=$original_image"
    log_pass "Deployment patched back to original image"

    log_step "Waiting for rollout..."
    oc rollout status "deployment/$OPERATOR_DEPLOY" -n "$OPERATOR_NS" --timeout=120s || true

    local ready
    ready=$(oc get deployment "$OPERATOR_DEPLOY" -n "$OPERATOR_NS" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${ready:-0}" -gt 0 ]; then
        log_pass "Operator rolled back successfully ($ready ready replicas)"
    else
        log_fail "Operator not ready after rollback"
    fi

    rm -f "$BACKUP_FILE"
    log_info "Backup file removed"
}

# ---------------------------------------------------------------------------
# Clone and checkout PR
# ---------------------------------------------------------------------------
clone_and_checkout() {
    log_section "Cloning HyperShift and checking out PR #$PR_NUMBER"

    if [ -d "$CLONE_DIR/.git" ]; then
        log_info "Repo already exists at $CLONE_DIR, updating..."
        cd "$CLONE_DIR"
        git fetch origin 2>/dev/null || true
    else
        log_info "Cloning openshift/hypershift to $CLONE_DIR..."
        rm -rf "$CLONE_DIR"
        git clone --depth 50 https://github.com/openshift/hypershift.git "$CLONE_DIR"
        cd "$CLONE_DIR"
    fi

    log_step "Fetching PR #$PR_NUMBER"
    git fetch origin "pull/$PR_NUMBER/head:pr-$PR_NUMBER" 2>&1
    git checkout "pr-$PR_NUMBER"

    local head_commit
    head_commit=$(git log -1 --format='%h %s')
    log_pass "Checked out PR #$PR_NUMBER: $head_commit"
}

# ---------------------------------------------------------------------------
# Find Dockerfile
# ---------------------------------------------------------------------------
find_dockerfile() {
    log_step "Finding Dockerfile"

    if [ -f "$CLONE_DIR/Dockerfile.hypershift" ]; then
        DOCKERFILE="Dockerfile.hypershift"
    elif [ -f "$CLONE_DIR/Dockerfile" ]; then
        DOCKERFILE="Dockerfile"
    else
        log_warn "No standard Dockerfile found. Available Dockerfiles:"
        ls -1 "$CLONE_DIR"/Dockerfile* 2>/dev/null || echo "  (none)"
        log_fail "Cannot determine Dockerfile to build"
        exit 1
    fi

    log_pass "Using: $DOCKERFILE"
}

# ---------------------------------------------------------------------------
# Build the operator image
# ---------------------------------------------------------------------------
build_image() {
    local image_tag="$REGISTRY:pr-$PR_NUMBER"

    log_section "Building hypershift-operator image"
    log_info "Image tag: $image_tag"
    log_info "Dockerfile: $DOCKERFILE"
    log_info "Context: $CLONE_DIR"

    cd "$CLONE_DIR"

    log_step "Building image (this may take several minutes)..."
    $CONTAINER_RUNTIME build \
        -t "$image_tag" \
        -f "$DOCKERFILE" \
        --platform linux/amd64 \
        . 2>&1 | tail -20

    if [ $? -eq 0 ]; then
        log_pass "Image built: $image_tag"
    else
        log_fail "Build failed"
        exit 1
    fi

    echo "$image_tag"
}

# ---------------------------------------------------------------------------
# Push the image
# ---------------------------------------------------------------------------
push_image() {
    local image_tag="$1"

    log_section "Pushing image to registry"
    log_info "Image: $image_tag"

    # Check if logged in
    local registry_host
    registry_host=$(echo "$image_tag" | cut -d/ -f1)
    if ! $CONTAINER_RUNTIME login --get-login "$registry_host" >/dev/null 2>&1; then
        log_warn "Not logged in to $registry_host"
        echo "  Run: $CONTAINER_RUNTIME login $registry_host"
        read -p "  Continue anyway? [y/N]: " cont
        if [ "$cont" != "y" ] && [ "$cont" != "Y" ]; then
            exit 1
        fi
    fi

    $CONTAINER_RUNTIME push "$image_tag" 2>&1
    log_pass "Image pushed: $image_tag"
}

# ---------------------------------------------------------------------------
# Deploy the image to the management cluster
# ---------------------------------------------------------------------------
deploy_image() {
    local image_tag="$1"

    log_section "Deploying to management cluster"

    save_original_image

    local current_image
    current_image=$(oc get deployment "$OPERATOR_DEPLOY" -n "$OPERATOR_NS" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
    log_info "Current image: $current_image"
    log_info "New image:     $image_tag"

    log_step "Patching operator deployment"
    oc set image "deployment/$OPERATOR_DEPLOY" -n "$OPERATOR_NS" \
        "operator=$image_tag"
    log_pass "Deployment patched"

    log_step "Waiting for rollout..."
    oc rollout status "deployment/$OPERATOR_DEPLOY" -n "$OPERATOR_NS" --timeout=300s 2>&1 || true

    local ready
    ready=$(oc get deployment "$OPERATOR_DEPLOY" -n "$OPERATOR_NS" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

    if [ "${ready:-0}" -gt 0 ]; then
        log_pass "Operator running with new image ($ready ready replicas)"
    else
        log_fail "Operator not ready after deployment"
        echo "  Check pod status: oc get pods -n $OPERATOR_NS"
        echo "  Check pod logs:   oc logs deployment/$OPERATOR_DEPLOY -n $OPERATOR_NS --tail=30"
        echo ""
        echo "  To rollback: $(basename "$0") --rollback"
        return 1
    fi

    log_step "Verifying deployed image"
    local deployed_image
    deployed_image=$(oc get pods -n "$OPERATOR_NS" -l "app=$OPERATOR_DEPLOY" \
        -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "unknown")
    log_info "Running image: $deployed_image"

    if [ "$deployed_image" = "$image_tag" ]; then
        log_pass "Image verified"
    else
        log_warn "Running image doesn't match expected (may be using digest)"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  HyperShift Operator PR Deployment Tool${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Handle rollback
    if [ "$ROLLBACK" = true ]; then
        do_rollback
        return 0
    fi

    # Handle skip-build with custom image
    if [ "$SKIP_BUILD" = true ]; then
        if [ -z "$CUSTOM_IMAGE" ]; then
            log_fail "--skip-build requires --image <image>"
            exit 1
        fi

        echo "  Mode:     Deploy pre-built image"
        echo "  Image:    $CUSTOM_IMAGE"
        echo "  Operator: $OPERATOR_NS/$OPERATOR_DEPLOY"
        echo ""

        deploy_image "$CUSTOM_IMAGE"

        log_section "Deployment Complete"
        echo ""
        echo "  To test PR changes:"
        echo "    ./test-webhook-tls-profile.sh --test tls-verify"
        echo ""
        echo "  To rollback:"
        echo "    $(basename "$0") --rollback"
        return 0
    fi

    # Validate PR number
    if [ -z "$PR_NUMBER" ]; then
        log_fail "--pr NUMBER is required (or use --skip-build --image)"
        usage
    fi

    echo "  PR:       #$PR_NUMBER"
    echo "  Registry: $REGISTRY"
    echo "  Clone to: $CLONE_DIR"
    echo "  Operator: $OPERATOR_NS/$OPERATOR_DEPLOY"
    echo ""

    local image_tag="$REGISTRY:pr-$PR_NUMBER"

    # Prerequisites
    log_section "Prerequisites"

    detect_runtime

    if ! oc whoami >/dev/null 2>&1; then
        log_fail "Not logged in to OpenShift (oc whoami failed)"
        exit 1
    fi
    log_pass "Logged in as: $(oc whoami)"

    if ! oc get deployment "$OPERATOR_DEPLOY" -n "$OPERATOR_NS" >/dev/null 2>&1; then
        log_fail "Operator deployment '$OPERATOR_DEPLOY' not found in '$OPERATOR_NS'"
        exit 1
    fi
    log_pass "Operator deployment found"

    if ! command -v git >/dev/null 2>&1; then
        log_fail "git is required"
        exit 1
    fi
    log_pass "git is available"

    # Build
    clone_and_checkout
    find_dockerfile
    build_image

    # Push
    push_image "$image_tag"

    # Deploy
    deploy_image "$image_tag"

    # Summary
    log_section "Deployment Complete"
    echo ""
    echo -e "  ${GREEN}PR #$PR_NUMBER deployed to management cluster${NC}"
    echo ""
    echo "  Next steps — test the PR:"
    echo "    ./test-webhook-tls-profile.sh                     # Full test"
    echo "    ./test-webhook-tls-profile.sh --test tls-verify   # Quick TLS check"
    echo ""
    echo "  Rollback when done:"
    echo "    $(basename "$0") --rollback"
    echo ""
    echo "  Original image saved to: $BACKUP_FILE"
}

main "$@"
