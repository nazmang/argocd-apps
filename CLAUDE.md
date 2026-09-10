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

**1. helm-secrets — `helm-n8n`, `helm-openclaw`, `helm-anamnestic-claw`,
`helm-ntfy`.** A SOPS-encrypted Helm *values* file at the chart root,
`helm-<app>/secrets.yaml`, listed in the Application's `valueFiles` and
decrypted by the helm-secrets downloader plugin on `argocd-repo-server`. This is
the default mechanism for new work.

**This is live and proven.** The plugin, `sops`, and the age key were already
present on the repo-server before this migration; `docs/argocd-repo-server-helm-secrets.md`
records what is actually installed and how to verify it. End-to-end verified
2026-09-07: changing `helm-n8n/secrets.yaml`, pushing, and syncing produces a
`n8n-secrets` Secret holding the correct decrypted values.

> **The n8n encryption key lives in TWO places. Never change one alone.**
>
> n8n persists `N8N_ENCRYPTION_KEY` in `/home/node/.n8n/config` on its PVC and
> **refuses to start** if that file and the env var disagree:
> `Mismatching encryption keys ... Please make sure both keys match`. That is a
> good safety property — it makes silent credential orphaning impossible — but
> it means changing `helm-n8n/secrets.yaml` alone puts n8n into
> CrashLoopBackOff. Learned the hard way on 2026-09-07 (~8 minutes of downtime).
>
> To rotate it, follow `docs/n8n-encryption-key-rotation.md`. Do not improvise.
>
**Attaching an encrypted values file depends on the Application's shape.** Both
forms are verified working on this cluster:

| Application | How to list the encrypted values file |
|---|---|
| `spec.source` (single) | `- secrets://secrets.yaml` — path relative to the chart dir |
| `spec.sources` (multi) | `- $values/<chart-dir>/secrets.yaml` — **no** `secrets://` prefix |

Multi-source cannot use the prefix: ArgoCD requires `$ref` at the start of a
value-file string and does not resolve refs inside URLs. It works anyway
because `argocd-repo-server` runs with `HELM_SECRETS_WRAPPER_ENABLED=true`,
which wraps `helm` itself and decrypts value files it is handed. Verified
2026-09-07 on `helm-mailhog` (probe since removed; the result is this table).

Do **not** name the encrypted file `values.yaml`. Helm auto-loads a chart's own
`values.yaml` as defaults, so encrypting it makes ciphertext the default value
set — and the whole thing then rests on the overlay always winning. That is the
same failure shape as the bug above. Keep secrets in a separately-named file.

> Also note: `envFrom` is resolved when the **pod** is created, not when a
> container restarts. A crash-looping pod keeps the env it was created with, so
> `kubectl rollout restart` will not pick up a new Secret — you must delete the
> pod.

- **helm-secrets decrypts values files only — never templates.** An encrypted
  file under `templates/` is rendered verbatim by Helm. This repo shipped that
  bug to production: n8n ran for weeks with its `N8N_ENCRYPTION_KEY` set to the
  literal `ENC[AES256_GCM,...]` envelope. Fixed and the key rotated on
  2026-09-07 — see `docs/n8n-encryption-key-rotation.md` for the post-mortem.
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

**3. Applied by hand — none left.** `helm-openclaw` and `helm-anamnestic-claw`
were the last two and moved to mechanism 1 on 2026-09-08, once helm-secrets
proved out. Their `commands.md` files keep the manual sequence as a break-glass
path and are still worth reading for the hard-won parts: the `Recreate`
strategy reasoning, the `BACKEND_TOKEN` / `API_BEARER_TOKEN` cross-namespace
pairing, and above all `SQLCIPHER_KEY`, which cannot be rotated by swapping the
Secret. **Do not run `helm upgrade` against either chart now** — ArgoCD has
`selfHeal: true` and will revert it.

