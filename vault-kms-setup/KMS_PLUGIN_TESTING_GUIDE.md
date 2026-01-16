# KMS Plugin Testing Guide for OpenShift

This guide provides step-by-step instructions for testing a KMS (Key Management Service) plugin on an OpenShift cluster by manually configuring encryption.

## ⚠️ Important Warnings

- **Test/Development Clusters Only**: These procedures should NEVER be performed on production clusters
- **Backup Required**: Always backup your cluster configuration before proceeding
- **Cluster Risk**: Incorrect configuration can render your cluster unusable
- **Recovery Plan**: Have a documented recovery/rollback procedure ready

## Prerequisites

- OpenShift 4.x cluster with cluster-admin privileges
- `oc` CLI tool configured and authenticated
- KMS plugin container image available
- KMS service (e.g., Vault) accessible from the cluster
- Control plane node access (SSH or `oc debug node`)

## Architecture Overview

```
┌─────────────────┐      ┌──────────────────┐      ┌─────────────┐
│ kube-apiserver  │─────▶│  KMS Plugin Pod  │─────▶│  KMS Service│
│                 │ unix │  (Static Pod)    │ API  │  (Vault)    │
└─────────────────┘socket└──────────────────┘      └─────────────┘
        │                                                  │
        └──────────────────────────────────────────────────┘
                    Encrypt/Decrypt Operations
```

---

## Step 1: Scale Down Operators

**Important Note**: The `kubeapiserver` and `authentication` resources do NOT support `managementState: Unmanaged`. You can only scale down the operator deployments.

```bash
# Scale down the kube-apiserver-operator
oc scale deployment/kube-apiserver-operator \
  -n openshift-kube-apiserver-operator --replicas=0

# Scale down the authentication-operator
oc scale deployment/authentication-operator \
  -n openshift-authentication-operator --replicas=0
```

Verify operators are scaled down:

```bash
oc get deployment -n openshift-kube-apiserver-operator
oc get deployment -n openshift-authentication-operator
```

Expected output:
```
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
kube-apiserver-operator   0/0     0            0           XXm
authentication-operator   0/0     0            0           XXm
```

---

## Step 2: Deploy KMS Plugin

The KMS plugin must run on all control plane nodes. You have two deployment options:

### Option A: DaemonSet (Recommended)

Create a KMS plugin DaemonSet:

```bash
cat > kms-plugin-daemonset.yaml <<'EOF'
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

# Create credentials secret first
oc create secret generic vault-kms-credentials \
  -n openshift-kube-apiserver \
  --from-literal=role-id="<YOUR_ROLE_ID>" \
  --from-literal=secret-id="<YOUR_SECRET_ID>"

# Deploy the DaemonSet
oc apply -f kms-plugin-daemonset.yaml
```

Verify KMS plugin pods are running:

```bash
oc get pods -n openshift-kube-apiserver -l name=vault-kms-plugin -o wide
```

### Option B: Static Pods

If you prefer static pods, create the manifest on each control plane node:

```bash
# Get control plane nodes
CONTROL_PLANE_NODES=$(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}')

# For each node
for node in $CONTROL_PLANE_NODES; do
  echo "Deploying KMS plugin on node: $node"

  oc debug node/$node -- chroot /host bash -c 'cat > /etc/kubernetes/manifests/kms-plugin.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kms-plugin
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kms-plugin
    image: registry.k8s.io/kms/vault:v0.9.0
    command:
    - /kms-plugin
    args:
    - --listen=/var/run/kmsplugin/socket.sock
    - --vault-address=http://vault.vault.svc.cluster.local:8200
    - --vault-transit-path=transit
    - --vault-transit-key=kubernetes-encryption
    volumeMounts:
    - name: kmsplugin
      mountPath: /var/run/kmsplugin
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
  volumes:
  - name: kmsplugin
    hostPath:
      path: /var/run/kmsplugin
      type: DirectoryOrCreate
  priorityClassName: system-node-critical
EOF'
done
```

---

## Step 3: Create Encryption Configuration

Create the encryption configuration file:

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

Create the encryption configuration secret:

```bash
oc create secret generic encryption-config \
  -n openshift-kube-apiserver \
  --from-file=encryption-config=encryption-config.yaml
```

---

## Step 4: Patch API Server Static Pods

You need to manually update the kube-apiserver static pod manifests on each control plane node.

### 4.1 Backup Current Configuration

```bash
for node in $(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}'); do
  echo "Backing up kube-apiserver manifest on node: $node"

  oc debug node/$node -- chroot /host bash -c '
    cp /etc/kubernetes/manifests/kube-apiserver-pod.yaml \
       /etc/kubernetes/manifests/kube-apiserver-pod.yaml.backup

    mkdir -p /etc/kubernetes/encryption-config
  '
done
```

