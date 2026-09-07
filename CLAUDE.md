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

> **STOP — applying the runbook is NOT sufficient, and it is not the first
> step.** Because of the ciphertext-as-secret bug above, the n8n pod is right
> now running with `N8N_ENCRYPTION_KEY` set to the literal `ENC[AES256_GCM,...]`
> string, and every credential n8n has stored is encrypted under it. The
> encryption key will NOT be rotated (user decision, 2026-09-07).
> `helm-n8n/secrets.yaml` must therefore be **pinned to the key n8n is actually
> running** before anything syncs, or the first sync replaces the live key and
> orphans every stored credential — silently, since `n8n.yaml` has
> `syncPolicy.automated` with `prune: true, selfHeal: true` and there is no
> manual gate once this is on `main`.
>
> Correct operator sequence, in this order:
>
> 1. Apply `docs/argocd-repo-server-helm-secrets.md` (plugin + sops + age key +
>    `helm.valuesFileSchemes`).
> 2. Pin the live key into `helm-n8n/secrets.yaml` and commit it —
>    `docs/superpowers/plans/2026-09-07-helm-secrets-argocd.md`, Task 5
>    Steps 1–2 (Option A).
> 3. Only then merge to `main` / let ArgoCD sync, and run Task 5 Steps 3–6 to
>    verify.
>
> Doing 3 before 2 is the one irreversible mistake in this whole migration.

- **helm-secrets decrypts values files only — never templates.** An encrypted
  file under `templates/` is rendered verbatim by Helm, which is exactly the
  bug this repo shipped to production until 2026-09-07: n8n ran with its
  `N8N_ENCRYPTION_KEY` set to the literal `ENC[AES256_GCM,...]` string.
  `helm-n8n/templates/secret.yaml` is now an ordinary template that reads
  `.Values.secrets` and `fail`s loudly, naming the offenders, if any of
  `N8N_ENCRYPTION_KEY` / `N8N_BASIC_AUTH_USER` / `N8N_BASIC_AUTH_PASSWORD` is
  missing or empty — so a plain `helm template ./helm-n8n` (no values file), or
  a values file that drops one key, errors instead of silently shipping an
  empty or partial Secret.
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
- **The `sops-encrypted-only` hook covers the committed subset of
  `.sops.yaml`'s rules, not all of it — and that's deliberate.** `.sops.yaml`
  has six per-path rules. The hook in `.pre-commit-config.yaml` lists five of
  them: `helm-n8n/secrets.yaml`,
  `helm-vault/auto-unseal/vault-init-secret.yaml`,
  `helm-ansible-semaphore/semaphore/secret.yaml`,
  `helm-openclaw/secret-*.yaml`, `helm-anamnestic-claw/secret.yaml`. The
  sixth rule, `helm-vault/auto-unseal/vault-init.(yaml|json)` (raw
  `vault operator init` output, encrypted at rest for safety), is
  gitignored via `helm-vault/auto-unseal/.gitignore` — it is never staged
  and never scanned, so it can never be committed in plaintext regardless of
  what the hook says. Adding it to the hook's `files:` regex would be dead
  config matching nothing pre-commit ever sees. When adding a new `.sops.yaml`
  rule, add it to the hook too only if the file is meant to be committed; leave
  gitignored artifacts out.
- **Know what each gate actually catches — they are not interchangeable.** The
  `sops-encrypted-only` hook only tests that a staged file has a `sops:` block.
  That is true of a *partially* encrypted file too, so the hook cannot see a key
  that sops left in plaintext because it fell outside that file's
  `encrypted_regex`. gitleaks is what catches that, which is why
  `.gitleaks.toml` has **no path-based allowlist**: encrypted files stay in
  gitleaks' scope. Keeping them in scope is free — verified 2026-09-07, gitleaks
  v8.30.1 with `useDefault = true` reports no findings on all seven committed
  encrypted files without any path allowlist. Do not "quiet" gitleaks by
  allowlisting a SOPS path; if something is genuinely noisy, allowlist the
  specific content pattern instead (as the age recipient is).
