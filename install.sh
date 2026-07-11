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

# ── Shared Gateway ─────────────────────────────────────────────────────────────
# A single Gateway is shared by every service in the cluster. MetalLB assigns it
# one LoadBalancer IP; each service attaches via an HTTPRoute parentRef.
echo "==> Installing shared gateway..."
kustomize build "$DIR/gateway" | kubectl apply -f -

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
