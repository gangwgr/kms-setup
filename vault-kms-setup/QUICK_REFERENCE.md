# KMS Plugin Testing - Quick Reference

Quick command reference for testing KMS plugins on OpenShift.

## 1. Mark Operators as Unmanaged and Scale Down

```bash
# Mark as Unmanaged
oc patch kubeapiserver cluster --type=merge -p '{"spec":{"managementState":"Unmanaged"}}'
oc patch openshiftapiserver cluster --type=merge -p '{"spec":{"managementState":"Unmanaged"}}'
oc patch authentication cluster --type=merge -p '{"spec":{"managementState":"Unmanaged"}}'

# Scale down operators
oc scale deployment kube-apiserver-operator -n openshift-kube-apiserver-operator --replicas=0
oc scale deployment openshift-apiserver-operator -n openshift-apiserver-operator --replicas=0
oc scale deployment authentication-operator -n openshift-authentication-operator --replicas=0
```

## 2. Deploy KMS Plugin on All Control Plane Nodes

```bash
# Get control plane nodes
oc get nodes -l node-role.kubernetes.io/master

# For each node, create static pod manifest
# SSH or use oc debug to access each node
oc debug node/<NODE_NAME> -- chroot /host bash

# Then on the node, create the manifest
cat > /etc/kubernetes/manifests/kms-plugin.yaml <<'EOF'
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
    command:
    - /kms-plugin
    args:
    - --listen=/var/run/kmsplugin/socket.sock
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
EOF
```

## 3. Create Encryption Configuration on Each Node

```bash
# On each control plane node
mkdir -p /etc/kubernetes/encryption-config

cat > /etc/kubernetes/encryption-config/encryption-config.yaml <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - kms:
          name: vault-kms-plugin
          endpoint: unix:///var/run/kmsplugin/socket.sock
          cachesize: 1000
          timeout: 3s
      - identity: {}
EOF
```

## 4. Modify Kube API Server Static Pod

On each control plane node, edit `/etc/kubernetes/manifests/kube-apiserver-pod.yaml`:

**Add to container args:**
```yaml
- --encryption-provider-config=/etc/kubernetes/encryption-config/encryption-config.yaml
```

**Add to volumeMounts:**
```yaml
- mountPath: /etc/kubernetes/encryption-config
  name: encryption-config
  readOnly: true
- mountPath: /var/run/kmsplugin
  name: kmsplugin
```

**Add to volumes:**
```yaml
- hostPath:
    path: /etc/kubernetes/encryption-config
    type: DirectoryOrCreate
  name: encryption-config
- hostPath:
    path: /var/run/kmsplugin
    type: DirectoryOrCreate
  name: kmsplugin
```

## 5. Verify

```bash
# Check KMS plugin pods
oc get pods -n kube-system | grep kms-plugin

# Check API server logs
oc logs -n openshift-kube-apiserver -l app=openshift-kube-apiserver --tail=50 | grep -i kms

# Test with a secret
oc create secret generic test-kms --from-literal=key=value
oc get secret test-kms -o yaml
```

## 6. Restore (if needed)

```bash
# Remove static pods and configs from each node
rm /etc/kubernetes/manifests/kms-plugin.yaml
rm -rf /etc/kubernetes/encryption-config

# Restore the kube-apiserver manifest from backup

# Scale operators back up
oc scale deployment kube-apiserver-operator -n openshift-kube-apiserver-operator --replicas=1
oc scale deployment openshift-apiserver-operator -n openshift-apiserver-operator --replicas=1
oc scale deployment authentication-operator -n openshift-authentication-operator --replicas=1

# Mark as Managed
oc patch kubeapiserver cluster --type=merge -p '{"spec":{"managementState":"Managed"}}'
oc patch openshiftapiserver cluster --type=merge -p '{"spec":{"managementState":"Managed"}}'
oc patch authentication cluster --type=merge -p '{"spec":{"managementState":"Managed"}}'
```

## Important Notes

- **Backup first**: `cp /etc/kubernetes/manifests/kube-apiserver-pod.yaml /etc/kubernetes/manifests/kube-apiserver-pod.yaml.backup`
- **Test environment only**: Never do this on production
- **All control plane nodes**: Changes must be applied to ALL control plane nodes
- **Socket path**: Must match between KMS plugin and encryption config (`/var/run/kmsplugin/socket.sock`)
