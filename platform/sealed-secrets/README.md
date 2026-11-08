# Sealed Secrets

The [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) controller
lets encrypted secrets live in git. You `kubeseal` a normal `Secret` into a
`SealedSecret` (encrypted with the cluster's **public** key); only the in-cluster
controller holds the private key, so it — and only it — can decrypt it back into a
real `Secret`. The controller is a platform app deployed by Argo CD
(`argocd/apps/applicationset-platform.yaml`); nothing is created out-of-band.

## How it's laid out

Each secret lives in the directory of the thing that uses it, as three files:

```
applications/authentik/
├── pia-credentials.yaml.example   # template with placeholder values (committed)
├── pia-credentials.yaml           # plaintext Secret — git-ignored, NOT in kustomization.yaml
└── pia-credentials-sealed.yaml    # SealedSecret — committed, listed in kustomization.yaml
```

`seal.sh <plaintext.yaml>...` seals each file and writes `<name>-sealed.yaml`
next to it. The plaintext must be an ordinary single-document `kind: Secret`
with `metadata.name` **and** `metadata.namespace` (the ciphertext is bound to the
namespace). `argocd-secret` uses **patch mode**: the controller adds only the
sealed keys to the existing, server-managed Secret and never deletes it. Note the
controller decides that from `sealedsecrets.bitnami.com/patch: "true"` on the
**live Secret** (set by `the argocd-secret patch in argocd/base/kustomization.yaml`) — annotations on the
SealedSecret or in its template don't count; kubeseal only copies input-Secret
annotations into `spec.template`.

| Plaintext (git-ignored) | → SealedSecret | Argo CD app |
| ----------------------- | -------------- | ----------- |
| `../cert-manager/gandi-credentials.yaml` | `../cert-manager/gandi-credentials-sealed.yaml` | `cert-manager` |
| `../../applications/qbittorrent/pia-credentials.yaml` | `../../applications/qbittorrent/pia-credentials-sealed.yaml` | `qbittorrent` |
| `../../applications/qbittorrent/qbittorrent-apikey-secret.yaml` | `../../applications/qbittorrent/qbittorrent-apikey-secret-sealed.yaml` | `qbittorrent` |
| `../oauth2-proxy/oauth2-proxy-secret.yaml` | `../oauth2-proxy/oauth2-proxy-secret-sealed.yaml` | `oauth2-proxy` |
| `../../argocd/argocd-secret.yaml` (patch) | `../../argocd/argocd-secret-sealed.yaml` | `argocd` (self-managed) |

Keeping the plaintext out of git is by **file name**: `.gitignore` ignores
`*secret*.yaml` and `*credentials*.yaml` except `*-sealed.yaml`. `seal.sh`
refuses to seal a file that isn't ignored, and `.githooks/pre-commit` blocks any
staged `kind: Secret` as a backstop.

> There are **no placeholder** `*-sealed.yaml` files: each one appears in git the
> first time you seal real values against the cluster's key. Until then the
> referencing kustomization fails to build (Argo CD shows the app as errored;
> `install.sh` lists what's missing at the end) — a loud, honest failure rather
> than a SealedSecret that silently never unseals.

Adding a new secret: write `<name>.yaml` (and a `.yaml.example`) in the app dir,
run `seal.sh` on it, add `<name>-sealed.yaml` to the dir's `kustomization.yaml`,
commit.

## The sealing key (⚠️ the one thing you must not lose)

The controller generates its private key on first boot. **A rebuilt cluster gets a
new key and can no longer decrypt SealedSecrets sealed against the old one.** The
key (the `active` sealing-key Secret, as `kubectl get -o yaml`) is kept in two
places, neither of them in git:

- **On the server**: `/mnt/main/config/sealed-secrets/master.key` (root, 0600).
  `install.sh` **restores** from it right after k3s is up — *before* Argo CD
  deploys this controller, which then adopts the existing active key — and
  **backs up** a freshly generated key there on a first-ever install.
- **Here, as the off-box copy**: `platform/sealed-secrets/master.key`. Git-ignored
  by name (`.gitignore`: `master.key`), and `.githooks/pre-commit` rejects any
  staged `PRIVATE KEY` block as a backstop. (Re)fetch it from the cluster with:

  ```bash
  kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml \
    > platform/sealed-secrets/master.key && chmod 600 platform/sealed-secrets/master.key
  ```

If the server copy is lost, put the repo copy back at the host path before running
`install.sh` (or `kubectl apply -f` it into the `sealed-secrets` namespace before
the controller first starts). It also lets you recover a plaintext offline:
`kubeseal --recovery-unseal --recovery-private-key platform/sealed-secrets/master.key < <name>-sealed.yaml`.
With the plaintext files backed up too you can always re-seal from scratch. To
rotate/replace the key, restore a different `master.key` and re-run
`seal.sh --fetch` on every plaintext secret.

## Sealing / rotating secrets

Needs `kubeseal` and `yq` (both installed by `install.sh`), plus cluster access
for `--fetch`:

```bash
# first time: copy the template next to it and fill in real values
cp applications/qbittorrent/pia-credentials.yaml.example applications/qbittorrent/pia-credentials.yaml
$EDITOR applications/qbittorrent/pia-credentials.yaml

# --fetch refreshes pub-cert.pem from the controller: first run, or after a key rotation
./platform/sealed-secrets/seal.sh --fetch applications/qbittorrent/pia-credentials.yaml

# later re-seals use the committed pub-cert.pem (offline); several files at once is fine
./platform/sealed-secrets/seal.sh applications/qbittorrent/pia-credentials.yaml platform/cert-manager/gandi-credentials.yaml
```

`pub-cert.pem` (the controller's **public** cert) is safe to commit — it can only
encrypt, not decrypt.

Then review, commit and push the `*-sealed.yaml` files + `pub-cert.pem` — Argo
CD applies all of them.

## Verify

```bash
kubectl get pods -n sealed-secrets                 # controller Running
kubectl get sealedsecret -A                        # each Synced
kubectl get secret gandi-credentials -n cert-manager -o jsonpath='{.data.pat}' | head -c1  # exists
```
