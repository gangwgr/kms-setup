# OpenShift Vault Transit KMS Encryption Setup Guide

This guide walks through configuring OpenShift etcd encryption using HashiCorp Vault Transit Engine as the KMS provider.

## Architecture Overview

```
┌─────────────────┐      ┌──────────────────┐      ┌─────────────┐
│ kube-apiserver  │─────▶│  KMS Plugin Pod  │─────▶│    Vault    │
│                 │      │  (DaemonSet)     │      │   Transit   │
└─────────────────┘      └──────────────────┘      └─────────────┘
        │                                                  │
        └──────────────────────────────────────────────────┘
                    Encrypt/Decrypt API calls
```

## Prerequisites

- OpenShift 4.x cluster with admin access
- `oc` CLI tool installed and logged in
- `helm` CLI tool installed
- HashiCorp Vault deployed (or will be deployed in Step 1)

## Status: Operators Scaled Down ✅

You have successfully completed the operator scaling step:

```bash
# kube-apiserver-operator: 0/0 replicas ✅
# authentication-operator: 0/0 replicas ✅
```

---

## Step 1: Deploy Vault Transit Engine

If Vault is not already deployed, run the setup script:

```bash
cd vault-kms-setup
bash setup-vault-transit-kms.sh
```

This script will:
- Deploy Vault in dev mode to the `vault` namespace
- Enable the Transit secret engine
- Create encryption key: `kubernetes-encryption`
- Configure AppRole authentication for the KMS plugin
- Generate RoleID and SecretID credentials
- Create `kms-plugin-config.yaml` with credentials

**Output files:**
- `vault-approle-credentials.txt` - AppRole credentials (keep secure!)
- `kms-plugin-config.yaml` - KMS plugin configuration secret

**Verify Vault is running:**
```bash
oc get pods -n vault
oc exec -n vault vault-0 -- vault status
```

---

## Step 2: Apply KMS Plugin Configuration Secret

This secret contains Vault connection details and AppRole credentials:

```bash
oc apply -f vault-kms-setup/kms-plugin-config.yaml
```

**Verify the secret:**
```bash
oc get secret kms-plugin-config -n openshift-config
```

---

## Step 3: Deploy Vault KMS Plugin DaemonSet

Create the Vault KMS plugin DaemonSet that will run on all control plane nodes:

```bash
cat > vault-kms-plugin-daemonset.yaml <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vault-kms-plugin
  namespace: openshift-kube-apiserver
spec:
  selector:
    matchLabels:
      name: vault-kms-plugin
  template:
    metadata:
      labels:
        name: vault-kms-plugin
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      containers:
      - name: vault-kms-plugin
        image: registry.k8s.io/kms/vault:v0.9.0
        args:
        - --debug
        - --listen=/var/run/kmsplugin/socket.sock
        - --vault-address=http://vault.vault.svc.cluster.local:8200
        - --vault-transit-path=transit
        - --vault-transit-key=kubernetes-encryption
        - --vault-role-id=$(VAULT_ROLE_ID)
        - --vault-secret-id=$(VAULT_SECRET_ID)
        env:
        - name: VAULT_ROLE_ID
          valueFrom:
            secretKeyRef:
              name: vault-kms-credentials
              key: role-id
        - name: VAULT_SECRET_ID
          valueFrom:
            secretKeyRef:
              name: vault-kms-credentials
              key: secret-id
        volumeMounts:
        - name: socket-dir
          mountPath: /var/run/kmsplugin
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - test -S /var/run/kmsplugin/socket.sock
          initialDelaySeconds: 15
          periodSeconds: 30
      hostNetwork: true
      volumes:
      - name: socket-dir
        hostPath:
          path: /var/run/kmsplugin
          type: DirectoryOrCreate
EOF

oc apply -f vault-kms-plugin-daemonset.yaml
```

**Before applying, you need to create the credentials secret:**

