# OpenShift KMS Encryption Setup

This repository contains setup scripts and configurations for enabling KMS encryption in OpenShift.

## Available KMS Providers

Choose the appropriate guide based on your KMS provider:

### 1. HashiCorp Vault Transit Engine (Recommended)
See **[VAULT-KMS-SETUP.md](VAULT-KMS-SETUP.md)** for complete setup instructions.

**Use Case:**
- On-premises or self-hosted KMS solution
- Multi-cloud environments
- Advanced secret management requirements
- Full control over encryption keys

**Features:**
- Transit engine for encryption as a service
- AppRole authentication
- Key versioning and rotation
- Audit logging

### 2. AWS KMS (Legacy)
**Files:** `kms-demonset.yaml`, `aws-key-setup*.sh`, `hashcode.go`

**Steps:**
1. Get IAM role of control plane nodes using console or CLI
2. Put IAM role value in script and run `aws-key-setup.sh`
3. Get ARN KMS values
4. Get hashcode using `hashcode.go`
5. Add hashcode value and KMS key ARN in plugin YAML, then apply:
   ```bash
   oc apply -f kms-demonset.yaml
   ```
6. Check AWS KMS pods are running:
   ```bash
   oc get pods -n openshift-kube-apiserver -l name=aws-kms-plugin -o wide
   ```

**Note:** KMS featuregate must be enabled first:
```bash
oc patch featuregate/cluster --type=merge -p '{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["KMSEncryptionProvider"]}}}'
```

## Quick Start

For Vault Transit KMS setup (recommended):
```bash
cd vault-kms-setup
bash setup-vault-transit-kms.sh
```

Then follow the complete guide in [VAULT-KMS-SETUP.md](VAULT-KMS-SETUP.md)

## Repository Structure

```
kms-setup/
├── README.md                          # This file
├── VAULT-KMS-SETUP.md                 # Complete Vault KMS setup guide
├── vault-kms-setup/                   # Vault KMS configuration
│   ├── setup-vault-transit-kms.sh     # Automated Vault setup script
│   └── kms-plugin-config.yaml         # KMS plugin configuration template
├── kms-demonset.yaml                  # AWS KMS plugin DaemonSet
├── aws-key-setup*.sh                  # AWS KMS setup scripts
├── hashcode.go                        # AWS hashcode generator
└── go.mod                             # Go dependencies
```

## Support

For issues or questions:
- Vault KMS: See troubleshooting section in [VAULT-KMS-SETUP.md](VAULT-KMS-SETUP.md)
- AWS KMS: Check AWS CloudWatch logs and KMS key permissions