- **Encrypt by explicit key name, never by prefix.** Every `encrypted_regex` in
  `.sops.yaml` names its keys in full. A prefix like `^(N8N_.*)$` looks tidier
  but silently writes the next key that does not match it
  (`DB_POSTGRESDB_PASSWORD`, `QUEUE_BULL_REDIS_PASSWORD`, `SMTP_PASS`,
  `OPENAI_API_KEY`, …) into a committed file in plaintext. So **adding a key to
  an existing Secret means updating that file's `encrypted_regex` first**, or
  the new key commits as plaintext.
- **Editing an encrypted file:** `sops -d -i <f>`, edit, `sops -e -i <f>`. That
  round-trip is the sanctioned workflow — it does briefly leave plaintext in the
  working tree, and that is expected. What must never happen is *leaving* a
  decrypted secret there: finish with `sops -e -i` in the same sitting, and
  never copy a decrypted value into a second file inside the repo (a scratch
  note, a values override, a test fixture) — use a path outside the working tree
  for that. If you decrypt in place and get interrupted, the
  `sops-encrypted-only` pre-commit hook is the backstop that stops the plaintext
  from being committed. A backstop, not a licence to leave it lying there.
- **`helm-openclaw`'s `BACKEND_TOKEN` must equal `helm-anamnestic-claw`'s
  `API_BEARER_TOKEN`.** Kubernetes Secrets do not cross namespaces, so it is
  duplicated. Rotating one without the other breaks the health plugin.
- Run `pre-commit run --all-files` before pushing.
- Do not commit `.age/` or `.worktrees/`.

## Local tooling

Local `sops` here is 3.7.1 (2021). `docs/argocd-repo-server-helm-secrets.md`
pins sops 3.13.3 as the version to install on `argocd-repo-server` once that
runbook is applied — nothing runs that version yet (see the helm-secrets
status note above). Files encrypted under 3.7.1 decrypt fine under newer
sops, so upgrading the local binary is not urgent, but it's worth doing.

## Known gaps

- **`helm-trustmanager/` is unresolved.** It contains only a bare
  `trustmanager-values.yaml`, added in a single commit (`fc1e91d`, "Added
  necessary folders"), and no root-level `<app>.yaml` or any other file in
  the repo references it.

  *What was since identified:* the values file is for cert-manager's
  **trust-manager** chart. Its keys — `replicaCount`, `serviceAccount.create`,
  `crds.enabled`, `crds.keep`, `resources` — match upstream
  `cert-manager/trust-manager` exactly, and that chart's images come from
  `quay.io/jetstack`. So the *what* is settled; the *whether it is deployed* is
  not.

  Settle it with cluster evidence — do not assume an answer:

      helm list -A | grep -i trust
      kubectl get crd | grep -i bundle    # trust-manager installs bundles.trust.cert-manager.io

  Then either add a `trustmanager.yaml` Application, fold it into an existing
  chart's `commands.md` as a by-hand deploy, or delete the directory.

  Related: cert-manager itself *is* used in this cluster — see
  `helm-vault/vault-config/vault-config.yaml` and
  `helm-minio/minio-tenant.values.yaml` — but has no Application manifest in
  this repo either. Same class of gap.
- **`helm-n8n/renderd-job-template.yaml` sets `RENDERD_S3_VERIFY: "false"` —
  accepted debt, not a setting to copy.** The render Job talks to MinIO over
  TLS with certificate verification disabled, because the MinIO operator's CA
  is not present in the `renderd` image. It is an in-cluster hop, which is why
  it was accepted rather than fixed, but it is still an unverified TLS
  connection carrying MinIO service-account credentials. The proper fix is to
  distribute the operator CA into the image's trust store — which is precisely
  what trust-manager does, so resolving the `helm-trustmanager/` gap above is
  the path to closing this one.
- Several secrets in the `n8n` namespace (`renderd-minio`, `ghcr-renderd`) are
  created by hand and exist nowhere in git, so a cluster rebuild cannot restore
  them. Documented at length in `helm-n8n/values.yaml`. Not solved.
- Vault is deployed but not used as a secret backend. External Secrets +
  Vault is the intended end state; helm-secrets is the current step.
- Kyverno enforces cosign signatures only for
  `ghcr.io/nazmang/ai-language-tutor*`. The `renderd` images are unsigned and
  unverified.
