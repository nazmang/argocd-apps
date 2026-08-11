# anamnestic-claw — deploy & operate

This chart is deployed **manually** with `helm upgrade --install`, not via
ArgoCD. There is no ArgoCD `Application` manifest for it anywhere in this
repo, and it should stay that way until `helm-anamnestic-claw/secret.yaml`
can be reconciled by whatever secret-management approach the rest of the
ArgoCD-managed apps use (e.g. sealed-secrets/external-secrets operator).
Until then, deploying this chart means running the commands below by hand.

## Why the secret lives outside `templates/`

`helm-anamnestic-claw/secret.yaml` sits at the chart root, not under
`templates/`. This is deliberate, same reasoning as `helm-openclaw`:

- Helm only renders files under `templates/`. Keeping the secret at chart
  root makes it invisible to `helm template`/`install`/`lint`
  unconditionally — no flag, no `.Values.manageSecrets` conditional needed.
- It also keeps the file as plain, valid Kubernetes YAML with zero Go
  templating, which SOPS's decrypt → edit → re-encrypt round-trip needs.

Practical consequence: `helm upgrade`/`helm template`/`helm lint` never
touch this file. It must be applied to the cluster separately, **before**
running `helm upgrade`, since the Deployment references
`anamnestic-claw-secrets` via `secretKeyRef` for both `SQLCIPHER_KEY` and
`API_BEARER_TOKEN` — if the Secret is missing, the pod won't start.

## The `bootstrap` image tag

`values.yaml`'s `image.tag` is `"bootstrap"`, not a CI-built tag. There is
no GitHub remote for `anamnestic-claw` yet (`.github/workflows/ci.yml`
exists in the app repo but has never run), so the image currently deployed
was hand-built and pushed once during initial bring-up:

```bash
cd /path/to/anamnestic-claw
docker build -t nazman/anamnestic-claw:bootstrap .
docker push nazman/anamnestic-claw:bootstrap
```

Once `anamnestic-claw` has a GitHub remote and Docker Hub CI secrets
configured, replace `image.tag` in `values.yaml` with a real CI-built tag
(e.g. a commit SHA or semver) and retire `bootstrap`. Until then, every
`helm upgrade --install` without an explicit `--set image.tag=...` will
correctly pick up `bootstrap` — do not point it back at `main`, no such tag
was ever built and pulling it is an `ImagePullBackOff` (and, because of
`strategy: Recreate` below, an outage — the old pod is torn down first).

## Prerequisites

```bash
export KUBECONFIG=~/.kube/hetzner
export SOPS_AGE_KEY_FILE=/home/nazman/Документы/argocd-apps/.age/age.key
cd /path/to/argocd-apps   # repo root, so relative paths below resolve
```

## Full deploy sequence

```bash
# 1. Decrypt + apply the secret directly (it is not Helm-managed)
sops -d helm-anamnestic-claw/secret.yaml | kubectl apply -n anamnestic-claw -f -

# 2. Install/upgrade the chart (renders everything under templates/ only)
helm upgrade --install anamnestic-claw ./helm-anamnestic-claw -n anamnestic-claw --create-namespace

# 3. Sanity check
kubectl get pods -n anamnestic-claw -o wide
kubectl -n anamnestic-claw port-forward svc/anamnestic-claw 18000:8000 &
curl -s localhost:18000/healthz; curl -s localhost:18000/readyz
```

Note: the Deployment uses `strategy: type: Recreate` (not the Helm/K8s
default `RollingUpdate`). This is intentional — `replicaCount` is 1, the
PVC is `ReadWriteOnce` on NFS-backed storage, and the app keeps
SQLCipher-encrypted SQLite state on that volume. `RollingUpdate`'s default
math brings the new pod up *before* tearing down the old one, which would
briefly put two writers on the same SQLite file over NFS. Expect a short
downtime window on every `helm upgrade` — that's the trade-off for not
corrupting state.

## Rotating `SQLCIPHER_KEY` is NOT a normal secret rotation

This is the one thing to get right before ever touching this key in
production. `app/db.py` uses SQLCipher's **raw-key** form
(`PRAGMA key = "x'<64-hex-chars>'"`), not the passphrase form — that's
deliberate (see the app repo's fix history: the passphrase form runs a
256,000-round PBKDF2 derivation on every new connection, and this app uses
`NullPool`, so that was 143ms of CPU on every single request). The
consequence is that the on-disk database is encrypted with the *exact*
32-byte key bytes stored in the Secret, with no passphrase-derivation step
in between.

