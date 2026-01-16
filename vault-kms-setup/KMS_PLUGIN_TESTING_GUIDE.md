# Testing KMS Plugin on Standard OpenShift Cluster

This guide provides steps to manually test a KMS plugin (e.g., HashiCorp Vault) on a standard OpenShift cluster by disabling the relevant operators and manually configuring encryption.

## Prerequisites

- Access to an OpenShift cluster with cluster-admin privileges
- `oc` CLI tool configured and authenticated
- Your KMS plugin container image available
- KMS service (e.g., Vault) accessible from the cluster

## Overview

The process involves:
1. Marking apiserver operators as Unmanaged
2. Scaling down the operators
3. Deploying the KMS plugin as a static pod on control plane nodes
4. Creating and injecting custom encryption configuration
5. Restarting apiservers to pick up the new configuration

---

## Step 1: Mark Operators as Unmanaged

First, we need to prevent the operators from managing the apiservers:

```bash
# Mark the Kubernetes API Server operator as Unmanaged
oc patch kubeapiserver cluster --type=merge -p '{"spec":{"managementState":"Unmanaged"}}'

# Mark the OpenShift API Server operator as Unmanaged
oc patch openshiftapiserver cluster --type=merge -p '{"spec":{"managementState":"Unmanaged"}}'

# Mark the Authentication operator as Unmanaged
oc patch authentication cluster --type=merge -p '{"spec":{"managementState":"Unmanaged"}}'
```

Verify the operators are marked as Unmanaged:

```bash
oc get kubeapiserver cluster -o jsonpath='{.spec.managementState}'
oc get openshiftapiserver cluster -o jsonpath='{.spec.managementState}'
oc get authentication cluster -o jsonpath='{.spec.managementState}'
```

---

## Step 2: Scale Down Operator Deployments

Scale down the operator deployments to prevent them from reverting changes:

```bash
# Scale down the Kube API Server operator
oc scale deployment kube-apiserver-operator -n openshift-kube-apiserver-operator --replicas=0

# Scale down the OpenShift API Server operator
oc scale deployment openshift-apiserver-operator -n openshift-apiserver-operator --replicas=0

# Scale down the Cluster Authentication operator
oc scale deployment authentication-operator -n openshift-authentication-operator --replicas=0
```

Verify the operators are scaled down:

```bash
oc get deployment -n openshift-kube-apiserver-operator kube-apiserver-operator
oc get deployment -n openshift-apiserver-operator openshift-apiserver-operator
oc get deployment -n openshift-authentication-operator authentication-operator
```

---

## Step 3: Deploy KMS Plugin as Static Pod

The KMS plugin needs to run as a static pod on all control plane nodes.

### 3.1 Create KMS Plugin Configuration

First, create the configuration for your KMS plugin (example for Vault):

```bash
# Create a ConfigMap with KMS plugin configuration
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kms-plugin-config
  namespace: openshift-kube-apiserver
data:
  vault-config.yaml: |
    # Your KMS plugin configuration
    # Example for Vault:
    vaultAddress: "https://vault.example.com:8200"
    vaultNamespace: "kms"
    tokenPath: "/var/run/secrets/vault/token"
EOF
```

### 3.2 Create Static Pod Manifest

Create the static pod manifest on each control plane node. You'll need to SSH to each control plane node:

```bash
# List control plane nodes
oc get nodes -l node-role.kubernetes.io/master

# For each control plane node, execute:
for node in $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}'); do
  echo "Configuring KMS plugin on node: $node"

  # Create the static pod manifest
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
    image: <YOUR_KMS_PLUGIN_IMAGE>
    imagePullPolicy: IfNotPresent
    command:
    - /kms-plugin
    args:
    - --listen=/var/run/kmsplugin/socket.sock
    - --config=/etc/kms-config/vault-config.yaml
    volumeMounts:
    - name: kmsplugin
      mountPath: /var/run/kmsplugin
    - name: kms-config
      mountPath: /etc/kms-config
      readOnly: true
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
  volumes:
  - name: kmsplugin
    hostPath:
      path: /var/run/kmsplugin
      type: DirectoryOrCreate
  - name: kms-config
    hostPath:
      path: /etc/kubernetes/kms-config
      type: DirectoryOrCreate
  priorityClassName: system-node-critical
EOF'
done
```

