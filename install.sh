#!/bin/bash
set -euo pipefail

KUSTOMIZE_VERSION="5.4.3"
ISTIO_VERSION="1.29.2"
GATEWAY_API_VERSION="v1.4.0"
METALLB_VERSION="v0.16.0"
KUBESEAL_VERSION="0.38.4"   # Sealed Secrets CLI; the controller chart is pinned in sealed-secrets/
YQ_VERSION="4.53.3"         # mikefarah/yq — YAML parser used by sealed-secrets/seal.sh + .githooks/pre-commit
# Argo CD version is pinned in argocd/kustomization.yaml (it is GitOps-managed).

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── k3s ───────────────────────────────────────────────────────────────────────
if ! command -v k3s >/dev/null 2>&1; then
    echo "==> Installing k3s..."
    sudo mkdir -p /etc/rancher/k3s
    sudo tee /etc/rancher/k3s/config.yaml > /dev/null << 'EOF'
disable:
  - traefik
  - servicelb
write-kubeconfig-mode: "0644"
EOF
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

# ── kustomize ─────────────────────────────────────────────────────────────────
if ! command -v kustomize >/dev/null 2>&1; then
    echo "==> Installing kustomize v${KUSTOMIZE_VERSION}..."
    curl -sL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
        | tar xz -C /tmp
    sudo mv /tmp/kustomize /usr/local/bin/kustomize
else
    echo "==> kustomize already installed ($(kustomize version --short 2>/dev/null || kustomize version))"
fi

# ── helm (required by kustomize --enable-helm for Istio chart inflation) ──────
if ! command -v helm >/dev/null 2>&1; then
    echo "==> Installing helm (needed by kustomize --enable-helm)..."
    curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "==> helm already installed ($(helm version --short))"
fi

# ── kubeseal (Sealed Secrets CLI, used by sealed-secrets/seal.sh) ─────────────
if ! command -v kubeseal >/dev/null 2>&1; then
    echo "==> Installing kubeseal v${KUBESEAL_VERSION}..."
    curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
        | tar xz -C /tmp kubeseal
    sudo mv /tmp/kubeseal /usr/local/bin/kubeseal
else
    echo "==> kubeseal already installed ($(kubeseal --version 2>/dev/null))"
fi

# ── yq (YAML parser, used by sealed-secrets/seal.sh to read the plaintext Secrets)
# Single static binary. NOTE: this is mikefarah/yq (Go); the unrelated Python
# "yq" package has a different CLI and will not work.
if ! command -v yq >/dev/null 2>&1; then
    echo "==> Installing yq v${YQ_VERSION}..."
    sudo curl -sL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
        -o /usr/local/bin/yq
    sudo chmod +x /usr/local/bin/yq
else
    echo "==> yq already installed ($(yq --version 2>/dev/null))"
fi

# ── Gateway API CRDs ──────────────────────────────────────────────────────────
# --server-side avoids the 256KB last-applied-configuration annotation limit
# that client-side apply hits on the large httproutes CRD.
echo "==> Applying Gateway API CRDs ${GATEWAY_API_VERSION}..."
kubectl apply --server-side --force-conflicts \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

# ── MetalLB ───────────────────────────────────────────────────────────────────
echo "==> Installing MetalLB ${METALLB_VERSION}..."
kustomize build "$DIR/metallb" | kubectl apply -f -

echo "    Waiting for MetalLB controller..."
kubectl wait --for=condition=Available deployment/controller \
    -n metallb-system --timeout=180s

# MetalLB has no separate webhook deployment — the controller serves the
# validating webhook. It can take a few seconds after the controller is Available
# before the webhook accepts connections, so retry the config apply until it takes.
echo "==> Configuring MetalLB address pool..."
until kubectl apply -f "$DIR/metallb/config.yaml" 2>/dev/null; do
    echo "    Webhook not ready yet, retrying..."
    sleep 3
done

# ── Istio (ingress only) ──────────────────────────────────────────────────────
# Control plane + Gateway API only — no mesh data plane (no ztunnel, no istio-cni).
echo "==> Installing Istio ${ISTIO_VERSION} (ingress only)..."
# --server-side handles CRD-before-CR ordering gracefully
kustomize build --enable-helm "$DIR/istio" \
    | kubectl apply --server-side --force-conflicts -f -

echo "    Waiting for istiod..."
kubectl wait --for=condition=Available deployment/istiod \
    -n istio-system --timeout=300s