`helm-openclaw`'s `healthPlugin.enabled` is `false`: its initContainer needs
`nazman/anamnestic-claw-plugin:main`, an image that has never been built. With
`strategy: Recreate`, enabling it before that image exists takes openclaw down
rather than degrading it. See the comment in `helm-openclaw/values.yaml`.

## Rules

- **Never put a SOPS-encrypted file under `templates/`.** Helm renders it
  verbatim and ships ciphertext as the secret value. Values file, or chart
  root, or ksops — nothing else.
- **A rendered config file that carries credentials goes into a Secret, not a
  ConfigMap.** Decrypting a value out of git and then rendering it into a
  ConfigMap moves the exposure rather than removing it: ConfigMap contents are
  readable by anything with `get configmap` in the namespace and are shown
  unmasked in the ArgoCD UI, while Secrets are masked. `helm-ntfy` renders its
  whole `server.yml` as a Secret for exactly this reason — the file holds
  `auth-users`, i.e. bcrypt password hashes. The mount is identical either way,
  so this costs nothing; the `checksum/config` annotation just has to point at
  the right template.
- **A `fail` guard belongs on any chart whose secrets moved out of
  `values.yaml`.** Once the values file no longer carries the key, a plain
  `helm template ./helm-<app>` renders a *valid* manifest with the secret
  missing, and the failure surfaces later as a confusing runtime symptom.
  `helm-n8n` and `helm-ntfy` both `fail` loudly instead, naming the missing key
  and how to render locally. For ntfy the silent version would have been a
  server with `require-login: true`, `auth-default-access: deny-all` and no
  users — one nobody can log into or publish to.
- **ntfy: if `authUsers` is set in config, every access token must be listed in
  `authTokens` too.** ntfy 2.28 provisions users declared in `auth-users` into
  its `auth.db` with `provisioned=1`, and it then refuses tokens carrying
  `provisioned=0` -- which is what `ntfy token add` produces. The symptom is a
  flat `401` on Bearer auth while Basic auth with the password succeeds against
  the same server, and it survives creating a brand-new token. Both are in
  `helm-ntfy/secrets.yaml`; `.sops.yaml` encrypts `^(authUsers|authTokens)$`.
  Found 2026-09-10, when Kuma's notification started failing with
  `unauthorized, error=40101` and the token in the database matched the one in
  the URL byte for byte.
- **Never wrap an encrypted file in `{{- if }}` to hide it from Helm.** Tried
  and failed: `sops -e -i` appends its metadata block after existing trailing
  content, landing it outside the `{{- end }}`. See commit `69bd828`.
- **`.sops.yaml` has no catch-all rule, on purpose.** `sops -e` on an unlisted
  file errors with "no matching creation rules found". Add an explicit
  `path_regex` + `encrypted_regex` for the new file rather than widening an
  existing rule.
- **The `sops-encrypted-only` hook covers the committed subset of
  `.sops.yaml`'s rules, not all of it — and that's deliberate.** `.sops.yaml`
  has seven per-path rules. The hook in `.pre-commit-config.yaml` lists six of
  them: `helm-n8n/secrets.yaml`,
  `helm-vault/auto-unseal/vault-init-secret.yaml`,
  `helm-ansible-semaphore/semaphore/secret.yaml`,
  `helm-openclaw/secrets.yaml`, `helm-anamnestic-claw/secrets.yaml`,
  `helm-ntfy/secrets.yaml`. The
  seventh rule, `helm-vault/auto-unseal/vault-init.(yaml|json)` (raw
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
  `encrypted_regex`. gitleaks is what catches that — a path-based allowlist
  would hide that plaintext key from gitleaks too, so `.gitleaks.toml` has
  **no path-based allowlist**: encrypted files stay in gitleaks' scope.
  Keeping them in scope is free — verified 2026-09-07, gitleaks
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

  *Settled 2026-09-07 against the live cluster:* **it is not deployed.**
  `helm list -A | grep -i trust` returns nothing and there is no
  `bundles.trust.cert-manager.io` CRD. So the directory is an orphaned values
  file for something that was never installed — decide whether to install
  trust-manager properly (add a `trustmanager.yaml` Application) or delete the
  directory. Re-check with those same two commands before acting.

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
- `helm-tutor`'s secrets (`tutor-db`, `tutor-llm-keys`, `tutor-review-audio`,
  `tutor-support-bot`, `ghcr-tutor` — 15 values in namespace `dev`) are created
  by hand and exist nowhere in git, so a cluster rebuild cannot restore them.
  The app IS ArgoCD-managed, which makes this the largest remaining gap.
  Deliberately not migrated into encrypted values yet: it holds the Anthropic,
  OpenAI and DeepSeek API keys plus a Telegram bot token, and this repo is
  public — so those belong behind Vault/External Secrets rather than in git,
  and that decision is pending (2026-09-08).
  The equivalent gap for n8n (`renderd-minio`, `ghcr-renderd`) is closed.
