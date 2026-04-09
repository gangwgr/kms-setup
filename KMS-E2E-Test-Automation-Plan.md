# KMS E2E Test Automation Plan

**Authors**: Rahul & Lukasz  
**Date**: April 2026  
**Status**: Draft  
**Jira**: CNTRLPLANE-2241 (KMS Encryption Provider)

---

## 1. Background

OpenShift 4.22 introduces KMS encryption at rest via `apiserver.spec.encryption.type=KMS`.
The initial provider is **HashiCorp Vault** (via the `vault-kube-kms` plugin), with potential
future support for AWS KMS and Azure Key Vault.

The KMS v2 gRPC protocol is provider-agnostic — each provider is a binary that implements
`Status`, `Encrypt`, and `Decrypt` on a unix socket (`/var/run/kmsplugin/kms.sock`). The
kube-apiserver connects to this socket regardless of which provider backs it.

```
apiserver.spec.encryption.type = "KMS"     (same for all KMS providers)
                    │
                    ▼
        ┌──────────────────────┐
        │  kube-apiserver       │
        │  EncryptionConfig:    │
        │    kms:               │
        │      apiVersion: v2   │
        │      endpoint: unix://│
        └──────────┬───────────┘
                   │  /var/run/kmsplugin/kms.sock
                   ▼
        ┌──────────────────────┐
        │  KMS Plugin Pod       │     ← vault-kube-kms / aws-kms / azure-kms / mock
        │  (Static Pod on CP)   │
        │  KMS v2 gRPC server   │
        └──────────────────────┘
```

**Key constraint**: The real `vault-kube-kms` binary requires **Vault Enterprise** (validates
server license at startup). For CI/testing we use a **mock plugin** that accepts all
vault-kube-kms flags but performs local AES-256-GCM encryption.

---

## 2. Current State

### 2.1 Existing E2E Tests

Location: `cluster-kube-apiserver-operator/test/e2e-encryption-kms/`

| Test | What it covers |
|------|---------------|
| `TestKMSEncryptionOnOff` | KMS on → encrypted → Identity → plaintext → KMS on → encrypted → Identity → plaintext |
| `TestKMSEncryptionProvidersMigration` | Migration between KMS and one random static provider (AESGCM or AESCBC), shuffled order |

**Not covered**: Key rotation with KMS, Vault-specific provider testing, multi-provider migration,
conformance scenarios, blocking CI jobs.

### 2.2 Existing Mock Plugin

Location: `library-go/test/library/encryption/kms/`

