#!/bin/bash
set -euo pipefail

KUSTOMIZE_VERSION="5.4.3"
ISTIO_VERSION="1.29.2"
GATEWAY_API_VERSION="v1.4.0"
METALLB_VERSION="v0.16.0"
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

# Materialize the `gandi-credentials` Secret from the PAT file on this server.
# The token stays a host file (never in git); the webhook reads this Secret at
# challenge time. Name/key are fixed (the chart RBAC + ClusterIssuer reference
# them). apply-from-dry-run makes it idempotent on re-runs.
GANDI_PAT_FILE="/mnt/main/config/cert-manager/gandi-pat"
if [ ! -f "$GANDI_PAT_FILE" ]; then
    echo "ERROR: Gandi PAT file not found at $GANDI_PAT_FILE"
    echo "       Create it with your (rotated) Gandi Personal Access Token:"
    echo "         sudo mkdir -p \$(dirname $GANDI_PAT_FILE)"
    echo "         printf '%s' '<YOUR_GANDI_PAT>' | sudo tee $GANDI_PAT_FILE >/dev/null"
    echo "       then re-run this script."
    exit 1
fi
echo "==> Creating gandi-credentials Secret from $GANDI_PAT_FILE..."
# Strip whitespace/newlines: a trailing newline in the PAT file produces an
# invalid `Authorization: Bearer <PAT>` header ("invalid header field value"),
# so the Gandi DNS-01 solver fails to create TXT records. --from-literal with a
# whitespace-stripped value is robust even if the file was written with `echo`.
kubectl create secret generic gandi-credentials -n cert-manager \
    --from-literal=pat="$(tr -d '[:space:]' < "$GANDI_PAT_FILE")" \
    --dry-run=client -o yaml | kubectl apply -f -

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

# ── Authentik secret (out-of-band) ───────────────────────────────────────────
# Authentik is an Argo-managed app, but its secret — session key, Postgres
# password, Google OAuth client, bootstrap admin password — must never be in git.
# Seed it from a host env file (mirrors the Gandi pattern). Argo does NOT manage
# or prune this Secret. The `--from-env-file` keys become the Secret's keys.
# Non-fatal if missing: the rest of the cluster still comes up; authentik pods
# just wait until the Secret exists. See applications/authentik/secret.env.example.
AUTHENTIK_ENV_FILE="/mnt/main/config/authentik/authentik.env"
if [ -f "$AUTHENTIK_ENV_FILE" ]; then
    echo "==> Creating authentik-secrets Secret from $AUTHENTIK_ENV_FILE..."
    kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic authentik-secrets -n authentik \
        --from-env-file="$AUTHENTIK_ENV_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    echo "==> WARNING: $AUTHENTIK_ENV_FILE not found."
    echo "    Authentik pods will stay pending until you create it"
    echo "    (see applications/authentik/secret.env.example) and re-run this script"
    echo "    or create the authentik-secrets Secret manually."
fi

# ── PIA credentials for qbittorrent (out-of-band) ─────────────────────────────
# qbittorrent's PIA VPN username/password — never in git. Seeded from a host env
# file into the pia-credentials Secret (keys PIA_USERNAME, PIA_PASSWORD). Argo
# doesn't manage it. Non-fatal if missing. See applications/qbittorrent/pia.env.example.
PIA_ENV_FILE="/mnt/main/config/pia/pia.env"
if [ -f "$PIA_ENV_FILE" ]; then
    echo "==> Creating pia-credentials Secret from $PIA_ENV_FILE..."
    kubectl create namespace qbittorrent --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic pia-credentials -n qbittorrent \
        --from-env-file="$PIA_ENV_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    echo "==> WARNING: $PIA_ENV_FILE not found — qbittorrent pod will stay pending"
    echo "    until you create it (see applications/qbittorrent/pia.env.example) and"
    echo "    re-run this script or create the pia-credentials Secret manually."
fi

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
