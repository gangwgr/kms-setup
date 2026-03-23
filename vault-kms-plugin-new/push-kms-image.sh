#!/bin/bash
# Push vault-kube-kms OCI image to Quay.io registry
#
# Supports:
#   - OCI image directories (with oci-layout/index.json)
#   - Docker tar archives (.tar files)
#   - Docker tar.zip archives (.tar.zip files)
#
# Usage:
#   # Using default image directory path:
#   ./push-kms-image.sh
#
#   # Using custom image path (directory, tar, or tar.zip):
#   ./push-kms-image.sh /path/to/oci-image-dir
#   ./push-kms-image.sh /path/to/image.tar
#   ./push-kms-image.sh /path/to/image.tar.zip
#
#   # Using custom registry target:
#   QUAY_REPO="quay.io/myorg/vault-kube-kms" ./push-kms-image.sh
#
#   # Non-interactive with env vars:
#   export QUAY_USERNAME="your-robot-account"
#   export QUAY_PASSWORD="your-token"
#   ./push-kms-image.sh /path/to/image
#
#   # Skip login (already logged in):
#   ./push-kms-image.sh --skip-login

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Portable colored echo (works in both bash and sh)
log_info()    { printf "${GREEN}%s${NC}\n" "$1"; }
log_warn()    { printf "${YELLOW}%s${NC}\n" "$1"; }
log_error()   { printf "${RED}%s${NC}\n" "$1"; }
log_step()    { printf "\n${YELLOW}%s${NC}\n" "$1"; }
log_success() { printf "${GREEN}%s${NC}\n" "$1"; }

# Default values
QUAY_REPO="${QUAY_REPO:-quay.io/rhn_support_rgangwar/vault-kube-kms}"
DEFAULT_IMAGE_DIR="$HOME/Downloads/vault-kube-kms_release-ubi_linux_amd64_0.0.0-dev_526d044fc5fe72d2e1f2b9bdcd15c71efd87b1d2.docker.redhat 2"
IMAGE_PATH=""
SKIP_LOGIN=false
VERSION_TAG="0.0.0-dev-ubi"

# Detect container runtime (podman preferred, fall back to docker)
CONTAINER_RUNTIME=""
if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
fi

# Check for skopeo (best tool for OCI directories)
# Also verify it actually runs (can break if linked libs are outdated)
HAS_SKOPEO=false
if command -v skopeo >/dev/null 2>&1; then
    if skopeo --version >/dev/null 2>&1; then
        HAS_SKOPEO=true
    else
        echo "  Warning: skopeo found but not functional (broken library link?)"
        echo "  Fix with: brew reinstall skopeo"
        echo "  Falling back to $CONTAINER_RUNTIME..."
    fi
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-login)
            SKIP_LOGIN=true
            shift
            ;;
        --repo)
            QUAY_REPO="$2"
            shift 2
            ;;
        --version-tag)
            VERSION_TAG="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [IMAGE_PATH] [options]"
            echo ""
            echo "Arguments:"
            echo "  IMAGE_PATH          Path to OCI image dir, .tar, or .tar.zip"
            echo ""
            echo "Options:"
            echo "  --repo REPO         Target registry/repo (default: $QUAY_REPO)"
            echo "  --version-tag TAG   Version tag to apply (default: $VERSION_TAG)"
            echo "  --skip-login        Skip registry login (if already logged in)"
            echo "  --help, -h          Show this help"
            echo ""
            echo "Environment variables:"
            echo "  QUAY_REPO           Target registry/repo"
            echo "  QUAY_USERNAME       Registry username (for login)"
            echo "  QUAY_PASSWORD       Registry password (for login)"
            echo ""
            echo "Supported image formats:"
            echo "  - OCI image directory (contains oci-layout, index.json, blobs/)"
            echo "  - Docker tar archive (.tar)"
            echo "  - Zipped tar archive (.tar.zip)"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            IMAGE_PATH="$1"
            shift
            ;;
    esac