### 3.3 Verify KMS Plugin Pods are Running

```bash
# Check on each control plane node
oc get pods -n kube-system -o wide | grep kms-plugin
```

---

## Step 4: Create Encryption Configuration

Create the encryption configuration that references your KMS plugin:

```bash
cat <<EOF > encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - kms:
          name: vault-kms-plugin
          endpoint: unix:///var/run/kmsplugin/socket.sock
          cachesize: 1000
          timeout: 3s
      - identity: {}
EOF
```

---

## Step 5: Inject Encryption Configuration into API Servers

### 5.1 For Kubernetes API Server

```bash
# Create a Secret with the encryption configuration
oc create secret generic encryption-config \
  --from-file=encryption-config=encryption-config.yaml \
  -n openshift-kube-apiserver \
  --dry-run=client -o yaml | oc apply -f -

# Get the current kube-apiserver pod specification
oc get pod -n openshift-kube-apiserver -l app=openshift-kube-apiserver -o yaml > kube-apiserver-pod.yaml

# Edit the pod specification to add encryption configuration
# You need to add the following to the kube-apiserver container:
# 1. --encryption-provider-config=/etc/kubernetes/encryption-config/encryption-config.yaml
# 2. Mount the encryption-config secret as a volume
```

For each control plane node, update the static pod manifest:

```bash
for node in $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}'); do
  echo "Updating kube-apiserver on node: $node"

  oc debug node/$node -- chroot /host bash -c '
    # Backup the current configuration
    cp /etc/kubernetes/manifests/kube-apiserver-pod.yaml /etc/kubernetes/manifests/kube-apiserver-pod.yaml.backup

    # Copy the encryption config
    mkdir -p /etc/kubernetes/encryption-config
    cat > /etc/kubernetes/encryption-config/encryption-config.yaml <<EOC
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - kms:
          name: vault-kms-plugin
          endpoint: unix:///var/run/kmsplugin/socket.sock
          cachesize: 1000
          timeout: 3s
      - identity: {}
EOC
  '
done
```

### 5.2 Update Kube API Server Static Pod

You need to modify the kube-apiserver static pod to:
1. Add the `--encryption-provider-config` flag
2. Mount the encryption configuration
3. Mount the KMS plugin socket

```bash
for node in $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}'); do
  echo "Patching kube-apiserver on node: $node"

  oc debug node/$node -- chroot /host bash -c '
    # Edit the kube-apiserver manifest
    # This is a complex operation - you may need to do this manually
    # Add the following to the kube-apiserver container args:
    # - --encryption-provider-config=/etc/kubernetes/encryption-config/encryption-config.yaml

    # Add these volume mounts:
    # - mountPath: /etc/kubernetes/encryption-config
    #   name: encryption-config
    # - mountPath: /var/run/kmsplugin
    #   name: kmsplugin

    # Add these volumes:
    # - hostPath:
    #     path: /etc/kubernetes/encryption-config
    #     type: DirectoryOrCreate
    #   name: encryption-config
    # - hostPath:
    #     path: /var/run/kmsplugin
    #     type: DirectoryOrCreate
    #   name: kmsplugin

    # The kubelet will automatically restart the pod when the manifest changes
  '
done
```

### 5.3 For OpenShift API Server

Similar process for the OpenShift API Server:

```bash
for node in $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}'); do
  echo "Updating openshift-apiserver on node: $node"

  oc debug node/$node -- chroot /host bash -c '
    # Backup the current configuration
    cp /etc/kubernetes/manifests/openshift-apiserver-pod.yaml /etc/kubernetes/manifests/openshift-apiserver-pod.yaml.backup 2>/dev/null || true

    # Apply similar changes to openshift-apiserver
    # Add encryption configuration and KMS plugin socket mount
  '
done
```

---

## Step 6: Verify KMS Plugin is Working

### 6.1 Check API Server Logs

```bash
# Check kube-apiserver logs for KMS plugin communication
oc logs -n openshift-kube-apiserver -l app=openshift-kube-apiserver --tail=100 | grep -i kms

# Check for any errors
oc logs -n openshift-kube-apiserver -l app=openshift-kube-apiserver --tail=100 | grep -i error
```

