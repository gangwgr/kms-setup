# KMS Key Loss & etcd Data Recovery Test Report

**Jira:** CNTRLPLANE-17  
**Cluster:** OpenShift 4.22.0-0.nightly-2026-03-22-201225  
**Platform:** AWS (us-west-1)  
**KMS Provider:** HashiCorp Vault (HCP) Transit Engine  
**Date:** March 23, 2026  
**Tester:** Ravi Gangwar

---

## Test Environment

| Component | Details |
|-----------|---------|
| OpenShift Version | 4.22.0-0.nightly-2026-03-22-201225 |
| Vault | HCP Vault (ocp-dav-vault-cluster-public) |
| Transit Key | `kms-key` (aes256-gcm96) |
| KMS Plugin | vault-kube-kms (3 pods on control plane nodes) |
| Encryption Type | KMS (etcd encryption via `spec.encryption.type: KMS`) |
| FeatureGate | TechPreviewNoUpgrade |
| Control Plane Nodes | 3 (ip-10-0-116-84, ip-10-0-118-22, ip-10-0-27-178) |

### Pre-Test State
- All 35 cluster operators: Available=True, Degraded=False
- KMS plugin pods: 3/3 Running
- etcd encryption status: EncryptionCompleted
- Approximate secrets in etcd: 700-800

---

## Scenario 1: Vault Transit Key Deletion (Full Key Loss)

### Description
Simulates complete loss of the KMS encryption key by deleting the Vault Transit key used for etcd encryption.

### Steps Performed
1. Verified Transit key exists (`kms-key`, type=aes256-gcm96, version=1)
2. Enabled key deletion (`deletion_allowed=true`)
3. Deleted the Transit key from Vault
4. Confirmed key no longer exists (HTTP 404)

### Impact
| Component | Effect |
|-----------|--------|
| kube-apiserver | **Complete outage** — `Unable to connect to the server: dial tcp 20.237.193.191:6443: i/o timeout` |
| All `oc` commands | Non-functional (API server unreachable) |
| KMS plugin pods | Running but unable to decrypt (Transit key missing) |
| Encrypted resources | All KMS-encrypted secrets/configmaps undecryptable |

### Severity: **Critical — Full cluster API outage**

The kube-apiserver crash-looped because it could not decrypt critical resources (serving certs, SA tokens, etc.) from etcd. The entire cluster became unreachable.

### Recovery
1. Recreated the Transit key in Vault: `vault write -f transit/keys/kms-key type=aes256-gcm96`
2. The new key has **different key material** — old encrypted data remains undecryptable
3. KMS plugin pods began using the new key for new encrypt operations
4. kube-apiserver recovered and became reachable again
5. Operators detected missing/undecryptable resources and began recreating them
6. Cluster returned to healthy state with all operators Available=True

### Key Finding
> **A complete KMS Transit key deletion causes total API server outage.** Recovery requires recreating the key in Vault. The old encrypted data is permanently lost, but OpenShift operators successfully recreate their managed secrets and configmaps. Full cluster recovery took approximately 20-30 minutes.

---

## Scenario 2: Delete All Secrets from etcd

### Description
Deletes all secrets directly from etcd using `etcdctl`, bypassing the Kubernetes API server entirely. This tests whether OpenShift operators can self-heal when their managed secrets are removed at the storage layer.

### Steps Performed
1. Took etcd backup (`cluster-backup.sh`)
2. Enumerated all secret keys in etcd across all namespaces (~700-800 secrets)
3. Deleted all secrets from etcd via `etcdctl del`

### Impact — Progressive Failure

The failure is **not immediate**. The cluster degrades progressively over several minutes:

**Phase 1 — Operators Degrade (first few minutes):**
Operators detect missing secrets and enter Degraded state. The API server is still accessible during this phase:

| Operator | Degraded Reason |
|----------|----------------|
| authentication | `CustomRouteControllerDegraded: Internal error occurred: no matching prefix found` |
| cloud-credential | `5 of 7 credentials requests are failing to sync` |
| machine-config | `error fetching cluster pull secret: secret "pull-secret" not found` |
| image-registry | `unable to get cluster minted credentials "installer-cloud-credentials"` |
| kube-apiserver | Progressing — rolling out new revisions |
| etcd | Progressing — `NodeInstallerProgressing: 1 node is at revision 9` |
| openshift-apiserver | Progressing — `3/3 pods have been updated, 2/3 pods available` |
| storage | Progressing — `Waiting for Deployment to deploy` |

**Phase 2 — Cluster Becomes Inaccessible (after some time):**
As TLS certificates expire from in-memory caches and kube-apiserver attempts to reload now-missing serving certs, the API server stops responding:
```
oc get co
Error from server (Timeout): the server was unable to return a response in the time allotted,
but may still be processing the request (get clusteroperators.config.openshift.io)
```

This progressive failure occurs because:
- Initially, kube-apiserver still has TLS certs loaded in memory from before the deletion
- As the apiserver rolls out new revisions or restarts, it cannot find its serving certificates
- etcd client certificates are missing, breaking etcd communication
- Service account token signing keys are gone, invalidating all pod API access

### Severity: **Critical — Progressive degradation leading to full cluster outage**

Unlike the key deletion scenario (which causes immediate outage), deleting all secrets causes a **delayed outage**. The cluster remains partially functional initially while operators degrade, then becomes fully inaccessible as the kube-apiserver loses its cached certificates.

### Recovery
**The cluster does NOT self-heal from this scenario.** This is a chicken-and-egg problem:
- Operators need the API server to recreate secrets
- The API server needs its TLS certs (which are secrets) to run
- Neither can recover without the other

