# HashiCorp Vault Transit Engine as KMS Provider for OpenShift

This setup configures HashiCorp Vault with the **Transit secret engine** to act as a KMS (Key Management Service) provider for Kubernetes/OpenShift etcd encryption.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                  OpenShift Cluster                       │
│                                                          │
│  ┌──────────────────┐         ┌──────────────────┐     │
│  │  kube-apiserver  │────────▶│ Vault (Transit)  │     │
│  │  (KMS Plugin)    │ AppRole │ Encryption API   │     │
│  └────────┬─────────┘         └──────────────────┘     │
│           │                                              │
│           ▼                                              │
│  ┌──────────────────┐                                   │
│  │      etcd        │                                   │
│  │ (Encrypted Data) │                                   │
│  └──────────────────┘                                   │
└─────────────────────────────────────────────────────────┘
```

## How It Works

- **Vault Transit Engine**: Provides encryption-as-a-service API
- **KMS Plugin**: Kubernetes component that calls Vault for encrypt/decrypt operations
- **AppRole Authentication**: KMS plugin authenticates to Vault using RoleID and SecretID
- **etcd Encryption**: All etcd data is encrypted using Vault before being stored

## Key Differences from AWS KMS Approach

| Feature | This Approach (Transit) | AWS KMS Auto-Unseal |
|---------|------------------------|---------------------|
| **Purpose** | Vault encrypts Kubernetes data | AWS KMS unseals Vault |
| **Direction** | Kubernetes → Vault | Vault → AWS |
| **Use Case** | etcd encryption | Vault unsealing |
| **Authentication** | AppRole | IAM credentials |
| **AWS Required** | No | Yes |
| **Complexity** | Simple | Complex |

## Prerequisites

- OpenShift Container Platform 4.x cluster
- `oc` CLI installed and logged in
- `helm` CLI installed
- Cluster-admin permissions

## Quick Start

Run the automated setup script:

```bash
./setup-vault-transit-kms.sh
```

This script will:
1. ✅ Clean up any existing Vault installations
2. ✅ Install Vault in dev mode
3. ✅ Enable Transit secret engine
4. ✅ Configure AppRole authentication
5. ✅ Create encryption key for Kubernetes
6. ✅ Run comprehensive verification tests
7. ✅ Generate KMS plugin configuration

## What Gets Created

### 1. Vault Pod

```bash
# Check Vault pod
oc get pods -n vault

# Expected output:
# NAME                                    READY   STATUS    RESTARTS   AGE
# vault-0                                 1/1     Running   0          5m
```

### 2. Transit Secret Engine

```bash
# Verify Transit engine
oc exec -n vault vault-0 -- vault secrets list

# Should show:
# Path          Type         Description
# ----          ----         -----------
# transit/      transit      n/a
```

### 3. Encryption Key

```bash
# Check encryption key
oc exec -n vault vault-0 -- vault list transit/keys

# Should show:
# Keys
# ----
# kubernetes-encryption
```

### 4. AppRole Authentication

```bash
# Verify AppRole is enabled
oc exec -n vault vault-0 -- vault auth list

# Should show:
# Path         Type        Description
# ----         ----        -----------
# approle/     approle     n/a

# Check AppRole role
oc exec -n vault vault-0 -- vault list auth/approle/role

# Should show:
# Keys
# ----
# kms-plugin
```

### 5. Policy for KMS Plugin

```bash
# View the policy
oc exec -n vault vault-0 -- vault policy read kms-plugin

# Shows:
# path "transit/encrypt/kubernetes-encryption" {
#   capabilities = ["update"]
# }
#
# path "transit/decrypt/kubernetes-encryption" {
#   capabilities = ["update"]
# }
```

## Generated Files

After successful setup, you'll have:

### 1. `vault-approle-credentials.txt`

Contains AppRole credentials needed by the KMS plugin:

```
Vault Address: http://vault.vault.svc.cluster.local:8200
Transit Key: kubernetes-encryption
AppRole Name: kms-plugin
Role ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Secret ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Root Token: root (dev mode)
```

### 2. `kms-plugin-config.yaml`

KMS plugin configuration secret for OpenShift:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: kms-plugin-config
  namespace: openshift-config
type: Opaque
stringData:
  config.yaml: |
    kind: VaultConfig
    apiVersion: apiserver.config.k8s.io/v1
    vault:
      address: "http://vault.vault.svc.cluster.local:8200"
      transitKeyName: "kubernetes-encryption"
      auth:
        type: "approle"
        approle:
          roleID: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
          secretID: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### 3. `vault-values-transit.yaml`

Helm values used to deploy Vault (auto-generated):

```yaml
global:
  openshift: true