- **Vault is deployed but still not used as a secret backend.** Nothing carries
  the agent-injector annotations and External Secrets Operator is not installed.
  External Secrets + Vault remains the intended end state; helm-secrets is the
  current step.

  Two corrections to what this file used to say. Vault is **not** installed from
  another repository — `vault.yaml` here is a multi-source Application pulling
  the upstream chart plus three paths from this repo. And the auto-unseal
  question is settled: since 2026-09-10 the seal is **transit**, backed by a
  small Vault on dkr01 (docker repo, `docker-vault-transit`), and Vault unseals
  itself on startup. Verified by deleting the pod and watching it come back
  unsealed with zero restarts. The one-shot Job that preceded it ran once at
  install time and never again, so every restart left Vault sealed until a human
  noticed.

  The Shamir keys are now **recovery** keys, not unseal keys. They remain the
  break-glass path if the transit Vault is lost.

  **There is no standing root token, on purpose.** The one that used to sit in
  `vault-init.yaml` was exposed in a session transcript on 2026-09-10 and has
  been revoked — verified, a lookup with it returns 403. A replacement was
  generated from the recovery keys, used to revoke the old one, and then revoked
  itself. Generate one when an admin operation needs it and revoke it after:

      vault operator generate-root -init              # gives nonce + otp
      vault operator generate-root -nonce=... <key>   # three of the five
      vault operator generate-root -decode=... -otp=...
      ... do the work ...
      vault token revoke -self

  That path is not theoretical: it was walked end to end on 2026-09-10 before
  the old token was revoked, precisely so that revoking it could not lock anyone
  out.

  `vault-init.yaml` is **now SOPS-encrypted** (it had been plaintext on disk
  since April despite `.sops.yaml` carrying a rule for it — gitignored, so never
  committed, but plaintext recovery keys on a laptop are the exposure that rule
  exists to prevent). Its duplicate `vault-init.json` held the same five keys in
  the clear and was deleted rather than encrypted: fewer copies of the recovery
  keys is strictly better, and nothing referenced it.

- **`server.config` and `server.tls` in `helm-vault/vault-values.yaml` are dead
  config.** The chart has no such keys and ignores both. Vault actually reads
  `server.ha.raft.config`, which is why it runs with `tls_disable = 1` and
  serves plain HTTP inside the cluster despite the TLS settings written there;
  externally Cloudflare terminates TLS, so nothing ever looked wrong. Confirmed
  by reading `/vault/config/extraconfig-from-values.hcl` inside the pod. The
  block is kept and marked rather than deleted, because it records the intended
  setup that a real TLS configuration would move into `ha.raft.config`.
- **ArgoCD's own configuration is not in this repo.** It is Helm-managed
  (release `argocd`, chart `argo-cd 7.7.16`) with no Application here and no
  values file committed anywhere — including the helm-secrets and ksops wiring
  that everything above depends on. `helm get values argocd -n argocd` is the
  only record. See `docs/argocd-repo-server-helm-secrets.md`.
- Kyverno enforces cosign signatures only for
  `ghcr.io/nazmang/ai-language-tutor*`. The `renderd` images are unsigned and
  unverified.