```bash
# Extract RoleID and SecretID from vault-approle-credentials.txt
ROLE_ID="<from vault-approle-credentials.txt>"
SECRET_ID="<from vault-approle-credentials.txt>"

oc create secret generic vault-kms-credentials \
  -n openshift-kube-apiserver \
  --from-literal=role-id="${ROLE_ID}" \
  --from-literal=secret-id="${SECRET_ID}"
```

**Verify KMS plugin pods are running:**
```bash
oc get pods -n openshift-kube-apiserver -l name=vault-kms-plugin -o wide
```

You should see one pod per control plane node in `Running` state.

---

## Step 4: Create Encryption Configuration

Create the encryption configuration that tells kube-apiserver to use the KMS plugin:

```bash
cat > encryption-config.yaml <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - kms:
          name: vault-kms
          endpoint: unix:///var/run/kmsplugin/socket.sock
          cachesize: 1000
          timeout: 3s
      - identity: {}
EOF
```

**Create the encryption configuration secret:**
```bash
oc create secret generic encryption-config \
  -n openshift-kube-apiserver \
  --from-file=encryption-config=encryption-config.yaml
```

---

## Step 5: Patch API Server Static Pods

You need to manually update the kube-apiserver static pod manifests on each control plane node to use the encryption configuration.

**SSH to each control plane node and run:**

```bash
# Backup the current manifest
sudo cp /etc/kubernetes/manifests/kube-apiserver-pod.yaml \
  /etc/kubernetes/manifests/kube-apiserver-pod.yaml.backup

# Edit the manifest
sudo vi /etc/kubernetes/manifests/kube-apiserver-pod.yaml
```

**Add these sections:**

1. In `spec.containers[name=kube-apiserver].command`, add:
```yaml
- --encryption-provider-config=/etc/kubernetes/encryption-config/encryption-config.yaml
```

2. In `spec.containers[name=kube-apiserver].volumeMounts`, add:
```yaml
- name: encryption-config
  mountPath: /etc/kubernetes/encryption-config
  readOnly: true
- name: kms-socket
  mountPath: /var/run/kmsplugin
```

3. In `spec.volumes`, add:
```yaml
- name: encryption-config
  secret:
    secretName: encryption-config
    defaultMode: 0600
- name: kms-socket
  hostPath:
    path: /var/run/kmsplugin
    type: DirectoryOrCreate
```

**The kubelet will automatically restart the API server pod when the manifest changes.**

---

## Step 6: Scale Operators Back Up

Once all control plane nodes have been updated:

```bash
# Scale kube-apiserver-operator back up
oc scale deployment/kube-apiserver-operator \
  -n openshift-kube-apiserver-operator --replicas=1

# Scale authentication-operator back up
oc scale deployment/authentication-operator \
  -n openshift-authentication-operator --replicas=1
```

**Verify operators are running:**
```bash
oc get deployment -n openshift-kube-apiserver-operator
oc get deployment -n openshift-authentication-operator
```

---

## Step 7: Verify Encryption is Working

### Check API Server Logs
```bash
oc logs -n openshift-kube-apiserver -l app=openshift-kube-apiserver | grep -i kms
```

Look for messages indicating successful KMS provider initialization.

### Test Secret Encryption
```bash
# Create a test secret
oc create secret generic test-encryption --from-literal=foo=bar

# Check if it's encrypted in etcd
oc get secret test-encryption -o yaml | grep "k8s:enc:kms"
```

If you see `k8s:enc:kms:v1:vault-kms:` prefix, encryption is working!

### Encrypt Existing Secrets
Force re-encryption of all existing secrets:

```bash
oc adm migrate storage secrets --confirm
```

This will re-encrypt all secrets using the new KMS provider.

---

## Step 8: Monitor and Verify

### Check KMS Plugin Health
```bash
# Check plugin pods
oc get pods -n openshift-kube-apiserver -l name=vault-kms-plugin

# Check plugin logs
oc logs -n openshift-kube-apiserver -l name=vault-kms-plugin
```

### Check Vault Metrics
```bash
# Login to Vault
oc exec -n vault vault-0 -- vault login root

# Check Transit engine usage
oc exec -n vault vault-0 -- vault read transit/keys/kubernetes-encryption
```