**etcd restore is the only recovery path:**
```
# SSH to a control plane node (oc debug may not work if API is down)
ssh -i <key>.pem core@<node-ip>
sudo -i
/usr/local/bin/cluster-restore.sh /home/core/assets/backup_before_delete_<timestamp>
```

### Key Finding
> **Deleting ALL secrets from etcd causes a progressive, unrecoverable cluster failure.** Operators degrade first while cached certificates are still in memory, then the cluster becomes permanently inaccessible once those caches expire. Unlike scoped deletion (operator namespaces only), deleting secrets from **all** namespaces creates a deadlock: the kube-apiserver cannot start without its serving certificates, and operators cannot recreate certificates without a functioning API server. **Recovery requires restoring etcd from backup.** This underscores the critical importance of taking an etcd backup before any destructive operation.

---

## Scenario 3: etcd Data Corruption (Corrupted Secret)

### Description
Simulates data corruption in etcd by writing invalid (non-Kubernetes) data directly to an etcd key that represents a secret. This tests how the platform handles malformed data at the storage layer.

### Steps Performed
1. Created a test namespace and secret:
   ```
   oc create ns test
   oc create secret generic mysecret1 --from-literal=password="SuperSecure123" -n test
   ```
2. Wrote corrupted data directly to etcd:
   ```
   etcdctl put /kubernetes.io/secrets/test/test-secret "corrupted-data"
   ```
3. Attempted to read the corrupted secret via API:
   ```
   oc get secret test-secret -n test
   Error from server: illegal base64 data at input byte 9
   ```

### Impact
The corrupted secret caused cascading errors across operators that list secrets:

| Operator | Degraded Reason |
|----------|----------------|
| authentication | `EncryptionKeyControllerDegraded: failed to list *core.Secret: illegal base64 data at input byte 9` |
| openshift-apiserver | `EncryptionKeyControllerDegraded: failed to list *core.Secret: illegal base64 data at input byte 9` |
| kube-apiserver | `InstallerControllerDegraded: missing required resources` |
| cluster-api | `Failed to resync because unable to clear token secret data` |

### Severity: **High — Single corrupted entry poisons list operations**

A single corrupted secret in etcd caused operators that perform `List` operations on secrets to fail, since the API server returns an error when it encounters the malformed data during deserialization.

### Recovery
1. Deleted the corrupted key directly from etcd:
   ```
   etcdctl del /kubernetes.io/secrets/test/test-secret
   ```
2. All operators recovered: Available=True, Degraded=False
3. Recovery was immediate once the corrupted entry was removed

### Key Finding
> **A single corrupted entry in etcd can degrade multiple cluster operators** because operators that list secrets encounter the deserialization error. The fix is straightforward: identify and delete the corrupted entry from etcd. Recovery is immediate. This highlights the importance of etcd data integrity and the blast radius of corruption.

---

## Summary of Findings

| Scenario | API Server Impact | Recovery Method | Recovery Time | Manual Intervention |
|----------|------------------|-----------------|---------------|-------------------|
| **Key Deletion** | Immediate outage | Recreate Transit key in Vault | 20-30 min | Required (Vault admin) |
| **All Secrets Deleted** | Progressive then permanent outage | **etcd restore required** | Depends on restore | Required (etcd backup restore) |
| **Data Corruption** | Accessible but degraded | Delete corrupted etcd key | Immediate | Required (etcd admin) |

### Overall Conclusions

1. **Deleting ALL secrets from etcd is unrecoverable without backup.** When every secret across all namespaces is deleted, the cluster enters a deadlock: the API server cannot start without its TLS certificates (stored as secrets), and operators cannot recreate certificates without a functioning API server. **etcd backup restore is the only recovery path.**

2. **Key deletion and all-secret deletion both cause outages, but with different patterns.** Key deletion causes immediate outage (undecryptable data); all-secret deletion causes progressive outage (degraded first, then inaccessible as cached certs expire). Key deletion requires Vault admin intervention; all-secret deletion requires etcd backup restore.

3. **Data corruption has a disproportionate blast radius.** A single corrupted secret in etcd can degrade multiple operators that perform list operations. The corruption must be identified and removed manually from etcd.

4. **etcd backup is essential before destructive operations.** The `cluster-backup.sh` script should be used before any destructive testing. For all-namespace secret deletion scenarios, recovery without backup relies entirely on operator self-healing.

5. **KMS encryption adds a critical dependency.** The availability of the Vault Transit key becomes a hard dependency for cluster functionality. Key management practices (backup, rotation policies, access controls) are critical for production deployments.

---

## Test Scripts Used

| Script | Purpose |
|--------|---------|
| `deploy-kms-st-pod.sh` | Deploy KMS plugin as static pods on control plane nodes |
| `kms-key-loss-test.sh` | Automated test scenarios (key deletion, corruption, etcd deletion) |
| `etcd-backup-restore-kms.sh` | etcd backup and restore with KMS verification |

### Available Test Actions (`kms-key-loss-test.sh`)

```
Key Loss Test:
  --full-test              Full key loss simulation and recovery test
  --simulate-key-loss      Delete the Vault Transit key (DESTRUCTIVE)
  --delete-undecryptable   Find and delete undecryptable resources
  --recover-kms            Create new Transit key and restore KMS

Key Corruption Test:
  --corrupt-key            Rotate key + set min_decryption_version (reversible)
  --recover-corrupted-key  Undo corruption by resetting min_decryption_version

Direct etcd Deletion Tests:
  --delete-etcd-secrets    Delete secrets from etcd via etcdctl
  --delete-etcd-configmaps Delete configmaps from etcd via etcdctl
    (add --all-namespaces to target every namespace)

Common Options:
  --dry-run                Preview without deleting
  --username / --password  Vault userpass authentication
  --all-namespaces         Target all namespaces (mandatory etcd backup taken first)
```