server:
  image:
    repository: "docker.io/hashicorp/vault"
    tag: "1.16.1"

  dev:
    enabled: true
    devRootToken: "root"

  standalone:
    enabled: false

  dataStorage:
    enabled: false

injector:
  enabled: false

ui:
  enabled: true
  serviceType: ClusterIP
```

## Manual Testing

### Test 1: Encrypt Data

```bash
# Encrypt some data
oc exec -n vault vault-0 -- vault write \
  transit/encrypt/kubernetes-encryption \
  plaintext=$(echo 'hello world' | base64)

# Output:
# Key            Value
# ---            -----
# ciphertext     vault:v1:xxxxx...
# key_version    1
```

### Test 2: Decrypt Data

```bash
# Decrypt the ciphertext
oc exec -n vault vault-0 -- vault write \
  transit/decrypt/kubernetes-encryption \
  ciphertext="vault:v1:xxxxx..."

# Then decode:
echo "decoded-base64-output" | base64 -d
# Output: hello world
```

### Test 3: AppRole Login

```bash
# Get credentials from file
ROLE_ID=$(grep "Role ID:" vault-approle-credentials.txt | cut -d: -f2 | xargs)
SECRET_ID=$(grep "Secret ID:" vault-approle-credentials.txt | cut -d: -f2 | xargs)

# Test login
oc exec -n vault vault-0 -- vault write auth/approle/login \
  role_id="$ROLE_ID" \
  secret_id="$SECRET_ID"

