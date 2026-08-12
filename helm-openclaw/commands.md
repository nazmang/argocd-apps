# OpenClaw — deploy & operate

This chart is deployed **manually** with `helm upgrade --install`, not via
ArgoCD. There is no ArgoCD `Application` manifest for it anywhere in this
repo, and it should stay that way until the two SOPS-encrypted secret files
below can be reconciled by whatever secret-management approach the rest of
the ArgoCD-managed apps use (e.g. sealed-secrets/external-secrets operator).
Until then, deploying this chart means running the commands below by hand.

## Why the secrets live outside `templates/`

`helm-openclaw/secret-basic-auth.yaml` and `helm-openclaw/secret-gateway-token.yaml`
sit at the chart root, not under `templates/`. This is deliberate:

- Helm only renders files under `templates/`. Keeping the secrets at chart
  root makes them invisible to `helm template`/`install`/`lint`
  unconditionally — no flag, no `.Values.manageSecrets` conditional needed.
- It also keeps the files as plain, valid Kubernetes YAML with zero Go
  templating, which SOPS's decrypt → edit → re-encrypt round-trip needs.
  An earlier version of the gateway-token secret lived under `templates/`
  wrapped in a commented-out `{{- if }}` / `{{- end }}` pair so Helm would
  ignore it. That broke on the first rotation: SOPS re-appends its `sops:`
  metadata block after existing trailing content, which landed the
  metadata block *outside* the `{{- end }}` comment and produced an invalid
  manifest fragment. See `git log --oneline -- helm-openclaw/` (commit
  `69bd828`, "Move gateway token secret out of templates/ to avoid Helm
  entirely") for the full story.

Practical consequence: `helm upgrade`/`helm template`/`helm lint` never
touch these two files. They must be applied to the cluster separately,
**before** running `helm upgrade`, since the Deployment references
`openclaw-gateway-token` via `secretKeyRef` and the Ingress references
`openclaw-basic-auth` via the `auth-secret` annotation — if either Secret
is missing, the pod won't start / the Ingress auth will fail closed.

## Prerequisites

```bash
export KUBECONFIG=~/.kube/hetzner
export SOPS_AGE_KEY_FILE=/home/nazman/Документы/argocd-apps/.age/age.key
cd /path/to/argocd-apps   # repo root, so relative paths below resolve
```

## Full deploy sequence

```bash
# 1. Decrypt + apply both secrets directly (they are not Helm-managed)
sops -d helm-openclaw/secret-gateway-token.yaml | kubectl apply -n openclaw -f -
sops -d helm-openclaw/secret-basic-auth.yaml    | kubectl apply -n openclaw -f -

# 2. Install/upgrade the chart (renders everything under templates/ only)
helm upgrade --install openclaw ./helm-openclaw -n openclaw --create-namespace

# 3. Sanity check
kubectl get pods -n openclaw -o wide
kubectl -n openclaw port-forward svc/openclaw 18789:18789 &
curl -s localhost:18789/healthz; curl -s localhost:18789/readyz
```

Note: the Deployment uses `strategy: type: Recreate` (not the Helm/K8s
default `RollingUpdate`). This is intentional — `replicaCount` is 1, the
PVC is `ReadWriteOnce` on NFS-backed storage, and the app keeps SQLite-backed
state on that volume. `RollingUpdate`'s default math brings the new pod up
*before* tearing down the old one, which briefly puts two OpenClaw
processes on the same PVC. Expect a short downtime window on every
`helm upgrade` — that's the trade-off for not corrupting state.

## Rotating a secret

Same pattern for either `secret-gateway-token.yaml` or
`secret-basic-auth.yaml`:

```bash
export SOPS_AGE_KEY_FILE=/home/nazman/Документы/argocd-apps/.age/age.key

# decrypt in place
sops -d -i helm-openclaw/secret-<name>.yaml

# edit the plaintext value(s) by hand ...

# re-encrypt (uses the scoped rule in .sops.yaml: helm-openclaw/secret-*.yaml)
sops -e -i helm-openclaw/secret-<name>.yaml

# apply straight to the cluster
sops -d helm-openclaw/secret-<name>.yaml | kubectl apply -n openclaw -f -
```

No pod restart is needed for either secret:

- `openclaw-gateway-token` — actually, this one *is* consumed via
  `env.valueFrom.secretKeyRef` at container start, so a token rotation
  **does** need the pod to pick up the new env var. Restart it with
  `kubectl -n openclaw rollout restart deployment/openclaw` after applying.
- `openclaw-basic-auth` — nginx-ingress reads this Secret live on every
  request (no env var, no volume mount into the app container), so
  rotating the Basic Auth password/hash takes effect immediately with no
  restart of anything.

`secret-basic-auth.yaml` stores two keys: `auth` (the bcrypt htpasswd line
nginx-ingress needs for `auth-type: basic`) and `password` (the plaintext
password itself, so a human can actually log into the Gateway UI). Both are
listed in `.sops.yaml`'s scoped `encrypted_regex` for this chart
(`^(OPENCLAW_GATEWAY_TOKEN|auth|password)$`) so both get encrypted — if you
add a third key to either secret file, remember to extend that regex too,
or the new key will be committed as plaintext.

### `health-plugin-token` is a special case

`health-plugin-token`'s `BACKEND_TOKEN` must always equal
`helm-anamnestic-claw/secret.yaml`'s `API_BEARER_TOKEN` exactly — it's a
duplicate of that value, kept in this namespace because Kubernetes Secrets
don't cross namespaces. Rotating `API_BEARER_TOKEN` (see
`helm-anamnestic-claw/commands.md`) without also updating this file leaves
the plugin unable to authenticate to the backend (401s on every
`log_weight` call) until both are back in sync. After updating either,
restart the `openclaw` deployment so the `health-plugin-bootstrap`
initContainer re-runs with the new value:

```bash
kubectl -n openclaw rollout restart deployment/openclaw
```

## Verifying end-to-end (not just that nginx answers)

A `401` from `https://openclaw.srvx.cc/healthz` only proves nginx-ingress's
own auth phase is working — nginx returns `401` *before* ever proxying to
the backend, so it does **not** prove the Ingress → Service → pod path
works. The real check is a `200` with valid credentials:

```bash
PW=$(sops -d --extract '["stringData"]["password"]' helm-openclaw/secret-basic-auth.yaml)
curl -s -o /dev/null -w "%{http_code}\n" -u "admin:$PW" https://openclaw.srvx.cc/healthz
# expect: 200
```
