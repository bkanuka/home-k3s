#!/bin/bash
# Bootstrap the home k3s cluster: install k3s, then Argo CD, which installs
# everything else (platform/* and applications/*) from git. Idempotent.
set -euo pipefail

KUBESEAL_VERSION="0.38.4"      # Sealed Secrets CLI (the controller chart is pinned in platform/sealed-secrets/)
YQ_VERSION="4.53.3"            # mikefarah/yq, used by platform/sealed-secrets/seal.sh and .githooks/pre-commit

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEALED_SECRETS_KEY_BACKUP="/mnt/main/config/sealed-secrets/master.key"

# ── host tools (only what platform/sealed-secrets/seal.sh needs) ───────────────
if ! command -v kubeseal >/dev/null 2>&1; then
    echo "==> Installing kubeseal v${KUBESEAL_VERSION}..."
    curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
        | tar xz -C /tmp kubeseal
    sudo mv /tmp/kubeseal /usr/local/bin/kubeseal
else
    echo "==> kubeseal already installed ($(kubeseal --version 2>/dev/null))"
fi
# The Python "yq" has a different CLI; require mikefarah's.
if ! yq --version 2>/dev/null | grep -q mikefarah; then
    echo "==> Installing yq v${YQ_VERSION}..."
    sudo curl -sL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
        -o /usr/local/bin/yq
    sudo chmod +x /usr/local/bin/yq
else
    echo "==> yq already installed ($(yq --version 2>/dev/null))"
fi

# ── k3s ───────────────────────────────────────────────────────────────────────
# Installs k3s-config.yaml as the server config on every run; k3s reads it only at start.
echo "==> Installing k3s config to /etc/rancher/k3s/config.yaml..."
sudo mkdir -p /etc/rancher/k3s
if ! sudo cmp -s "$DIR/k3s-config.yaml" /etc/rancher/k3s/config.yaml; then
    sudo install -m 644 "$DIR/k3s-config.yaml" /etc/rancher/k3s/config.yaml
    [ ! -x /usr/local/bin/k3s ] || echo "    config changed — run 'sudo systemctl restart k3s' to apply it"
fi
if ! command -v k3s >/dev/null 2>&1; then
    echo "==> Installing k3s..."
    curl -sfL https://get.k3s.io | sh -
else
    echo "==> k3s already installed"
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "==> Waiting for k3s node to be ready..."
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
    sleep 3
done
echo "    Node ready."

# ── Sealed Secrets key restore ────────────────────────────────────────────────
# Must happen before the controller first starts: it adopts an existing active key
# instead of generating one, and a fresh key can't decrypt the SealedSecrets in git.
if [ -f "$SEALED_SECRETS_KEY_BACKUP" ]; then
    echo "==> Restoring Sealed Secrets sealing key from $SEALED_SECRETS_KEY_BACKUP..."
    kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "$SEALED_SECRETS_KEY_BACKUP"
fi

# ── Argo CD ─────────────────────────────────────────────────────────────────────
# argocd/base = Argo CD itself; argocd/apps = the ApplicationSets + self-managing
# Application.
echo "==> Bootstrapping Argo CD..."
kubectl apply --server-side --force-conflicts -k "$DIR/argocd/base"  # --server-side: install manifest exceeds the annotation size limit
echo "    Waiting for Argo CD..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl wait --for=condition=Available deployment/argocd-applicationset-controller \
    -n argocd --timeout=180s
echo "==> Installing the ApplicationSets + self-managing Application..."
kubectl apply --server-side --force-conflicts -k "$DIR/argocd/apps"

# ── Sealed Secrets key backup (first install only) ────────────────────────────
# Persists the key the controller generated so the next rebuild can decrypt today's SealedSecrets.
if [ ! -f "$SEALED_SECRETS_KEY_BACKUP" ]; then
    echo "==> Waiting for Argo CD to deploy the sealed-secrets controller..."
    until kubectl get deployment sealed-secrets-controller -n sealed-secrets >/dev/null 2>&1; do
        sleep 5
    done
    kubectl rollout status deployment/sealed-secrets-controller -n sealed-secrets --timeout=300s
    echo "    Backing up sealing key to $SEALED_SECRETS_KEY_BACKUP..."
    sudo mkdir -p "$(dirname "$SEALED_SECRETS_KEY_BACKUP")"
    kubectl get secret -n sealed-secrets \
        -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
        -o yaml | sudo tee "$SEALED_SECRETS_KEY_BACKUP" >/dev/null
    sudo chmod 600 "$SEALED_SECRETS_KEY_BACKUP"
    echo "    ⚠ Keep an OFF-BOX copy of this file."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==> Bootstrap complete. Argo CD is syncing platform/* and applications/* from git."
echo ""
# SealedSecrets not yet committed; their apps fail to build in Argo CD until sealed.
missing=()
for f in platform/cert-manager/gandi-credentials-sealed.yaml argocd/argocd-secret-sealed.yaml \
         platform/oauth2-proxy/oauth2-proxy-secret-sealed.yaml \
         applications/qbittorrent/pia-credentials-sealed.yaml; do
    [ -f "$DIR/$f" ] || missing+=("$f")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "SealedSecrets not in the repo yet (their apps stay errored in Argo CD until sealed):"
    printf '    %s\n' "${missing[@]}"
    echo "  For each: copy the <name>.yaml.example beside it to <name>.yaml, fill it in, then"
    echo "    ./platform/sealed-secrets/seal.sh --fetch <name>.yaml ...   # once the controller is up"
    echo "    git add -A && git commit && git push                         # the *-sealed.yaml + pub-cert.pem"
    echo ""
fi
echo "Watch it converge (platform/* first — CRDs, MetalLB, Istio — then the apps):"
echo "  kubectl get applications -n argocd"
echo ""
echo "Argo CD admin password (break-glass; Google SSO once the OIDC secret is sealed):"
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null && echo || echo "  (not available yet)"
echo "  https://argocd.home.bkanuka.com  (user: admin) — once the gateway has its IP:"
echo "  kubectl get gateway -n istio-system home-gateway"