# ── Sealed Secrets ─────────────────────────────────────────────────────────────
# Controller that unseals committed SealedSecret CRs into real Secrets, so every
# secret in this repo (gandi-credentials, authentik-secrets, pia-credentials, the
# Argo CD webhook key) lives in git encrypted instead of being created here from
# host files. Installed BEFORE cert-manager because the ClusterIssuer needs the
# gandi-credentials SealedSecret unsealed. See sealed-secrets/README.md.
#
# The controller's PRIVATE key is the one piece of state a rebuild must preserve:
# a fresh key cannot decrypt SealedSecrets sealed against the old public cert. We
# restore it from a host backup if present, else back up the freshly-generated key
# so the NEXT rebuild can still decrypt today's committed SealedSecrets.
SEALED_SECRETS_KEY_BACKUP="/mnt/main/config/sealed-secrets/master.key"

echo "==> Installing Sealed Secrets controller..."
kustomize build --enable-helm "$DIR/sealed-secrets" \
    | kubectl apply --server-side --force-conflicts -f -

# Restore a previously backed-up sealing key, then restart the controller so it
# adopts it (the controller decrypts with ALL keys it holds). Do this before any
# SealedSecret is applied so unsealing uses the key the repo was sealed against.
if [ -f "$SEALED_SECRETS_KEY_BACKUP" ]; then
    echo "    Restoring sealing key from $SEALED_SECRETS_KEY_BACKUP..."
    kubectl apply -f "$SEALED_SECRETS_KEY_BACKUP"
    kubectl -n sealed-secrets rollout restart deployment/sealed-secrets-controller
fi

echo "    Waiting for sealed-secrets controller..."
kubectl rollout status deployment/sealed-secrets-controller \
    -n sealed-secrets --timeout=180s

# No backup yet → persist the key the controller just generated. Without this, a
# rebuilt cluster gets a NEW key and can no longer decrypt the committed
# SealedSecrets (you'd have to re-seal every secret from plaintext).
if [ ! -f "$SEALED_SECRETS_KEY_BACKUP" ]; then
    echo "    Backing up sealing key to $SEALED_SECRETS_KEY_BACKUP..."
    sudo mkdir -p "$(dirname "$SEALED_SECRETS_KEY_BACKUP")"
    kubectl get secret -n sealed-secrets \
        -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
        -o yaml | sudo tee "$SEALED_SECRETS_KEY_BACKUP" >/dev/null
    sudo chmod 600 "$SEALED_SECRETS_KEY_BACKUP"
    echo "    ⚠ Keep an OFF-BOX copy of this file. Then run sealed-secrets/seal.sh"
    echo "      --fetch <secret.yaml>... to seal your secrets against this key"
    echo "      and commit the *-sealed.yaml results."
fi

# First-ever bootstrap gate. The SealedSecrets install.sh applies below are NOT
# shipped as placeholders — they only exist in git once you have sealed real
# values against THIS cluster's key. Stop here (controller is up, so seal.sh
# --fetch works) until they do; on a rebuild with the key restored above, the
# committed files decrypt as-is and this is a no-op.
missing=()
for f in cert-manager/gandi-credentials-sealed.yaml argocd/argocd-secret-sealed.yaml; do
    [ -f "$DIR/$f" ] || missing+=("$f")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo ""
    echo "==> STOP: SealedSecret(s) not in the repo yet:"
    printf '        %s\n' "${missing[@]}"
    echo "    Seal them now (the controller is running), then re-run this script:"
    echo "        cp cert-manager/gandi-credentials.yaml.example cert-manager/gandi-credentials.yaml"
    echo "        cp argocd/argocd-secret.yaml.example argocd/argocd-secret.yaml"
    echo "        \$EDITOR cert-manager/gandi-credentials.yaml argocd/argocd-secret.yaml"
    echo "        ./sealed-secrets/seal.sh --fetch cert-manager/gandi-credentials.yaml argocd/argocd-secret.yaml"
    echo "        git add -A && git commit     # the *-sealed.yaml files + sealed-secrets/pub-cert.pem"
    echo "    (Do the same for applications/*/ secrets — Argo CD syncs those from git.)"
    exit 1
fi

# ── cert-manager ───────────────────────────────────────────────────────────────
# Issues Let's Encrypt TLS certs for the gateway's HTTPS listeners. Installed via
# Helm (--enable-helm) with the Gateway API integration enabled. The ClusterIssuer
# is applied separately below because its validating webhook rejects the CR until
# the webhook pod is ready (same reason MetalLB's config is applied with a retry).
echo "==> Installing cert-manager..."
kustomize build --enable-helm "$DIR/cert-manager" \
    | kubectl apply --server-side --force-conflicts -f -