done

# Use default image path if not provided
if [ -z "$IMAGE_PATH" ]; then
    IMAGE_PATH="$DEFAULT_IMAGE_DIR"
fi

# Detect image format
IMAGE_FORMAT=""
if [ -d "$IMAGE_PATH" ]; then
    if [ -f "$IMAGE_PATH/oci-layout" ] || [ -f "$IMAGE_PATH/index.json" ]; then
        IMAGE_FORMAT="oci-dir"
    elif [ -f "$IMAGE_PATH/manifest.json" ]; then
        IMAGE_FORMAT="docker-dir"
    else
        log_error "Error: Directory exists but does not look like an OCI or Docker image"
        exit 1
    fi
elif [ -f "$IMAGE_PATH" ]; then
    case "$IMAGE_PATH" in
        *.tar.zip)
            IMAGE_FORMAT="tar-zip"
            ;;
        *.tar|*.tar.gz|*.tgz)
            IMAGE_FORMAT="tar"
            ;;
        *)
            IMAGE_FORMAT="tar"  # Try as tar anyway
            ;;
    esac
else
    log_error "Error: Image path not found: $IMAGE_PATH"
    echo "  Provide the path as an argument."
    exit 1
fi

echo ""
log_info "============================================"
log_info "  Push vault-kube-kms Image to Registry"
log_info "============================================"
echo ""
echo "  Image path:        $IMAGE_PATH"
echo "  Image format:      $IMAGE_FORMAT"
echo "  Container runtime: ${CONTAINER_RUNTIME:-not found}"
echo "  Skopeo available:  $HAS_SKOPEO"
echo "  Target repo:       $QUAY_REPO"
echo "  Tags:              latest, $VERSION_TAG"
echo ""

# Validate we have at least one tool to push with
if [ "$HAS_SKOPEO" = "false" ] && [ -z "$CONTAINER_RUNTIME" ]; then
    log_error "Error: Need either skopeo or podman/docker. Install one of them."
    exit 1
fi

#######################################
# Step 1: Login to registry
#######################################
if [ "$SKIP_LOGIN" = "false" ]; then
    log_step "Step 1: Logging in to registry..."

    REGISTRY=$(echo "$QUAY_REPO" | cut -d'/' -f1)

    if [ -n "$QUAY_USERNAME" ] && [ -n "$QUAY_PASSWORD" ]; then
        echo "  Logging in to $REGISTRY with provided credentials..."
        if [ -n "$CONTAINER_RUNTIME" ]; then
            echo "$QUAY_PASSWORD" | $CONTAINER_RUNTIME login "$REGISTRY" \
                --username "$QUAY_USERNAME" \
                --password-stdin
        elif [ "$HAS_SKOPEO" = "true" ]; then
            # skopeo uses the same auth file, login via podman/docker or pass creds inline
            echo "  (Will pass credentials inline to skopeo)"
        fi
    else
        echo "  Logging in to $REGISTRY (interactive)..."
        if [ -n "$CONTAINER_RUNTIME" ]; then
            $CONTAINER_RUNTIME login "$REGISTRY"
        else
            log_error "Error: No container runtime for interactive login. Set QUAY_USERNAME and QUAY_PASSWORD."
            exit 1
        fi
    fi
    log_success "  Login successful"
else
    log_warn "Step 1: Skipping login (--skip-login)"
fi

#######################################
# Step 2: Prepare image (unzip if needed)
#######################################
CLEANUP_TAR=""
ACTUAL_IMAGE_PATH="$IMAGE_PATH"

if [ "$IMAGE_FORMAT" = "tar-zip" ]; then
    log_step "Step 2a: Extracting .tar.zip archive..."
    TEMP_TAR="/tmp/vault-kube-kms-image-$$.tar"
    unzip -p "$IMAGE_PATH" > "$TEMP_TAR"
    ACTUAL_IMAGE_PATH="$TEMP_TAR"
    CLEANUP_TAR="$TEMP_TAR"
    IMAGE_FORMAT="tar"
    echo "  Extracted to: $TEMP_TAR"
