# argocd-apps

GitOps source of truth for a single-cluster Hetzner homelab. ArgoCD watches
`main`.

## Layout

| | |
|---|---|
| `<app>.yaml` | ArgoCD `Application`, namespace `argocd`. One per app. |
| `helm-<app>/` | A chart authored here, or values layered onto an upstream chart. |
| `docs/` | Runbooks and implementation plans. |
| `.sops.yaml` | SOPS creation rules — explicit paths, no catch-all. |
| `.age/` | age private key. Gitignored. Never commit. |

## Apps

Application manifest name, then its `metadata.name`, chart source, and the
`spec.destination.namespace` it deploys into.

| Application manifest | Chart source | Namespace |
|---|---|---|
| `ansible-semaphore.yaml` | upstream (`cloudhippie/ansible-semaphore`) + `helm-ansible-semaphore/semaphore` | `semaphore` |
| `apprise.yaml` | `helm-apprise/` | `apprise` |
| `gateway-api.yaml` (name: `gateway-api-app`) | upstream (`appscode/gateway-api`) | `kube-system` |
| `kyverno.yaml` | upstream (`kyverno/kyverno`) | `kyverno` |
| `mailhog.yaml` | upstream (`codecentric/mailhog`) + `helm-mailhog/` values | `mailhog` |
| `minio.yaml` (name: `minio-operator`) | upstream (`minio/operator`, both the operator and tenant paths) + `helm-minio/` values | `minio-operator` |
| `n8n.yaml` | `helm-n8n/` | `n8n` |
| `ntfy.yaml` | `helm-ntfy/` | `ntfy` |
| `openclaw.yaml` | `helm-openclaw/` | `openclaw` |
| `anamnestic-claw.yaml` | `helm-anamnestic-claw/` | `anamnestic-claw` |
| `reloader.yaml` | upstream (`stakater/reloader`) + `helm-reloader/` values | `reloader` |
| `trivy-operator.yaml` | upstream (`aquasecurity/trivy-operator`) | `trivy-system` |
| `trivy-operator-dashboard.yaml` | external repo (`raoulx24/trivy-operator-dashboard`), not `helm-*/` | `trivy-dashboard` |
| `tutor-dev.yaml` (name: `tutor-dev`) | `helm-tutor/` | `dev` |
| `vault.yaml` | upstream (`hashicorp/vault`) + `helm-vault/` values, plus local `helm-vault/vault-config` and `helm-vault/auto-unseal` (ksops) | `vault` |
| `vpa.yaml` (name: `vertical-pod-autoscaler`) | upstream (`cowboysysop/vertical-pod-autoscaler`) | `kube-system` |

All charts are ArgoCD-managed. `helm-openclaw/` and `helm-anamnestic-claw/`
were the last two deployed by hand and moved to ArgoCD on 2026-09-08.

**Unresolved**: `helm-trustmanager/` has no Application manifest anywhere in
the repo and nothing references it. See `CLAUDE.md`'s Known gaps before
assuming it is either live or dead.

## Secrets

SOPS + age, one recipient. Two delivery mechanisms: helm-secrets — an encrypted
values file per chart — for `helm-n8n`, `helm-openclaw` and
`helm-anamnestic-claw`, and ksops via kustomize for `helm-vault/auto-unseal` and
`helm-ansible-semaphore/semaphore`. Nothing is applied by hand any more; the
last two manual charts moved on 2026-09-08. helm-secrets is verified end to end
in both Application shapes — `secrets://` for single-source, and a plain
`$values/...` path for multi-source. Note that n8n's encryption key
also lives on its PVC and cannot be rotated by changing the Secret alone — see
`docs/n8n-encryption-key-rotation.md`.

`CLAUDE.md` has the rules, the reasoning, and the traps. Read it before
touching anything encrypted.

## Working here

```bash
export KUBECONFIG=~/.kube/hetzner
export SOPS_AGE_KEY_FILE="$PWD/.age/age.key"
pre-commit install
```

Before pushing: `pre-commit run --all-files`.
