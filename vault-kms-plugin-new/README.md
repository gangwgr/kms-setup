# Vault KMS Plugin for OpenShift

This directory contains manifests and scripts for deploying a Vault-based KMS plugin for testing KMS encryption in OpenShift.

## Overview

The Vault KMS plugin allows the Kubernetes API server to use HashiCorp Vault's Transit secrets engine for encrypting secrets at rest. This is useful for:

- Testing KMS encryption functionality
- Development and local testing
- Validating KMS encryption workflows

## Prerequisites

- OpenShift cluster (4.22+)
- `oc` CLI logged into the cluster
- `helm` CLI (for local Vault installation)
- `jq` CLI
- `curl` CLI

## Quick Start

### Option 1: Local Vault (Recommended for Testing)

This installs Vault in dev mode on your cluster and configures everything automatically:

```bash
bash deploy-kms.sh --local
```

### Option 2: Cloud/External Vault

Connect to an existing Vault instance:

```bash
# Set environment variables
export VAULT_ADDR="https://your-vault.example.com:8200"
export VAULT_NAMESPACE="admin"  # For Vault Enterprise/HCP
export VAULT_USERNAME="your-username"
export VAULT_PASSWORD="your-password"

# Run deployment
bash deploy-kms.sh --cloud
```

### Option 3: Interactive Mode

```bash
bash deploy-kms.sh
```

Follow the prompts to choose local or cloud mode and enter credentials.

### Prerequisites: Create Pull Secret

The KMS plugin image is private. Before deploying, create the pull secret:

```bash
# Create namespace first
oc apply -f namespace.yaml

# Create pull secret with robot account credentials
oc create secret docker-registry quay-pull-secret \
    --namespace=openshift-kms-plugin \
    --docker-server=quay.io \
    --docker-username="rhn_support_rgangwar+vault_kms_testing" \
    --docker-password="<ROBOT_TOKEN>"
```

## What the Script Does

1. **Local Mode:**
   - Installs Vault using Helm in dev mode
   - Configures Transit secrets engine
   - Creates KMS encryption key
   - Sets up AppRole authentication
   - Deploys KMS plugin DaemonSet

2. **Cloud Mode:**
   - Authenticates to existing Vault
   - Configures Transit secrets engine (if not exists)
   - Creates KMS encryption key
   - Sets up AppRole authentication
   - Deploys KMS plugin DaemonSet

## Manual Deployment

If you prefer to deploy manually:

### 1. Deploy Vault (Local Mode Only)

```bash
# Add Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Create namespace
oc create namespace vault-system
oc label namespace vault-system pod-security.kubernetes.io/enforce=privileged

# Install Vault in dev mode
helm install vault hashicorp/vault \
    --namespace vault-system \
    --set "global.openshift=true" \
    --set "server.dev.enabled=true" \
    --set "server.dev.devRootToken=root" \
    --set "injector.enabled=false"
```

### 2. Configure Vault

```bash
# Port-forward to Vault
oc port-forward -n vault-system svc/vault 8200:8200 &

# Set environment
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root"

# Enable Transit
curl -sf --noproxy "*" \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST --data '{"type": "transit"}' \
    $VAULT_ADDR/v1/sys/mounts/transit

# Create KMS key
curl -sf --noproxy "*" \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST --data '{"type": "aes256-gcm96"}' \
    $VAULT_ADDR/v1/transit/keys/kms-key

# Enable AppRole
curl -sf --noproxy "*" \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST --data '{"type": "approle"}' \
    $VAULT_ADDR/v1/sys/auth/approle

# Create policy
curl -s --noproxy "*" \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request PUT \
    --data '{
      "policy": "path \"transit/encrypt/kms-key\" { capabilities = [\"update\"] }\npath \"transit/decrypt/kms-key\" { capabilities = [\"update\"] }\npath \"transit/keys/kms-key\" { capabilities = [\"read\"] }\npath \"sys/license/status\" { capabilities = [\"read\"] }"
    }' \
    $VAULT_ADDR/v1/sys/policies/acl/kms-plugin-policy

# Create AppRole
curl -s --noproxy "*" \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST \
    --data '{"policies": ["kms-plugin-policy"], "token_ttl": "1h", "token_max_ttl": "24h"}' \
    $VAULT_ADDR/v1/auth/approle/role/kms-plugin

# Get credentials
ROLE_ID=$(curl -s --noproxy "*" \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    $VAULT_ADDR/v1/auth/approle/role/kms-plugin/role-id | jq -r '.data.role_id')

SECRET_ID=$(curl -s --noproxy "*" \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST \
    $VAULT_ADDR/v1/auth/approle/role/kms-plugin/secret-id | jq -r '.data.secret_id')

echo "Role ID: $ROLE_ID"
echo "Secret ID: $SECRET_ID"
```