fi

#######################################
# Step 3: Push image to registry
#######################################
log_step "Step 2: Pushing image to registry..."

# Strategy depends on image format and available tools
push_with_skopeo_oci() {
    echo "  Using skopeo to copy OCI directory -> registry..."

    # Build skopeo credentials flag if available
    local cred_flag=""
    if [ -n "$QUAY_USERNAME" ] && [ -n "$QUAY_PASSWORD" ]; then
        cred_flag="--dest-creds=${QUAY_USERNAME}:${QUAY_PASSWORD}"
    fi

    echo "  Pushing ${QUAY_REPO}:latest ..."
    skopeo copy $cred_flag \
        "oci:${ACTUAL_IMAGE_PATH}" \
        "docker://${QUAY_REPO}:latest"
    log_success "  Pushed :latest"

    echo "  Pushing ${QUAY_REPO}:${VERSION_TAG} ..."
    skopeo copy $cred_flag \
        "oci:${ACTUAL_IMAGE_PATH}" \
        "docker://${QUAY_REPO}:${VERSION_TAG}"
    log_success "  Pushed :${VERSION_TAG}"
}

push_with_skopeo_tar() {
    echo "  Using skopeo to copy Docker tar -> registry..."

    local cred_flag=""
    if [ -n "$QUAY_USERNAME" ] && [ -n "$QUAY_PASSWORD" ]; then
        cred_flag="--dest-creds=${QUAY_USERNAME}:${QUAY_PASSWORD}"
    fi

    echo "  Pushing ${QUAY_REPO}:latest ..."
    skopeo copy $cred_flag \
        "docker-archive:${ACTUAL_IMAGE_PATH}" \
        "docker://${QUAY_REPO}:latest"
    log_success "  Pushed :latest"

    echo "  Pushing ${QUAY_REPO}:${VERSION_TAG} ..."
    skopeo copy $cred_flag \
        "docker-archive:${ACTUAL_IMAGE_PATH}" \
        "docker://${QUAY_REPO}:${VERSION_TAG}"
    log_success "  Pushed :${VERSION_TAG}"
}

push_with_podman_tar() {
    echo "  Using $CONTAINER_RUNTIME to load tar and push..."

    echo "  Loading image from tar (this may take a moment)..."
    LOAD_OUTPUT=$($CONTAINER_RUNTIME load -i "$ACTUAL_IMAGE_PATH" 2>&1)
    echo "  $LOAD_OUTPUT"

    # Determine loaded image name
    # podman load may output multiple "Loaded image:" lines (one per tag).
    # Pick the LAST one with "localhost/" prefix (the locally-stored name),
    # or fall back to the last "Loaded image:" line.
    LOADED_IMAGE=$(echo "$LOAD_OUTPUT" | grep "Loaded image:" | grep "localhost/" | tail -1 | sed 's/.*Loaded image: *//' 2>/dev/null || echo "")
    if [ -z "$LOADED_IMAGE" ]; then
        LOADED_IMAGE=$(echo "$LOAD_OUTPUT" | grep "Loaded image:" | tail -1 | sed 's/.*Loaded image: *//' 2>/dev/null || echo "")
    fi

    if [ -z "$LOADED_IMAGE" ]; then
        # Last resort: list images and pick the most recent vault-kube-kms
        LOADED_IMAGE=$($CONTAINER_RUNTIME images --format '{{.Repository}}:{{.Tag}}' | grep vault-kube-kms | head -1 2>/dev/null || echo "")
    fi

    if [ -z "$LOADED_IMAGE" ]; then
        log_error "Error: Could not determine loaded image name"
        echo "  Load output: $LOAD_OUTPUT"
        echo "  Try manually: $CONTAINER_RUNTIME images | grep vault-kube-kms"
        exit 1
    fi

    echo "  Using image: $LOADED_IMAGE"

    # Tag
    echo "  Tagging as ${QUAY_REPO}:latest"
    $CONTAINER_RUNTIME tag "$LOADED_IMAGE" "${QUAY_REPO}:latest"
    echo "  Tagging as ${QUAY_REPO}:${VERSION_TAG}"
    $CONTAINER_RUNTIME tag "$LOADED_IMAGE" "${QUAY_REPO}:${VERSION_TAG}"

    # Push
    echo "  Pushing ${QUAY_REPO}:latest ..."
    $CONTAINER_RUNTIME push "${QUAY_REPO}:latest"
    log_success "  Pushed :latest"

    echo "  Pushing ${QUAY_REPO}:${VERSION_TAG} ..."
    $CONTAINER_RUNTIME push "${QUAY_REPO}:${VERSION_TAG}"
    log_success "  Pushed :${VERSION_TAG}"
}