- **Image**: `quay.io/openshifttest/mock-kms-plugin` (SoftHSM/PKCS#11 based)
- **Deployment**: DaemonSet on control-plane nodes (E2E test-only approach)
- **Socket**: `/var/run/kmsplugin/kms.sock`
- **Namespace**: `k8s-mock-plugin`
- **Reference**: Kubernetes `k8s.io/kms/internal/plugins/_mock`

This is the **upstream reference mock** — it does not accept any Vault-specific flags.

> **Note**: The upstream mock uses a DaemonSet for convenience in E2E tests. The actual
> Vault plugin in production is deployed as a **static pod** — the manifest is written
> directly to `/etc/kubernetes/manifests/` on each control-plane node. The new Vault mock
> deployer must follow the static pod model to match the production deployment path.

### 2.3 Mock Vault KMS Plugin (New)

Location: `kms-setup/mock-vault-kms/`

- **Image**: `quay.io/rhn_support_rgangwar/mock-kms-plugin-vault:latest`
- **Based on**: `k8s.io/kms/pkg/service` framework (same as upstream mock)
- **Deployment**: **Static pod** on each control-plane node (manifest at `/etc/kubernetes/manifests/mock-vault-kms.yaml`)
- **Encryption**: AES-256-GCM with static key (no external dependencies)
- **Base image**: `scratch` (statically compiled Go binary, minimal footprint)
- **Flags**: Accepts all 16 `vault-kube-kms` flags exactly (verified against real binary):

| Flag | Env Var | Default |
|------|---------|---------|
| `--listen-address` | `VAULT_KUBE_KMS_LISTEN_ADDRESS` | `unix:///var/run/kmsplugin/kms.sock` |
| `--vault-address` | `VAULT_KUBE_KMS_VAULT_ADDRESS` | |
| `--vault-namespace` | `VAULT_KUBE_KMS_VAULT_NAMESPACE` | |
| `--vault-connection-timeout` | `VAULT_KUBE_KMS_VAULT_CONNECTION_TIMEOUT` | `10s` |
| `--transit-mount` | `VAULT_KUBE_KMS_TRANSIT_MOUNT` | `transit` |
| `--transit-key` | `VAULT_KUBE_KMS_TRANSIT_KEY` | `kms-key` |
| `--auth-method` | `VAULT_KUBE_KMS_AUTH_METHOD` | `approle` |
| `--auth-mount` | `VAULT_KUBE_KMS_AUTH_MOUNT` | `approle` |
| `--approle-role-id` | `VAULT_KUBE_KMS_APPROLE_ROLE_ID` | |
| `--approle-secret-id-path` | `VAULT_KUBE_KMS_APPROLE_SECRET_ID_PATH` | |
| `--tls-ca-file` | `VAULT_KUBE_KMS_TLS_CA_FILE` | |
| `--tls-sni` | `VAULT_KUBE_KMS_TLS_SNI` | |
| `--tls-skip-verify` | `VAULT_KUBE_KMS_TLS_SKIP_VERIFY` | `false` |
| `--log-level` | `VAULT_KUBE_KMS_LOG_LEVEL` | `info` |
| `--metrics-port` | `VAULT_KUBE_KMS_METRICS_PORT` | `8080` |
| `--disable-runtime-metrics` | `VAULT_KUBE_KMS_DISABLE_RUNTIME_METRICS` | `false` |

**Validated on OCP 4.22**: TechPreviewNoUpgrade FeatureGate + KMS encryption enabled,
all secrets and configmaps encrypted successfully.

---

## 3. Test Framework Architecture

### 3.1 Provider-Agnostic Design

Since all KMS providers use the same `EncryptionType = "KMS"` API, tests are
**provider-agnostic** — only the plugin deployer changes:

```go
// KMSPluginDeployer abstracts deployment of different KMS provider mocks
type KMSPluginDeployer interface {
    Deploy(ctx context.Context, t testing.TB, kubeClient kubernetes.Interface)
    Cleanup(ctx context.Context, t testing.TB, kubeClient kubernetes.Interface)
    Name() string  // e.g. "vault", "upstream", "aws"
}
```

### 3.2 Deployer Implementations

```
library-go/test/library/encryption/kms/
├── deployer.go                  ← KMSPluginDeployer interface
├── upstream_deployer.go         ← existing: SoftHSM/PKCS#11 mock (DaemonSet)
├── vault_deployer.go            ← new: mock-vault-kms (Static Pod with Vault flags)
├── aws_deployer.go              ← future: mock-aws-kms
├── azure_deployer.go            ← future: mock-azure-kms
└── assets/
    ├── upstream_*.yaml          ← existing upstream mock manifests (DaemonSet)
    └── vault_static_pod.yaml   ← new vault mock manifest (Static Pod)
```

### 3.3 Static Pod vs DaemonSet Deployment

| Aspect | Upstream Mock (DaemonSet) | Vault Mock (Static Pod) |
|--------|--------------------------|------------------------|
| Manifest location | API server (DaemonSet object) | `/etc/kubernetes/manifests/` on each node |
| Deploy method | `kubectl apply` | `oc debug node/... chroot /host` to write manifest |
| Scheduling | kube-scheduler via DaemonSet controller | kubelet watches manifests directory |
| Teardown | `kubectl delete daemonset` | Remove manifest file from each node |
| Mirrors production | No | **Yes** — matches how vault-kube-kms runs |
| Plugin lifecycle (v2) | N/A | Controller writes manifest automatically |

The Vault deployer writes the static pod manifest to each control-plane node:

```bash
# Per node (via oc debug):
mkdir -p /etc/kubernetes/manifests /var/run/kmsplugin
cat > /etc/kubernetes/manifests/mock-vault-kms.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mock-vault-kms
  namespace: openshift-kms-plugin
spec:
  hostNetwork: false
  priorityClassName: system-node-critical
  containers:
  - name: mock-vault-kms
    image: quay.io/openshifttest/mock-vault-kms-plugin:latest
    args:
    - "--listen-address=unix:///var/run/kmsplugin/kms.sock"
    - "--vault-address=https://mock.vault.local:8200"
    - "--transit-mount=transit"
    - "--transit-key=kms-key"
    volumeMounts:
    - name: kmsplugin
      mountPath: /var/run/kmsplugin
  volumes:
  - name: kmsplugin
    hostPath:
      path: /var/run/kmsplugin
      type: DirectoryOrCreate
EOF
```

### 3.4 Test Selection

The KMS provider is selected via environment variable, defaulting to upstream:

```go
func getKMSDeployer(kubeClient kubernetes.Interface) KMSPluginDeployer {
    switch os.Getenv("KMS_PROVIDER") {
    case "vault":
        return NewVaultMockDeployer(kubeClient, VaultMockImage, VaultMockNamespace)
    case "aws":
        return NewAWSMockDeployer(kubeClient, AWSMockImage, AWSMockNamespace)
    default:
        return NewUpstreamMockDeployer(kubeClient, UpstreamMockImage, UpstreamMockNamespace)
    }
}
```

---

## 4. Test Scenarios

### 4.1 Vault KMS Provider — Basic (P0)

Reuse existing `library-go` test scenarios with the Vault mock deployer.

| Test | Library Function | Description |
|------|-----------------|-------------|
| `TestVaultKMSEncryptionOnOff` | `TestEncryptionTurnOnAndOff` | Enable/disable KMS encryption round-trip |
| `TestVaultKMSEncryptionTypeSecrets` | `TestEncryptionType` | Verify secrets encrypted with Vault KMS |
| `TestVaultKMSEncryptionTypeConfigMaps` | `TestEncryptionType` | Verify configmaps encrypted with Vault KMS |

### 4.2 Migration To/From Vault KMS Provider (P1)

| Test | Providers | Description |
|------|-----------|-------------|
| `TestMigrationVaultKMSAndAESGCM` | [KMS, AESGCM] shuffled | Migrate between Vault KMS and AESGCM |
| `TestMigrationVaultKMSAndAESCBC` | [KMS, AESCBC] shuffled | Migrate between Vault KMS and AESCBC |
| `TestMigrationAllProviders` | [KMS, AESGCM, AESCBC] shuffled | Full provider migration matrix |

All tests end with `Identity` to verify data is re-written unencrypted.

### 4.3 Key Rotation with Vault KMS (P2)

| Test | Library Function | Description |
|------|-----------------|-------------|
| `TestVaultKMSKeyRotation` | `TestEncryptionRotation` | Force key rotation → verify new key ID in etcd → verify old data decryptable |

**Prerequisite**: The mock plugin may need enhancement to support key rotation
(changing `mockKeyID` via signal/config reload). Alternatively, rely on the operator's
`unsupportedConfigOverrides` mechanism to force rotation at the encryption config level.

### 4.4 Lifecycle Controller Integration (P1, TechPreview v2)

When the plugin lifecycle controller lands, it **automatically writes the static pod manifest**
to `/etc/kubernetes/manifests/` on each control-plane node based on the `VaultImage` and
Vault configuration in the `APIServer` CRD. The mock-vault-kms plugin is used as the
`VaultImage` so the controller can be tested end-to-end without Vault Enterprise.

| Test | Description |
|------|-------------|
| `TestLifecycleControllerDeploysPlugin` | Set `VaultImage` in APIServer CRD → verify controller writes static pod manifest → pod runs |
| `TestLifecycleControllerPassesFlags` | Verify controller passes Vault config flags from CRD to static pod container args |
| `TestLifecycleControllerHandlesImageUpdate` | Update `VaultImage` → verify controller updates static pod manifest → pod restarts |
| `TestLifecycleControllerHealthCheck` | Verify `/readyz/kms-providers` returns `ok` after controller deploys static pod |

### 4.5 Conformance Scenarios via OTE (P2)

Lightweight checks suitable for the OpenShift Test Extension conformance suite:

| Scenario | Assertion |
|----------|-----------|
| KMS encryption enabled | `apiserver.spec.encryption.type=KMS` → secrets encrypted in etcd |
| KMS health check passes | `GET /readyz/kms-providers` returns `ok` |
| KMS round-trip | Create secret → read back → values match |
| KMS to Identity migration | KMS → Identity → secrets readable in plaintext |

---

## 5. CI Job Configuration

### 5.1 New Makefile Targets

Add to `cluster-kube-apiserver-operator/Makefile`:

```makefile
test-e2e-encryption-kms-vault:
	KMS_PROVIDER=vault go test ./test/e2e-encryption-kms/... -v -timeout 4h -p 1

test-e2e-encryption-kms-vault-migration:
	KMS_PROVIDER=vault go test ./test/e2e-encryption-kms-migration/... -v -timeout 4h -p 1

test-e2e-encryption-kms-rotation:
	KMS_PROVIDER=vault go test ./test/e2e-encryption-kms-rotation/... -v -timeout 4h -p 1
```

### 5.2 Prow Jobs (openshift/release)

| Job Name | Type | Trigger | Cluster Profile | Timeout |
|----------|------|---------|----------------|---------|
| `e2e-aws-ovn-encryption-kms-vault` | Presubmit | `cluster-kube-apiserver-operator` changes | aws | 4h |
| `periodic-e2e-aws-encryption-kms-vault` | Periodic (nightly) | Cron 0 4 * * * | aws | 4h |
| `e2e-aws-encryption-kms-vault-migration` | Presubmit | encryption-related changes | aws | 4h |
| `periodic-e2e-aws-encryption-kms-vault-migration` | Periodic (weekly) | Cron 0 6 * * 0 | aws | 4h |
| `periodic-e2e-aws-encryption-kms-rotation` | Periodic (weekly) | Cron 0 8 * * 0 | aws | 4h |

### 5.3 Blocking vs Informing

| Phase | Blocking | Informing |
|-------|----------|-----------|
| Initial (TechPreview v1) | None | All Vault KMS jobs |
| Stable (after 2 weeks green) | `e2e-aws-ovn-encryption-kms-vault` | Migration + Rotation jobs |
| GA readiness | All Vault KMS jobs | None |

---

## 6. Multi-Provider Strategy

### 6.1 How Multiple KMS Providers Work

OpenShift uses a **single** `EncryptionType = "KMS"` for all KMS providers. Only **one** KMS
plugin runs at a time per cluster. The provider is selected by which plugin image is deployed:

| Provider | Plugin Binary | Image |
|----------|--------------|-------|
| Vault (HashiCorp) | `vault-kube-kms` | `quay.io/redhat-isv-containers/...` |
| AWS | `aws-encryption-provider` | `quay.io/openshift/...` |
| Azure | `azure-kubernetes-kms` | `quay.io/openshift/...` |
| Mock (upstream) | `mock-kms-plugin` | `quay.io/openshifttest/mock-kms-plugin` |
| Mock (Vault-shaped) | `mock-vault-kms` | `quay.io/openshifttest/mock-vault-kms-plugin` |

### 6.2 Cross-Provider Migration

Switching between KMS providers (e.g., Vault → AWS) requires:

```
KMS (Vault plugin running) → Identity → swap plugin binary → KMS (AWS plugin running)
```

This is not a direct migration — it's two separate encryption type changes with a plugin
swap in between. Tests should cover this sequence.

### 6.3 Adding a New Provider

To add E2E tests for a new KMS provider (e.g., AWS):

1. Create a mock plugin that accepts the provider's flags but performs local encryption
2. Add a deployer in `library-go` (`aws_deployer.go` + YAML assets)
3. Add `KMS_PROVIDER=aws` to CI job configuration
4. All existing test scenarios automatically work — no test logic changes needed

---

## 7. Implementation Roadmap

### Phase 1: Foundation (Week 1-2)

- [ ] Publish `mock-vault-kms` image to `quay.io/openshifttest/` with pinned digest
- [ ] Add `VaultMockDeployer` to `library-go/test/library/encryption/kms/`
- [ ] Create static pod manifest for Vault mock (written to `/etc/kubernetes/manifests/` per CP node)
- [ ] Implement `oc debug node/` based deploy/cleanup in `VaultMockDeployer`
- [ ] Add `KMS_PROVIDER` env var selection to test setup

### Phase 2: Core Tests (Week 2-3)

- [ ] `TestVaultKMSEncryptionOnOff` — basic on/off with Vault mock
- [ ] `TestVaultKMSEncryptionProvidersMigration` — KMS ↔ AES migration
- [ ] Add Makefile targets for Vault KMS tests
- [ ] Create informing Prow jobs

### Phase 3: Extended Coverage (Week 3-4)

- [ ] `TestVaultKMSKeyRotation` — key rotation with Vault mock
- [ ] Cross-provider migration test (if applicable)
- [ ] Performance/load tests during encryption migration
- [ ] Promote informing jobs to blocking (after 2 weeks green)

### Phase 4: Conformance & Lifecycle (Week 4-6)

- [ ] Add OTE conformance scenarios for KMS encryption
- [ ] Lifecycle controller integration tests (when TechPreview v2 lands)
- [ ] Add wide-coverage periodic jobs (full matrix)
- [ ] Document test procedures for QA

---

## 8. Dependencies

| Dependency | Owner | Status |
|------------|-------|--------|
| `mock-vault-kms` image published to openshifttest | Rahul | Done (private repo), needs move to public |
| `KMSEncryption` FeatureGate in `openshift/api` | API team | Merged |
| KMS plugin socket volume mount in CKAO | CKAO team | Merged (PR #2015) |
| Plugin lifecycle controller (TechPreview v2) | Flavian/Arda | In progress |
| Vault-kube-kms certified image | HashiCorp | In progress |
| `openshift/release` job configurations | Rahul/Lukasz | Not started |

---

## 9. Open Questions

1. **Key rotation in mock**: Should the mock plugin support dynamic key ID changes
   (e.g., via SIGHUP or config file watch), or is operator-level rotation sufficient?

2. **Real Vault in CI**: Is there value in running a real Vault Community instance in CI
   for integration testing the setup flow (separate from KMS encryption tests)?

3. **Cross-provider migration**: Do we need to test Vault KMS → AWS KMS migration in CI,
   or is the Identity intermediary step sufficient coverage?

4. **Conformance scope**: Which KMS scenarios should be in the conformance suite vs.
   extended testing only?

5. **Multi-arch**: Does the mock plugin need arm64 images for multi-arch CI testing?