### 4.2 Copy Encryption Configuration

```bash
for node in $(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}'); do
  echo "Deploying encryption config on node: $node"

  oc debug node/$node -- chroot /host bash -c 'cat > /etc/kubernetes/encryption-config/encryption-config.yaml <<EOF
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
EOF'
done
```

### 4.3 Manual Manifest Update

For each control plane node, you need to manually edit the kube-apiserver manifest:

```bash
# Access the node
oc debug node/<NODE_NAME> -- chroot /host bash

# Edit the manifest
vi /etc/kubernetes/manifests/kube-apiserver-pod.yaml
```

**Add to `spec.containers[name=kube-apiserver].command`:**
```yaml
- --encryption-provider-config=/etc/kubernetes/encryption-config/encryption-config.yaml
```

**Add to `spec.containers[name=kube-apiserver].volumeMounts`:**
```yaml
- name: encryption-config
  mountPath: /etc/kubernetes/encryption-config
  readOnly: true
- name: kms-socket
  mountPath: /var/run/kmsplugin
```

**Add to `spec.volumes`:**
```yaml
- name: encryption-config
  hostPath:
    path: /etc/kubernetes/encryption-config
    type: DirectoryOrCreate
- name: kms-socket
  hostPath:
    path: /var/run/kmsplugin
    type: DirectoryOrCreate
```

**Save the file. The kubelet will automatically restart the API server pod.**

---

## Step 5: Verify Configuration

### 5.1 Check API Server Pods

```bash
# Check that API server pods are running
oc get pods -n openshift-kube-apiserver -l app=openshift-kube-apiserver

# Check logs for KMS-related messages
oc logs -n openshift-kube-apiserver -l app=openshift-kube-apiserver --tail=50 | grep -i kms
```

Expected log entries:
```
I0116 loaded encryption config: vault-kms
I0116 KMS plugin vault-kms initialized successfully
```

### 5.2 Check KMS Plugin

```bash
# Check KMS plugin pods
oc get pods -n openshift-kube-apiserver -l name=vault-kms-plugin

# Check KMS plugin logs
oc logs -n openshift-kube-apiserver -l name=vault-kms-plugin --tail=50
```

### 5.3 Verify Socket Connectivity

```bash
# Check that socket exists on each control plane node
for node in $(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}'); do
  echo "Checking socket on node: $node"
  oc debug node/$node -- chroot /host ls -la /var/run/kmsplugin/socket.sock
done
```

---

## Step 6: Test Encryption

### 6.1 Create Test Secret

```bash
# Create a test secret
oc create secret generic test-kms-encryption \
  --from-literal=password=supersecret \
  -n default
```

### 6.2 Verify Secret is Encrypted

```bash
# Get the secret
oc get secret test-kms-encryption -n default -o yaml

# Look for encryption metadata
# The secret should have metadata indicating KMS encryption
```

### 6.3 Verify in etcd (Optional)

If you have etcd access:

```bash
# Access etcd pod
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.name}')

# Check the secret in etcd (it should be encrypted)
oc exec -n openshift-etcd $ETCD_POD -- etcdctl get \
  /kubernetes.io/secrets/default/test-kms-encryption \
  --print-value-only | hexdump -C

# Should show encrypted data starting with "k8s:enc:kms:v1:vault-kms:"
```

### 6.4 Test Decryption

```bash
# Retrieve the secret - if decryption works, you'll see the value
oc get secret test-kms-encryption -n default -o jsonpath='{.data.password}' | base64 -d

# Should output: supersecret
```

---

## Step 7: Migrate Existing Secrets (Optional)

To re-encrypt existing secrets with the new KMS plugin:

```bash
# Re-encrypt all secrets in a specific namespace
oc get secrets -n <namespace> -o json | oc replace -f -

# Or use the storage migration tool (if available)
oc adm migrate storage secrets --confirm
```

**Warning**: This can be resource-intensive on large clusters.

---

## Step 8: Scale Operators Back Up

Once everything is verified and working:

```bash
# Scale kube-apiserver-operator back up
oc scale deployment/kube-apiserver-operator \
  -n openshift-kube-apiserver-operator --replicas=1

# Scale authentication-operator back up
oc scale deployment/authentication-operator \
  -n openshift-authentication-operator --replicas=1
```

Verify operators are running:

```bash
oc get deployment -n openshift-kube-apiserver-operator
oc get deployment -n openshift-authentication-operator
```

**Note**: The operators will now manage the API servers again. Ensure your KMS configuration persists through operator reconciliation.

---

## Troubleshooting

### Issue: API Server Won't Start

**Symptoms**: API server pods in CrashLoopBackOff

**Check**:
```bash
# Check API server logs
oc logs -n openshift-kube-apiserver -l app=openshift-kube-apiserver --tail=100

# Check kubelet logs on control plane node
oc debug node/<node> -- chroot /host journalctl -u kubelet -n 100
```

