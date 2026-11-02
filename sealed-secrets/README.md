# Sealed Secrets

The [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) controller
lets encrypted secrets live in git. You `kubeseal` a normal `Secret` into a
`SealedSecret` (encrypted with the cluster's **public** key); only the in-cluster
controller holds the private key, so it — and only it — can decrypt it back into a
real `Secret`. This replaces the old out-of-band `kubectl create secret` blocks in
`install.sh`.

## How it's laid out

Each secret lives in the directory of the thing that uses it, as three files:

```
applications/authentik/
├── authentik-secrets.yaml.example   # template with placeholder values (committed)
├── authentik-secrets.yaml           # plaintext Secret — git-ignored, NOT in kustomization.yaml
└── authentik-secrets-sealed.yaml    # SealedSecret — committed, listed in kustomization.yaml
```

`seal.sh <plaintext.yaml>...` seals each file and writes `<name>-sealed.yaml`
next to it. The plaintext must be an ordinary single-document `kind: Secret`
with `metadata.name` **and** `metadata.namespace` (the ciphertext is bound to the
namespace). Annotations are carried into the SealedSecret, which is how
`argocd-secret` gets **patch mode** (`sealedsecrets.bitnami.com/patch: "true"`):
the controller adds only `webhook.github.secret` to the existing, server-managed
`argocd-secret` and never deletes it.

| Plaintext (git-ignored) | → SealedSecret | Applied by |
| ----------------------- | -------------- | ---------- |
| `../cert-manager/gandi-credentials.yaml` | `../cert-manager/gandi-credentials-sealed.yaml` | `install.sh` (core) |
| `../applications/authentik/authentik-secrets.yaml` | `../applications/authentik/authentik-secrets-sealed.yaml` | Argo CD |
| `../applications/qbittorrent/pia-credentials.yaml` | `../applications/qbittorrent/pia-credentials-sealed.yaml` | Argo CD |
| `../argocd/argocd-secret.yaml` (patch) | `../argocd/argocd-secret-sealed.yaml` | `install.sh` (self-managed argocd/) |

Keeping the plaintext out of git is by **file name**: `.gitignore` ignores
`*secret*.yaml` and `*credentials*.yaml` except `*-sealed.yaml`. `seal.sh`
refuses to seal a file that isn't ignored, and `.githooks/pre-commit` blocks any
staged `kind: Secret` as a backstop.

> There are **no placeholder** `*-sealed.yaml` files: each one appears in git the
> first time you seal real values against the cluster's key. Until then the
> referencing kustomization fails to build (Argo CD shows the app as errored,
> `install.sh` stops after installing the controller and tells you what to seal)
> — a loud, honest failure rather than a SealedSecret that silently never unseals.

Adding a new secret: write `<name>.yaml` (and a `.yaml.example`) in the app dir,
run `seal.sh` on it, add `<name>-sealed.yaml` to the dir's `kustomization.yaml`,
commit.

## The sealing key (⚠️ the one thing you must not lose)

The controller generates its private key on first boot. **A rebuilt cluster gets a
new key and can no longer decrypt SealedSecrets sealed against the old one.**
`install.sh` therefore:

- **restores** the key from `/mnt/main/config/sealed-secrets/master.key` if that
  backup exists (applied before the controller becomes active), and
- **backs it up** there after first generation if no backup exists yet.

That single host file is the only cluster state that must survive a wipe (with
the plaintext files backed up too you can always re-seal from scratch). Keep
off-box copies of both. To rotate/replace the key, restore a different
`master.key` and re-run `seal.sh --fetch` on every plaintext secret.

## Sealing / rotating secrets

Needs `kubeseal` and `yq` (both installed by `install.sh`), plus cluster access
for `--fetch`:

```bash
# first time: copy the template next to it and fill in real values
cp applications/authentik/authentik-secrets.yaml.example applications/authentik/authentik-secrets.yaml
$EDITOR applications/authentik/authentik-secrets.yaml

# --fetch refreshes pub-cert.pem from the controller: first run, or after a key rotation
./sealed-secrets/seal.sh --fetch applications/authentik/authentik-secrets.yaml

# later re-seals use the committed pub-cert.pem (offline); several files at once is fine
./sealed-secrets/seal.sh applications/authentik/authentik-secrets.yaml cert-manager/gandi-credentials.yaml
```

`pub-cert.pem` (the controller's **public** cert) is safe to commit — it can only
encrypt, not decrypt.

Then review and commit the `*-sealed.yaml` files + `pub-cert.pem`. Argo CD
applies the app ones; the core ones apply on the next `install.sh` (or a one-off
`kustomize build` apply).

## Verify

```bash
kubectl get pods -n sealed-secrets                 # controller Running
kubectl get sealedsecret -A                        # each Synced
kubectl get secret gandi-credentials -n cert-manager -o jsonpath='{.data.pat}' | head -c1  # exists
```