# Should return a token
```

### Test 4: AppRole Can Encrypt/Decrypt

```bash
# Login and get token
TOKEN=$(oc exec -n vault vault-0 -- vault write -field=token \
  auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID")

# Use token to encrypt
oc exec -n vault vault-0 -- env VAULT_TOKEN=$TOKEN vault write \
  transit/encrypt/kubernetes-encryption \
  plaintext=$(echo 'test with approle' | base64)

# Should succeed ✅
```

## Verification

The setup script includes 10 comprehensive verification tests:

1. ✅ **Pod Status** - Vault pod is ready (1/1)
2. ✅ **Vault Status** - Vault is unsealed and initialized
3. ✅ **Transit Engine** - Transit engine is enabled
4. ✅ **Transit Key** - Encryption key exists
5. ✅ **AppRole Auth** - AppRole authentication is enabled
6. ✅ **AppRole Role** - KMS plugin role exists
7. ✅ **Encryption Test** - Can encrypt data
8. ✅ **Decryption Test** - Can decrypt data
9. ✅ **AppRole Login** - Can login with AppRole credentials
10. ✅ **AppRole Permissions** - AppRole token can encrypt/decrypt

## Configuration Options

You can customize the setup using environment variables:

```bash
# Change Vault namespace (default: vault)
export VAULT_NAMESPACE="my-vault"

# Change Transit key name (default: kubernetes-encryption)
export TRANSIT_KEY_NAME="my-encryption-key"

# Change AppRole name (default: kms-plugin)
export APPROLE_NAME="my-kms-plugin"

# Run setup
./setup-vault-transit-kms.sh
```

## Vault URLs

### Internal (from within cluster)
```
http://vault.vault.svc.cluster.local:8200
```

### Port-Forward (for local access)
```bash
# Forward Vault port to localhost
oc port-forward -n vault vault-0 8200:8200

# Access locally
export VAULT_ADDR='http://127.0.0.1:8200'
vault status
```

## Next Steps: Configure OpenShift KMS

After Vault is set up, configure OpenShift kube-apiserver to use Vault as KMS provider:

### 1. Apply KMS Plugin Configuration

```bash
oc apply -f kms-plugin-config.yaml
```

### 2. Configure kube-apiserver Encryption

Refer to OpenShift documentation for configuring etcd encryption with external KMS provider:
- [OpenShift Encryption Configuration](https://docs.openshift.com/container-platform/latest/security/encrypting-etcd.html)

### 3. Deploy KMS Plugin

Deploy the Vault KMS plugin DaemonSet that will handle encryption/decryption requests from kube-apiserver.

## Security Considerations

### ⚠️ Dev Mode is NOT for Production

The current setup uses **dev mode** which is:
- ✅ Great for testing and development
- ❌ NOT suitable for production use

**Dev mode limitations:**
- Root token is hardcoded as "root"
- No TLS encryption (HTTP only)
- No persistent storage (data lost on pod restart)
- Auto-unsealed (no seal protection)
- Single pod (no HA)

### Production Recommendations

For production use, you should:

1. **Enable TLS**: Configure Vault with TLS certificates
2. **Use Persistent Storage**: Enable PVC for Vault data
3. **Enable HA Mode**: Run multiple Vault replicas
4. **Seal Vault**: Use auto-unseal with AWS KMS or similar
5. **Rotate Credentials**: Implement AppRole SecretID rotation
6. **Audit Logging**: Enable Vault audit logs
7. **Network Policies**: Restrict access to Vault pod
8. **Backup**: Regular backups of Vault data

## Troubleshooting

### Issue: `oc: command not found`

**Solution:** Install OpenShift CLI:
```bash
# macOS
brew install openshift-cli

# Linux
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
tar xvf openshift-client-linux.tar.gz
sudo mv oc /usr/local/bin/
```

### Issue: `helm: command not found`

**Solution:** Install Helm:
```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Issue: Network Connection Errors

**Error:**
```
Error from server: error dialing backend: write tcp ... use of closed network connection
```

**Solution:** The script includes automatic retry logic (3 attempts with 5s delay). If errors persist:
- Check OpenShift cluster health
- Verify kubelet is running on all nodes
- Check network connectivity

### Issue: Policy Creation Failed

**Error:**
```
'policy' parameter not supplied or empty
```

**Solution:** This is fixed in the script using `sh -c` wrapper. If you still see this:
```bash
# Manual policy creation
oc exec -n vault vault-0 -- sh -c 'vault policy write kms-plugin - <<EOF
path "transit/encrypt/kubernetes-encryption" {
  capabilities = ["update"]
}
path "transit/decrypt/kubernetes-encryption" {
  capabilities = ["update"]
}
EOF'
```

### Issue: Pod Not Ready

**Solution:**
```bash
# Check pod status
oc get pods -n vault

# Check pod logs
oc logs -n vault vault-0

# Describe pod for events
oc describe pod -n vault vault-0
```

### Issue: Transit Engine Not Working

**Solution:**
```bash
# Check if Transit is enabled
oc exec -n vault vault-0 -- vault secrets list

# If not listed, enable manually
oc exec -n vault vault-0 -- vault secrets enable transit

# Create key manually
oc exec -n vault vault-0 -- vault write -f transit/keys/kubernetes-encryption
```

## Cleanup

To remove Vault:

```bash
# Delete Vault installation
helm uninstall vault -n vault

# Delete namespace
oc delete namespace vault

# Delete generated files
rm -f vault-approle-credentials.txt kms-plugin-config.yaml vault-values-transit.yaml
```

## Advanced Usage

### Rotate AppRole SecretID

```bash
# Generate new SecretID
NEW_SECRET_ID=$(oc exec -n vault vault-0 -- vault write -field=secret_id -f \
  auth/approle/role/kms-plugin/secret-id)

echo "New Secret ID: $NEW_SECRET_ID"

# Update KMS plugin configuration with new SecretID
# Restart KMS plugin pods
```

### Monitor Vault Transit Usage

```bash
# Enable metrics
oc exec -n vault vault-0 -- vault write sys/metrics/config \
  enabled=true \
  enable_hostname_label=true

# View Transit key info
oc exec -n vault vault-0 -- vault read transit/keys/kubernetes-encryption
```

### Key Rotation

```bash
# Rotate the Transit key
oc exec -n vault vault-0 -- vault write -f \
  transit/keys/kubernetes-encryption/rotate

# Check key versions
oc exec -n vault vault-0 -- vault read \
  transit/keys/kubernetes-encryption
```

## References

- [HashiCorp Vault Transit Engine](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [Kubernetes KMS Provider](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- [Vault AppRole Authentication](https://developer.hashicorp.com/vault/docs/auth/approle)
- [OpenShift Encryption](https://docs.openshift.com/container-platform/latest/security/encrypting-etcd.html)
- [Vault on OpenShift](https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-openshift)

## Support

For issues or questions:
- HashiCorp Vault: https://discuss.hashicorp.com/c/vault
- OpenShift: https://access.redhat.com/support
