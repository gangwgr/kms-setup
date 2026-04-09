#!/bin/bash
set -euo pipefail

REGISTRY="${REGISTRY:-quay.io}"
REPO="${REPO:-rhn_support_rgangwar}"
IMAGE_NAME="${IMAGE_NAME:-mock-kms-plugin-vault}"
TAG="${TAG:-latest}"
FULL_IMAGE="${REGISTRY}/${REPO}/${IMAGE_NAME}:${TAG}"
PLATFORMS="${PLATFORMS:-linux/amd64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo "  Mock Vault KMS Plugin - Build & Push"
echo "============================================"
echo "  Image:     $FULL_IMAGE"
echo "  Platforms: $PLATFORMS"
echo ""

if ! podman info >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
    echo "Error: podman or docker is required"
    exit 1
fi

CONTAINER_CMD="podman"
if ! command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
fi

echo "Compiling Go binary for linux/amd64..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o "$SCRIPT_DIR/mock-vault-kms" "$SCRIPT_DIR"
echo "Binary built: $(ls -lh "$SCRIPT_DIR/mock-vault-kms" | awk '{print $5}')"

echo ""
echo "Building container image..."
$CONTAINER_CMD build \
    --platform "$PLATFORMS" \
    -t "$FULL_IMAGE" \
    -f "$SCRIPT_DIR/Dockerfile" \
    "$SCRIPT_DIR"

rm -f "$SCRIPT_DIR/mock-vault-kms"

echo ""
echo "Build complete: $FULL_IMAGE"
echo ""

read -p "Push to $REGISTRY? [Y/n]: " push_confirm
if [ "${push_confirm:-Y}" != "n" ] && [ "${push_confirm:-Y}" != "N" ]; then
    echo "Pushing $FULL_IMAGE..."
    $CONTAINER_CMD push "$FULL_IMAGE"
    echo ""
    echo "Pushed successfully: $FULL_IMAGE"
else
    echo "Skipping push. To push manually:"
    echo "  $CONTAINER_CMD push $FULL_IMAGE"
fi

echo ""
echo "============================================"
echo "Usage in OpenShift APIServer CRD:"
echo ""
echo "  The plugin lifecycle controller will pass"
echo "  vault flags from the KMS config, but this"
echo "  mock image ignores them and runs a mock"
echo "  KMS v2 gRPC provider on the unix socket."
echo ""
echo "  Image: $FULL_IMAGE"
echo "============================================"
