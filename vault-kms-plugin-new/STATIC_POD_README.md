# Static Pod Deployment for KMS Plugin

## Overview

The `deploy-kms-st-pod.sh` script has been modified to support deploying the Vault KMS plugin as **static pods** when using the `--local` flag, instead of as a DaemonSet.

## What Are Static Pods?

Static pods are managed directly by the kubelet on each node, rather than by the Kubernetes API server. Key characteristics:

- **Managed by kubelet**: Pod manifests are read from `/etc/kubernetes/manifests/` on each node
- **Per-node deployment**: Each control plane node runs its own instance
- **No controller**: No ReplicaSet or DaemonSet controller manages them
- **Auto-restart**: kubelet automatically restarts them if they fail
- **API visibility**: Static pods appear in the API with a node name suffix (e.g., `vault-kube-kms-master-0`)

## Deployment Modes

### Cloud Mode (DaemonSet)
```bash
./deploy-kms-st-pod.sh --cloud \
    --vault-addr "https://your-vault.hashicorp.cloud:8200" \
    --vault-namespace "admin" \
    --username "admin-user" \
    --password "your-password"
```

**Behavior**: Deploys KMS plugin as a DaemonSet with credentials stored in Kubernetes Secrets.

### Local Mode (Static Pod)
```bash
./deploy-kms-st-pod.sh --local
```

**Behavior**:
1. Installs Vault locally via Helm
2. Configures Vault with Transit encryption
3. Deploys KMS plugin as static pods on each control plane node
4. Credentials are embedded directly in the static pod manifest

## Key Differences

| Feature | DaemonSet (Cloud) | Static Pod (Local) |
|---------|-------------------|-------------------|
| Management | Kubernetes API | kubelet |
| Credentials | Kubernetes Secret | Embedded in manifest |
| Pod Naming | `vault-kube-kms-xxxxx` | `vault-kube-kms-<node-name>` |
| Deployment Target | All control plane nodes | Each control plane node |
| Update Method | `kubectl apply` | Update manifest on node |
| Removal | `kubectl delete` | Remove manifest file |

## Files

### static-pod.yaml
Template for the static pod manifest. **Do not deploy directly**. The script substitutes placeholder values with actual credentials.

Key placeholders:
- `PLACEHOLDER_ROLE_ID` → Vault AppRole Role ID
- `PLACEHOLDER_SECRET_ID` → Vault AppRole Secret ID
- `PLACEHOLDER_VAULT_ADDR` → Vault server address
- `PLACEHOLDER_VAULT_NAMESPACE` → Vault namespace (if any)

### deploy-kms-st-pod.sh
Enhanced deployment script with two modes:

**New function**: `deploy_static_pod()`
- Generates static pod manifest with actual credentials
- Copies manifest to `/etc/kubernetes/manifests/` on each control plane node
- Uses `oc debug node/` to access node filesystem

## Usage Examples

### Deploy with Local Vault (Static Pod)
```bash
# Simple deployment
./deploy-kms-st-pod.sh --local

# With private Quay.io image
export QUAY_USERNAME="your-robot-account+name"
export QUAY_PASSWORD="your-robot-token"
./deploy-kms-st-pod.sh --local
```

### Verify Deployment
```bash
# Check static pods (note the node name suffix)
oc get pods -n openshift-kms-plugin -o wide

# View logs
oc logs -n openshift-kms-plugin vault-kube-kms-<node-name>

# Check on a specific node
oc debug node/<node-name> -- chroot /host ls -la /etc/kubernetes/manifests/
```

### Remove Static Pods
```bash
# Get control plane nodes
NODES=$(oc get nodes -l node-role.kubernetes.io/control-plane -o name)

# Remove manifest from each node
for node in $NODES; do
  oc debug $node -- chroot /host rm -f /etc/kubernetes/manifests/vault-kube-kms.yaml
done

# Verify removal
oc get pods -n openshift-kms-plugin
```

## Troubleshooting

### Static pods not appearing
**Wait 30-60 seconds** - kubelet scans the manifests directory periodically.

```bash
# Check kubelet logs
oc debug node/<node-name> -- chroot /host journalctl -u kubelet | grep vault-kube-kms

# Verify manifest exists
oc debug node/<node-name> -- chroot /host cat /etc/kubernetes/manifests/vault-kube-kms.yaml
```

### Pod in CrashLoopBackOff
```bash
# Check logs
oc logs -n openshift-kms-plugin vault-kube-kms-<node-name>

# Common issues:
# - Vault not accessible (check VAULT_ADDR in manifest)
# - Invalid AppRole credentials (check ROLE_ID and SECRET_ID)
# - Transit engine not enabled in Vault
```

### Update static pod configuration
```bash
# 1. Edit the manifest on the node
oc debug node/<node-name> -- chroot /host vi /etc/kubernetes/manifests/vault-kube-kms.yaml

# 2. Or remove and redeploy
oc debug node/<node-name> -- chroot /host rm /etc/kubernetes/manifests/vault-kube-kms.yaml
./deploy-kms-st-pod.sh --local
```

## Security Considerations

### Static Pod Security
⚠️ **Warning**: Static pods embed credentials directly in the manifest file.

- Manifest files are stored on the node filesystem
- Readable by users with node access
- Not encrypted at rest by default
- Consider using encrypted filesystems for control plane nodes

### DaemonSet Security
✓ **Better for production**: Credentials stored in Kubernetes Secrets
- Encrypted at rest if KMS is enabled
- RBAC-controlled access
- No credentials on node filesystem

## Recommendations

### Use Static Pods When:
- Testing or development environments
- Learning KMS plugin deployment
- Troubleshooting kubelet or API server issues
- Need pods to run even if API server is down

### Use DaemonSet When:
- Production deployments
- External/cloud Vault instances
- Need credential rotation
- Require Secret management features

## Additional Commands

### Check KMS encryption status
```bash
# Check API server encryption
oc get apiserver cluster -o jsonpath='{.spec.encryption.type}'

# Monitor encryption progress
oc get kubeapiserver cluster -o jsonpath='{.status.conditions}' | \
  jq '.[] | select(.type | contains("Encrypt"))'

# Check kube-apiserver operator
oc get clusteroperator kube-apiserver
```

### Test KMS plugin
```bash
# Create a test secret
oc create secret generic kms-test -n default --from-literal=key=value

# Check if it's encrypted with KMS
# (requires etcdctl access)
```

## Support

For issues or questions:
1. Check pod logs: `oc logs -n openshift-kms-plugin <pod-name>`
2. Check Vault logs: `oc logs -n vault-system vault-0`
3. Verify network connectivity between KMS plugin and Vault
4. Review Vault audit logs for authentication failures

## References

- [Kubernetes Static Pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/)
- [OpenShift KMS Provider](https://docs.openshift.com/container-platform/latest/security/encrypting-etcd.html)
- [HashiCorp Vault Transit Engine](https://developer.hashicorp.com/vault/docs/secrets/transit)