push_with_podman_oci_dir() {
    echo "  Creating tar from OCI directory for $CONTAINER_RUNTIME load..."

    TEMP_TAR="/tmp/vault-kube-kms-oci-$$.tar"
    # Create a tar archive from the OCI directory
    tar -cf "$TEMP_TAR" -C "$ACTUAL_IMAGE_PATH" .
    CLEANUP_TAR="$TEMP_TAR"

    ACTUAL_IMAGE_PATH="$TEMP_TAR"
    push_with_podman_tar
}

# Choose the best push strategy (with fallback if skopeo fails at runtime)
set +e  # Allow skopeo to fail without exiting
case "$IMAGE_FORMAT" in
    oci-dir|docker-dir)
        if [ "$HAS_SKOPEO" = "true" ]; then
            push_with_skopeo_oci
            if [ $? -ne 0 ]; then
                log_warn "  skopeo failed, falling back to $CONTAINER_RUNTIME..."
                set -e
                [ -n "$CONTAINER_RUNTIME" ] && push_with_podman_oci_dir
            fi
        elif [ -n "$CONTAINER_RUNTIME" ]; then
            set -e
            push_with_podman_oci_dir
        fi
        ;;
    tar)
        if [ "$HAS_SKOPEO" = "true" ]; then
            push_with_skopeo_tar
            if [ $? -ne 0 ]; then
                log_warn "  skopeo failed, falling back to $CONTAINER_RUNTIME..."
                set -e
                [ -n "$CONTAINER_RUNTIME" ] && push_with_podman_tar
            fi
        elif [ -n "$CONTAINER_RUNTIME" ]; then
            set -e
            push_with_podman_tar
        fi
        ;;
esac
set -e

#######################################
# Step 3: Cleanup
#######################################
if [ -n "$CLEANUP_TAR" ] && [ -f "$CLEANUP_TAR" ]; then
    rm -f "$CLEANUP_TAR"
    echo "  Cleaned up temporary tar file"
fi

#######################################
# Step 4: Verify
#######################################
log_step "Step 3: Verifying..."

if [ -n "$CONTAINER_RUNTIME" ]; then
    echo "  Local images:"
    $CONTAINER_RUNTIME images | grep -E "REPOSITORY|vault-kube-kms" | head -5 || true
fi

echo ""
log_info "============================================"
log_info "  Image push complete!"
log_info "============================================"
echo ""
echo "Pushed images:"
echo "  ${QUAY_REPO}:latest"
echo "  ${QUAY_REPO}:${VERSION_TAG}"
echo ""
echo "To use in deployments, the image reference is:"
echo "  ${QUAY_REPO}:latest"
echo ""
echo "If static pods are already deployed, restart them to pick up the new image:"
echo "  # Force re-pull on each control plane node:"
echo "  for node in \$(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}'); do"
echo "    oc debug node/\$node -- chroot /host crictl pull ${QUAY_REPO}:latest"
echo "  done"