### 6.2 Test Encryption

Create a test secret and verify it's encrypted:

```bash
# Create a test secret
oc create secret generic test-kms-secret \
  --from-literal=password=supersecret \
  -n default

# Verify the secret is encrypted in etcd
# You'll need to access etcd directly for this
oc get secret test-kms-secret -n default -o yaml

# The secret should be encrypted via KMS in etcd
# You can verify by checking etcd directly:
oc exec -n openshift-etcd etcd-<control-plane-node> -- \
  etcdctl get /kubernetes.io/secrets/default/test-kms-secret \
  --print-value-only | hexdump -C
```

### 6.3 Check KMS Plugin Logs

```bash
# Check KMS plugin logs on control plane nodes
oc debug node/<control-plane-node> -- chroot /host crictl logs <kms-plugin-container-id>
```

---

## Step 7: Migrate Existing Secrets (Optional)

If you want to re-encrypt existing secrets with the new KMS plugin:

```bash
# This will read and write all secrets, triggering re-encryption
oc get secrets --all-namespaces -o json | \
  oc replace -f -
```

**Warning**: This operation can be resource-intensive on large clusters.

---

## Troubleshooting

### KMS Plugin Not Responding

```bash
# Check if the socket exists
for node in $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}'); do
  echo "Checking socket on node: $node"
  oc debug node/$node -- chroot /host ls -la /var/run/kmsplugin/
done

# Check KMS plugin logs
oc debug node/<node> -- chroot /host crictl logs <container-id>
```

### API Server Fails to Start

```bash
# Check kubelet logs
oc debug node/<node> -- chroot /host journalctl -u kubelet -n 100

# Check for static pod errors
oc debug node/<node> -- chroot /host ls -la /etc/kubernetes/manifests/
```

### Restore to Original State

If you need to revert the changes:

```bash
# Remove encryption configuration
for node in $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}'); do
  oc debug node/$node -- chroot /host bash -c '
    # Restore backups
    cp /etc/kubernetes/manifests/kube-apiserver-pod.yaml.backup /etc/kubernetes/manifests/kube-apiserver-pod.yaml 2>/dev/null || true

    # Remove KMS plugin static pod
    rm /etc/kubernetes/manifests/kms-plugin.yaml 2>/dev/null || true

    # Remove encryption config
    rm -rf /etc/kubernetes/encryption-config 2>/dev/null || true
  '
done

# Scale operators back up
oc scale deployment kube-apiserver-operator -n openshift-kube-apiserver-operator --replicas=1
oc scale deployment openshift-apiserver-operator -n openshift-apiserver-operator --replicas=1
oc scale deployment authentication-operator -n openshift-authentication-operator --replicas=1

# Mark operators as Managed again
oc patch kubeapiserver cluster --type=merge -p '{"spec":{"managementState":"Managed"}}'
oc patch openshiftapiserver cluster --type=merge -p '{"spec":{"managementState":"Managed"}}'
oc patch authentication cluster --type=merge -p '{"spec":{"managementState":"Managed"}}'
```

---

## Important Notes

1. **Testing Environment**: These steps should only be performed on test/development clusters, not production
2. **Backup**: Always backup your cluster configuration before making these changes
3. **Static Pods**: Changes to static pod manifests in `/etc/kubernetes/manifests/` are automatically detected by kubelet
4. **Socket Path**: Ensure the KMS plugin socket path matches the path in the encryption configuration
5. **Permissions**: The KMS plugin must have appropriate permissions to access the KMS service (e.g., Vault tokens)
6. **Network**: Ensure network connectivity between API servers and the KMS service
7. **High Availability**: The KMS plugin should be available on all control plane nodes for HA

---

## Additional Resources

- [Kubernetes Encryption at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [KMS Plugin Documentation](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- [OpenShift API Server Configuration](https://docs.openshift.com/container-platform/latest/security/encrypting-etcd.html)

---

## Support

For issues specific to the KMS plugin implementation, contact your KMS provider (e.g., HashiCorp for Vault KMS plugin).

For OpenShift-specific issues, refer to Red Hat support or OpenShift documentation.