That means you cannot rotate `SQLCIPHER_KEY` the way you'd rotate
`API_BEARER_TOKEN` — swap the Secret, restart the pod, done. Swapping the
key out from under an existing encrypted database and restarting leaves the
new process trying to open a file encrypted under a key it no longer has:
SQLCipher will fail to read the database header and the pod will crash-loop.

Pick one of two paths before rotating:

**(a) Re-key the live database in place (preserves data).** Before
swapping the deployed Secret, connect to the running pod and re-key the
existing SQLite file to the new key:

```bash
kubectl -n anamnestic-claw exec -it deploy/anamnestic-claw -- python -c "
import sqlcipher3
conn = sqlcipher3.connect('/data/health.db')
cur = conn.cursor()
cur.execute(\"PRAGMA key = \\\"x'<OLD-64-HEX-KEY>'\\\"\")
cur.execute(\"PRAGMA rekey = \\\"x'<NEW-64-HEX-KEY>'\\\"\")
conn.commit()
"
```

Only after that succeeds, update and re-apply the Secret (see below) and
restart the pod so it connects with the new key.

**(b) Accept data loss and start fresh.** If the data in `/data/health.db`
is disposable (as it is today — the only row in it is throwaway test data
from initial bring-up), it's simpler to delete the PVC, update the Secret,
and let `helm upgrade --install` provision a fresh empty database under the
new key (Alembic re-runs migrations against the empty file on pod start):

```bash
kubectl delete pvc anamnestic-claw -n anamnestic-claw
sops -d -i helm-anamnestic-claw/secret.yaml
# edit SQLCIPHER_KEY to a new `openssl rand -hex 32` value ...
sops -e -i helm-anamnestic-claw/secret.yaml
sops -d helm-anamnestic-claw/secret.yaml | kubectl apply -n anamnestic-claw -f -
helm upgrade --install anamnestic-claw ./helm-anamnestic-claw -n anamnestic-claw
```

Whichever path you pick, generate the new key the same way the existing
one was generated (`openssl rand -hex 32` — 64 hex characters, no more, no
less; `app/db.py` validates this format and raises before ever touching
SQLCipher if it doesn't match).

## Rotating `API_BEARER_TOKEN`

This one *is* a normal rotation — no derivation, no on-disk state tied to
it, just an `Authorization: Bearer <token>` string the app compares on each
request:

```bash
export SOPS_AGE_KEY_FILE=/home/nazman/Документы/argocd-apps/.age/age.key

# decrypt in place
sops -d -i helm-anamnestic-claw/secret.yaml

# edit the API_BEARER_TOKEN value by hand ...

# re-encrypt (uses the scoped rule in .sops.yaml: helm-anamnestic-claw/secret.yaml)
sops -e -i helm-anamnestic-claw/secret.yaml

# apply straight to the cluster, then restart so the pod picks up the new env var
sops -d helm-anamnestic-claw/secret.yaml | kubectl apply -n anamnestic-claw -f -
kubectl -n anamnestic-claw rollout restart deployment/anamnestic-claw
```

Both `SQLCIPHER_KEY` and `API_BEARER_TOKEN` are consumed via
`env.valueFrom.secretKeyRef` at container start (see
`templates/deployment.yaml`), so either rotation needs a pod restart to
take effect — the running process only reads the env var once, at startup.

## Verifying end-to-end

```bash
kubectl -n anamnestic-claw port-forward svc/anamnestic-claw 18000:8000 &
curl -s localhost:18000/healthz
curl -s localhost:18000/readyz

TOKEN=$(sops -d --extract '["stringData"]["API_BEARER_TOKEN"]' helm-anamnestic-claw/secret.yaml)

curl -s -X POST localhost:18000/weight-logs \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"weight_kg": 72.5, "recorded_at": "2026-08-10T08:00:00Z"}'
# expect: 201, recorded_at echoed back exactly as "2026-08-10T08:00:00Z"

curl -s localhost:18000/weight-logs -H "Authorization: Bearer $TOKEN"
# expect: 200, the entry above

curl -s -o /dev/null -w "%{http_code}\n" localhost:18000/weight-logs -H 'Authorization: Bearer wrong-token'
# expect: 401
```