echo "    Waiting for cert-manager webhook..."
kubectl wait --for=condition=Available deployment/cert-manager-webhook \
    -n cert-manager --timeout=300s

# Gandi DNS-01 webhook — installed after cert-manager so its Issuer/Certificate
# CRs (self-signed serving cert) apply against established CRDs.
echo "==> Installing Gandi DNS-01 webhook..."
kustomize build --enable-helm "$DIR/cert-manager/webhook-gandi" \
    | kubectl apply --server-side --force-conflicts -f -

# The `gandi-credentials` Secret is no longer created here — it ships as a
# SealedSecret (cert-manager/gandi-credentials-sealed.yaml, applied by the
# cert-manager build above) and is unsealed by the sealed-secrets controller.
# Regenerate with `sealed-secrets/seal.sh cert-manager/gandi-credentials.yaml`.
# See sealed-secrets/README.md.

echo "    Waiting for Gandi webhook..."
kubectl wait --for=condition=Available deployment/cert-manager-webhook-gandi \
    -n cert-manager --timeout=300s

echo "==> Configuring Let's Encrypt ClusterIssuers..."
until kubectl apply -f "$DIR/cert-manager/clusterissuer.yaml" 2>/dev/null; do
    echo "    Webhook not ready yet, retrying..."
    sleep 3
done

# ── Shared Gateway ─────────────────────────────────────────────────────────────
# A single Gateway is shared by every service in the cluster. MetalLB assigns it
# one LoadBalancer IP; each service attaches via an HTTPRoute parentRef.
echo "==> Installing shared gateway..."
kustomize build "$DIR/gateway" | kubectl apply -f -

# ── NVIDIA device plugin ───────────────────────────────────────────────────────
# k3s already registers the `nvidia` RuntimeClass (auto-detected container
# runtime). The device plugin advertises `nvidia.com/gpu` so GPU workloads (Plex)
# can be scheduled and transcode in hardware. Runs under runtimeClassName: nvidia.
echo "==> Installing NVIDIA device plugin..."
kustomize build "$DIR/nvidia-device-plugin" | kubectl apply -f -

# ── Argo CD ─────────────────────────────────────────────────────────────────────
# One-time bootstrap of Argo CD via kustomize (install manifest + /argocd config
# + HTTPRoute + ApplicationSet + a self-managing Application). After this, the
# `argocd` Application reconciles the argocd/ directory from git — so changes to
# Argo CD's own config/route/version sync automatically, no re-run of this script.
# --server-side avoids the annotation size limit on the large install manifest.
echo "==> Bootstrapping Argo CD (kustomize)..."
kustomize build "$DIR/argocd" | kubectl apply --server-side --force-conflicts -f -

echo "    Waiting for Argo CD server..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl wait --for=condition=Available deployment/argocd-applicationset-controller \
    -n argocd --timeout=180s

# From here on, services in applications/ are managed by Argo CD via git, and so
# is Argo CD itself. Push a change and Argo CD reconciles the cluster to match.
#
# All secrets are now SealedSecrets committed to git and unsealed by the
# sealed-secrets controller — nothing is created out-of-band here anymore:
#   - gandi-credentials  -> cert-manager/gandi-credentials-sealed.yaml   (applied above)
#   - authentik-secrets  -> applications/authentik/authentik-secrets-sealed.yaml (Argo CD)
#   - pia-credentials    -> applications/qbittorrent/pia-credentials-sealed.yaml (Argo CD)
#   - argocd webhook key -> argocd/argocd-secret-sealed.yaml (patch, applied above)
# None are shipped as placeholders — each *-sealed.yaml appears in git the first
# time you seal real values (the gate after the controller install above walks you
# through it). See sealed-secrets/README.md.

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==> Installation complete!"
echo ""
echo "Gateway status:"
kubectl get gateway -n istio-system home-gateway -o wide 2>/dev/null || true
echo ""
echo "Gateway IP (may take a moment for MetalLB to assign):"
GW_IP=$(kubectl get svc -n istio-system home-gateway-istio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<GATEWAY-IP>")
echo "  ${GW_IP}"
echo ""
echo "Applications (managed by Argo CD):"
kubectl get applications -n argocd 2>/dev/null || echo "  (Argo CD is still syncing; check again shortly)"
echo ""
echo "Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null && echo || echo "  (not available yet)"
echo "Access the Argo CD UI through the gateway (user: admin):"
echo "  http://${GW_IP}/argocd"
echo ""
echo "Test httpbin once Argo CD has synced it:"
echo "  curl http://${GW_IP}/httpbin/get"
