# CLAUDE.md

GitOps repo for a single-cluster homelab (Hetzner). ArgoCD watches `main` and
reconciles what is here. `export KUBECONFIG=~/.kube/hetzner` before any
`kubectl`/`helm`/`argocd` command.

## Layout

Two kinds of file, and the naming is load-bearing:

- **`<app>.yaml` at the repo root** — an ArgoCD `Application` in namespace
  `argocd`. One per app.
- **`helm-<app>/`** — either a chart authored here (has `Chart.yaml` and
  `templates/`) or just a values file layered onto an upstream chart.

An Application either points `source.path` at a local chart directory, or uses
`sources:` with a `ref: values` entry so `$values/helm-<app>/....yaml` layers
local values onto an upstream chart. `reloader.yaml` and `minio.yaml` are the
reference examples of the second shape.

Root-level app manifests are applied out-of-band (they are how ArgoCD learns
about the app); everything inside `helm-*/` is reconciled by ArgoCD.

## Secrets: three mechanisms, and which is which

All three use SOPS with one age recipient
(`age1wp7n5rlrjdqjx7hpkfv35ejwauuggyncl0cu4zllcq59a696sudqnucqfe`). The private
key is `.age/age.key` — gitignored, mode 600, never commit it. Always:

    export SOPS_AGE_KEY_FILE="$PWD/.age/age.key"

**1. helm-secrets (`helm-n8n` only).** A SOPS-encrypted Helm *values* file,
`helm-n8n/secrets.yaml`, referenced from `n8n.yaml` as
`secrets://secrets.yaml` and decrypted by the helm-secrets downloader plugin on
`argocd-repo-server`. Setup: `docs/argocd-repo-server-helm-secrets.md` — that
runbook has NOT been applied to any cluster yet; the repo-server still lacks
the plugin, so `n8n.yaml`'s sync will fail on `secrets://` until it is.

- **helm-secrets decrypts values files only — never templates.** An encrypted
  file under `templates/` is rendered verbatim by Helm, which is exactly the
  bug this repo shipped to production until 2026-09-07: n8n ran with its
  `N8N_ENCRYPTION_KEY` set to the literal `ENC[AES256_GCM,...]` string.
  `helm-n8n/templates/secret.yaml` is now an ordinary template that reads
  `.Values.secrets` and `fail`s loudly if that map is empty, so a plain
  `helm template ./helm-n8n` (no values file) errors instead of silently
  shipping an empty Secret.
- **`n8n.yaml` must stay single-source** (`spec.source`, not `spec.sources`).
  ArgoCD requires `$ref` at the start of a value-file string, which collides
  with the `secrets://` prefix.
- Render locally with `helm template n8n ./helm-n8n -f <(sops -d helm-n8n/secrets.yaml)`.

**2. ksops via kustomize (`helm-vault/auto-unseal`, `helm-ansible-semaphore/semaphore`).**
A `ksops` generator lists the encrypted file; ArgoCD's kustomize build decrypts
it. Check with
`kustomize build --enable-alpha-plugins --enable-exec <dir>`.

**3. Applied by hand (`helm-openclaw`, `helm-anamnestic-claw`).** Not
ArgoCD-managed at all. Encrypted Secrets sit at *chart root*, deliberately
outside `templates/`, and are applied with
`sops -d <file> | kubectl apply -n <ns> -f -` **before** `helm upgrade`. Full
procedure and rotation caveats: `helm-openclaw/commands.md` and
`helm-anamnestic-claw/commands.md`. Read those before touching either chart —
`SQLCIPHER_KEY` in particular cannot be rotated by swapping the Secret.

## Rules

- **Never put a SOPS-encrypted file under `templates/`.** Helm renders it
  verbatim and ships ciphertext as the secret value. Values file, or chart
  root, or ksops — nothing else.
- **Never wrap an encrypted file in `{{- if }}` to hide it from Helm.** Tried
  and failed: `sops -e -i` appends its metadata block after existing trailing
  content, landing it outside the `{{- end }}`. See commit `69bd828`.