**Common causes**:
- Encryption config file not found
- KMS socket not accessible
- KMS plugin not running
- Invalid encryption configuration syntax

**Solution**:
1. Verify encryption config exists: `/etc/kubernetes/encryption-config/encryption-config.yaml`
2. Verify KMS socket exists: `/var/run/kmsplugin/socket.sock`
3. Check KMS plugin is running and healthy

### Issue: KMS Plugin Not Responding

**Symptoms**: API server logs show KMS timeout errors

**Check**:
```bash
# Check KMS plugin logs
oc logs -n openshift-kube-apiserver -l name=vault-kms-plugin

# Check socket permissions
oc debug node/<node> -- chroot /host ls -la /var/run/kmsplugin/
```

**Solution**:
1. Verify Vault service is accessible
2. Verify AppRole credentials are correct
3. Check network connectivity between KMS plugin and Vault
4. Increase timeout in encryption config if needed

### Issue: Secrets Not Being Encrypted

**Symptoms**: New secrets are created but not encrypted via KMS

**Check**:
```bash
# Verify encryption config is loaded
oc logs -n openshift-kube-apiserver -l app=openshift-kube-apiserver | grep encryption

# Create test secret and check
oc create secret generic test-check --from-literal=foo=bar
oc get secret test-check -o yaml
```

**Solution**:
1. Verify `--encryption-provider-config` flag is present in API server command
2. Verify encryption config mounts are correct
3. Restart API server pods if needed

### Issue: Can't Access Secrets After Enabling Encryption

**Symptoms**: Secrets become unreadable

**Cause**: Encryption config may be using KMS-only without fallback

**Solution**: Ensure `identity: {}` provider is listed after KMS provider in encryption config

---

## Rollback Procedure

If you need to revert all changes:

### Step 1: Remove Encryption Configuration

```bash
for node in $(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}'); do
  echo "Restoring configuration on node: $node"

  oc debug node/$node -- chroot /host bash -c '
    # Restore original kube-apiserver manifest
    if [ -f /etc/kubernetes/manifests/kube-apiserver-pod.yaml.backup ]; then
      cp /etc/kubernetes/manifests/kube-apiserver-pod.yaml.backup \
         /etc/kubernetes/manifests/kube-apiserver-pod.yaml
    fi

    # Remove KMS plugin static pod (if using static pods)
    rm -f /etc/kubernetes/manifests/kms-plugin.yaml

    # Remove encryption config
    rm -rf /etc/kubernetes/encryption-config
  '
done
```

### Step 2: Remove KMS Plugin DaemonSet

```bash
# If using DaemonSet
oc delete daemonset vault-kms-plugin -n openshift-kube-apiserver

# Delete credentials secret
oc delete secret vault-kms-credentials -n openshift-kube-apiserver
```

### Step 3: Scale Operators Back Up

```bash
oc scale deployment/kube-apiserver-operator \
  -n openshift-kube-apiserver-operator --replicas=1

oc scale deployment/authentication-operator \
  -n openshift-authentication-operator --replicas=1
```

### Step 4: Verify Cluster is Healthy

```bash
# Check cluster operators
oc get clusteroperators

# All should show AVAILABLE=True, PROGRESSING=False, DEGRADED=False
```

---

## Important Notes

### Critical Considerations

1. **Socket Path Consistency**: The socket path must match exactly between:
   - KMS plugin `--listen` flag
   - Encryption config `endpoint`
   - Volume mount paths

2. **All Control Plane Nodes**: Changes must be applied to ALL control plane nodes for HA

3. **Backup Everything**: Always maintain backups of:
   - API server manifests
   - Encryption configurations
   - KMS credentials

4. **Testing Only**: This procedure is for test/dev clusters only

5. **Operators**: Once operators are scaled back up, they may revert your manual changes unless properly configured

### Security Best Practices

1. **Credentials**: Store Vault credentials securely in Kubernetes secrets
2. **RBAC**: Limit access to KMS plugin credentials
3. **Network**: Use network policies to restrict access to KMS plugin
4. **Audit**: Enable audit logging to track encryption events
5. **Rotation**: Implement regular credential rotation

---

## Additional Resources

- [Kubernetes Encryption at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [KMS Provider Documentation](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- [OpenShift etcd Encryption](https://docs.openshift.com/container-platform/latest/security/encrypting-etcd.html)
- [HashiCorp Vault Transit Engine](https://developer.hashicorp.com/vault/docs/secrets/transit)

---

## Support

- For Vault-specific issues: [HashiCorp Vault Community](https://discuss.hashicorp.com/c/vault)
- For OpenShift issues: [Red Hat Support](https://access.redhat.com/support)
- For this guide: Check the repository issues page