### 3. Deploy KMS Plugin

```bash
# Apply manifests
oc apply -f namespace.yaml
oc apply -f serviceaccount.yaml

# Create secret (use ClusterIP for internal address)
VAULT_CLUSTER_IP=$(oc get svc vault -n vault-system -o jsonpath='{.spec.clusterIP}')

oc create secret generic vault-kms-credentials \
    --namespace=openshift-kms-plugin \
    --from-literal=VAULT_ADDR="http://${VAULT_CLUSTER_IP}:8200" \
    --from-literal=VAULT_NAMESPACE="" \
    --from-literal=VAULT_ROLE_ID="$ROLE_ID" \
    --from-literal=VAULT_SECRET_ID="$SECRET_ID" \
    --from-literal=VAULT_KEY_NAME="kms-key"

# Deploy DaemonSet
oc apply -f daemonset.yaml

# Wait for pods
oc wait --for=condition=Ready pod -l app=vault-kube-kms -n openshift-kms-plugin --timeout=120s
```

### 4. Enable KMS Encryption

```bash
oc patch apiserver cluster --type=merge -p '{"spec":{"encryption":{"type":"KMS"}}}'
```

## Verification

### Check Encryption Status

```bash
# Check APIServer encryption config
oc get apiserver cluster -o jsonpath='{.spec.encryption.type}'

# Check operator status
oc get co kube-apiserver

# Check encryption keys
oc get secrets -n openshift-config-managed \
    -l encryption.apiserver.operator.openshift.io/component=openshift-kube-apiserver
```

### Verify Secret Encryption

```bash
# Create a test secret
oc create secret generic test-kms-secret --from-literal=key=testvalue -n default

# Verify it's accessible
oc get secret test-kms-secret -n default -o jsonpath='{.data.key}' | base64 -d
```

### Check KMS Plugin Logs

```bash
oc logs -n openshift-kms-plugin -l app=vault-kube-kms --tail=50
```

### Check Vault Logs

```bash
oc logs -n vault-system vault-0 --tail=50
```

## Cleanup

### Remove KMS Encryption

```bash
# Disable KMS encryption (switch back to identity)
oc patch apiserver cluster --type=merge -p '{"spec":{"encryption":{"type":"identity"}}}'

# Wait for rollout
oc get co kube-apiserver -w
```

### Remove KMS Plugin

```bash
oc delete -f daemonset.yaml
oc delete -f serviceaccount.yaml
oc delete -f namespace.yaml
```

### Remove Vault (Local Mode)

```bash
helm uninstall vault -n vault-system
oc delete namespace vault-system
```

## Troubleshooting

### KMS Plugin Pods Not Starting

Check pod events:
```bash
oc describe pods -n openshift-kms-plugin -l app=vault-kube-kms
```

Check logs:
```bash
oc logs -n openshift-kms-plugin -l app=vault-kube-kms
```

### Vault Connection Issues

1. **For local Vault:** Ensure the secret uses ClusterIP, not DNS name (KMS plugin runs with hostNetwork)
2. **For cloud Vault:** Ensure the Vault address is accessible from control-plane nodes
3. Check AppRole credentials are valid

### Proxy Issues

If you see Squid/proxy responses, the script includes `--noproxy "*"` flags. Ensure your environment doesn't override these.

### Permission Denied

The KMS plugin requires privileged security context. The `serviceaccount.yaml` includes the necessary SCC binding.

## Files

| File | Description |
|------|-------------|
| `deploy-kms.sh` | Main deployment script (local or cloud mode) |
| `namespace.yaml` | KMS plugin namespace with privileged labels |
| `serviceaccount.yaml` | ServiceAccount with privileged SCC binding |
| `daemonset.yaml` | KMS plugin DaemonSet configuration |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Control Plane Node                        │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │  kube-apiserver │───▶│  vault-kube-kms (DaemonSet)     │ │
│  │                 │    │  /var/run/kmsplugin/kms.sock    │ │
│  └─────────────────┘    └──────────────┬──────────────────┘ │
└────────────────────────────────────────┼────────────────────┘
                                         │
                                         ▼
                              ┌──────────────────────┐
                              │  HashiCorp Vault     │
                              │  (Transit Engine)    │
                              └──────────────────────┘
```

## Related Documentation

- [Kubernetes KMS Provider](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- [Vault Transit Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [Vault AppRole Auth](https://developer.hashicorp.com/vault/docs/auth/approle)
- [OpenShift Encryption at Rest](https://docs.openshift.com/container-platform/latest/security/encrypting-etcd.html)