- **`.sops.yaml` has no catch-all rule, on purpose.** `sops -e` on an unlisted
  file errors with "no matching creation rules found". Add an explicit
  `path_regex` + `encrypted_regex` for the new file rather than widening an
  existing rule.
- **The scanning configs cover the committed subset of `.sops.yaml`'s rules,
  not all of it — and that's deliberate.** `.sops.yaml` has six per-path
  rules. `.gitleaks.toml`'s allowlist and the `sops-encrypted-only` hook in
  `.pre-commit-config.yaml` list only five of them:
  `helm-n8n/secrets.yaml`, `helm-vault/auto-unseal/vault-init-secret.yaml`,
  `helm-ansible-semaphore/semaphore/secret.yaml`,
  `helm-openclaw/secret-*.yaml`, `helm-anamnestic-claw/secret.yaml`. The
  sixth rule, `helm-vault/auto-unseal/vault-init.(yaml|json)` (raw
  `vault operator init` output, encrypted at rest for safety), is
  gitignored via `helm-vault/auto-unseal/.gitignore` — it is never staged
  and never scanned, so it can never be committed in plaintext regardless of
  what either scanning config says. Adding it to `.gitleaks.toml` or the
  pre-commit hook's `files:` regex would be dead config matching nothing
  gitleaks or pre-commit ever sees — the exact kind of stale entry this plan
  removed from `.gitleaks.toml` (a dead `helm-cloudflared` allowlist). When
  adding a new `.sops.yaml` rule, add it to the scanning configs too only if
  the file is meant to be committed; leave gitignored artifacts out.
- **Editing an encrypted file:** `sops -d -i <f>`, edit, `sops -e -i <f>`. If
  you decrypt in place and get interrupted, the `sops-encrypted-only`
  pre-commit hook is what stops the plaintext from being committed. Never
  write a decrypted secret to a file inside the working tree.
- **Adding a key to an existing Secret** means updating that file's
  `encrypted_regex` in `.sops.yaml` too, or the new key commits as plaintext.
- **`helm-openclaw`'s `BACKEND_TOKEN` must equal `helm-anamnestic-claw`'s
  `API_BEARER_TOKEN`.** Kubernetes Secrets do not cross namespaces, so it is
  duplicated. Rotating one without the other breaks the health plugin.
- Run `pre-commit run --all-files` before pushing.
- Do not commit `.age/` or `.worktrees/`.

## Local tooling

`sops` here is 3.7.1 (2021); `argocd-repo-server` runs 3.13.3. Old files
decrypt fine under new sops, so this is not urgent, but upgrading the local
binary is worth doing.

## Known gaps

- **`helm-trustmanager/` is unresolved.** It contains only a bare
  `trustmanager-values.yaml`, added in a single commit (`fc1e91d`, "Added
  necessary folders"), and no root-level `<app>.yaml` or any other file in
  the repo references it. Whether it was deployed by hand, is orphaned, or
  should become an ArgoCD-managed app was not determined — settling it needs
  cluster evidence this session did not have. Run `helm list -A | grep -i
  trust` against the live cluster to find out what (if anything) is actually
  running, then either add a `trustmanager.yaml` Application, fold it into
  an existing chart's `commands.md` as a by-hand deploy, or delete the
  directory. Do not assume an answer without checking the cluster.
- Several secrets in the `n8n` namespace (`renderd-minio`, `ghcr-renderd`) are
  created by hand and exist nowhere in git, so a cluster rebuild cannot restore
  them. Documented at length in `helm-n8n/values.yaml`. Not solved.
- Vault is deployed but not used as a secret backend. External Secrets +
  Vault is the intended end state; helm-secrets is the current step.
- Kyverno enforces cosign signatures only for
  `ghcr.io/nazmang/ai-language-tutor*`. The `renderd` images are unsigned and
  unverified.