### Check API Server Health
```bash
oc get clusteroperators kube-apiserver
```

Should show `AVAILABLE=True, PROGRESSING=False, DEGRADED=False`

---

## Troubleshooting

### KMS Plugin Pods Not Starting
```bash
# Check pod status
oc describe pod -n openshift-kube-apiserver -l name=vault-kms-plugin

# Check credentials secret
oc get secret vault-kms-credentials -n openshift-kube-apiserver -o yaml
```

### API Server Not Starting
```bash
# SSH to control plane node
# Check kubelet logs
sudo journalctl -u kubelet -f

# Check static pod logs
sudo crictl logs <container-id>
```

### Encryption Not Working
```bash
# Test Vault connectivity from control plane node
curl http://vault.vault.svc.cluster.local:8200/v1/sys/health

# Test AppRole login
oc exec -n vault vault-0 -- vault write auth/approle/login \
  role_id="<ROLE_ID>" secret_id="<SECRET_ID>"
```

### Rollback Procedure
If you need to rollback:

1. Scale down operators (Step 6 in reverse)
2. Restore original API server manifests from backups
3. Wait for API servers to restart
4. Scale operators back up
5. Remove encryption configuration

---

## Security Considerations

### Production Recommendations

1. **Vault in Production Mode**
   - Do NOT use dev mode in production
   - Use Vault HA with proper storage backend (Consul, etcd, etc.)
   - Enable Vault auto-unsealing
   - Implement proper backup/disaster recovery

2. **Credential Management**
   - Rotate AppRole SecretIDs regularly
   - Use short token TTLs (1-4 hours)
   - Store credentials in a secure secrets manager
   - Never commit credentials to git

3. **Network Security**
   - Use TLS for Vault connections (https://)
   - Implement network policies to restrict access
   - Use Vault namespaces for isolation

4. **Monitoring & Auditing**
   - Enable Vault audit logging
   - Monitor KMS plugin metrics
   - Alert on encryption/decryption failures
   - Track Vault token usage

5. **Key Rotation**
   - Rotate Transit encryption keys periodically
   - Plan for key migration procedures
   - Test key rotation in non-production first

### Backup and Disaster Recovery

**Critical data to backup:**
- Vault storage backend
- AppRole credentials (vault-approle-credentials.txt)
- Encryption configuration files
- API server manifest backups

**Recovery procedure:**
1. Restore Vault from backup
2. Verify Transit key is accessible
3. Restore API server configurations
4. Verify decryption of existing secrets

---

## References

- [Vault Transit Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [Kubernetes KMS Encryption](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- [OpenShift etcd Encryption](https://docs.openshift.com/container-platform/latest/security/encrypting-etcd.html)

---

## Quick Command Reference

```bash
# Check operator status
oc get deployment -n openshift-kube-apiserver-operator
oc get deployment -n openshift-authentication-operator

# Check KMS plugin
oc get pods -n openshift-kube-apiserver -l name=vault-kms-plugin
oc logs -n openshift-kube-apiserver -l name=vault-kms-plugin

# Check Vault
oc get pods -n vault
oc exec -n vault vault-0 -- vault status

# Test encryption
oc create secret generic test-enc --from-literal=foo=bar
oc get secret test-enc -o yaml | grep "k8s:enc:kms"

# Migrate existing secrets
oc adm migrate storage secrets --confirm

# Check cluster operators
oc get clusteroperators
```

---

## Current Status

- [x] Scale down kube-apiserver-operator (0/0 replicas)
- [x] Scale down authentication-operator (0/0 replicas)
- [ ] Deploy Vault Transit Engine
- [ ] Apply KMS plugin configuration secret
- [ ] Deploy Vault KMS plugin DaemonSet
- [ ] Create encryption configuration
- [ ] Patch API server static pods
- [ ] Scale operators back up
- [ ] Verify encryption is working

---

**Last Updated:** 2026-01-16
**Status:** Operators scaled down, ready for KMS plugin deployment
