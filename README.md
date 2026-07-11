# home-k3s

A single-node [k3s](https://k3s.io/) setup for my home server. It runs Kubernetes
as the platform for self-hosted services such as **Plex**, **Sonarr**, and
**Radarr**.

Unlike a stock k3s install, this cluster swaps out the bundled components:

- **[Istio](https://istio.io/) (ambient mode)** instead of Traefik for ingress
  and service networking, via the Kubernetes **Gateway API**.
- **[MetalLB](https://metallb.universe.org/)** instead of k3s's ServiceLB
  (`klipper-lb`) for bare-metal `LoadBalancer` services, handing out real IPs
  from your LAN.

## Architecture

```
LAN client ──▶ MetalLB (L2, 192.168.1.200-220)
                 │  assigns ONE IP to the shared Gateway's LoadBalancer Service
                 ▼
            Istio Gateway "home-gateway"  (Gateway API, GatewayClass "istio")
                 │  ┌─────────────┬─────────────┬─────────────┐
                 │  ▼             ▼             ▼             ▼
                 │ HTTPRoute    HTTPRoute    HTTPRoute    HTTPRoute
                 │ (plex)       (sonarr)     (radarr)     (httpbin)
                 ▼
            Service ──▶ Pod (in an ambient-enabled namespace)
```

> **One shared Gateway for everything.** The cluster has a *single* Gateway
> (`home-gateway` in `istio-system`), so MetalLB hands out exactly **one**
> LoadBalancer IP for the whole cluster. Each service does **not** get its own
> Gateway or IP — instead it publishes an `HTTPRoute` whose `parentRef` attaches
> to `home-gateway`, and routing to the right backend is done by host/path rules.

- **k3s** is installed with `traefik` and `servicelb` disabled.
- **Gateway API** CRDs (experimental channel) provide `Gateway` / `HTTPRoute`.
- **MetalLB** runs in L2 mode and advertises an address pool on the local
  network.
- **Istio ambient mode** is used (no per-pod sidecars): `istiod` control plane,
  the `istio-cni` plugin (with k3s-specific CNI paths), and the `ztunnel`
  per-node DaemonSet for L4 traffic. Namespaces opt in with the
  `istio.io/dataplane-mode: ambient` label.

## Repository layout

| Path            | Purpose                                                            |
| --------------- | ----------------------------------------------------------------- |
| `install.sh`    | End-to-end installer — run this to build the whole cluster.        |
| `kustomization.yaml` | Root kustomization referencing all components in dep order.   |
| `metallb/`      | MetalLB manifests + `config.yaml` (IP pool & L2 advertisement).    |
| `istio/`        | Istio ambient install via Helm charts inflated by kustomize.       |
| `gateway/`      | The single **shared Gateway** (`home-gateway`) used by all services. |
| `httpbin/`      | Sample app demonstrating an `HTTPRoute` attached to the shared Gateway. |

## Versions

Pinned in `install.sh`:

| Component     | Version   |
| ------------- | --------- |
| Kustomize     | 5.4.3     |
| Istio         | 1.29.2    |
| Gateway API   | v1.4.0    |
| MetalLB       | v0.14.8   |

## Prerequisites

- A Linux host to act as the server (tested with k3s on amd64).
- `curl`, `sudo`, and `bash`.
- `kubectl`, `kustomize`, and `helm` — the installer downloads `kustomize` and
  `helm` automatically if they are missing (`helm` is required by
  `kustomize --enable-helm` to inflate the Istio charts).

## Configuration

Before installing, **edit the MetalLB address pool** in
[`metallb/config.yaml`](metallb/config.yaml) to match your network. The IPs must
be on your LAN subnet and outside your router's DHCP range:

```yaml
spec:
  addresses:
  - 192.168.1.200-192.168.1.220
```

## Install

```bash
./install.sh
```

The script is idempotent and, in order:

1. Installs k3s (with Traefik and ServiceLB disabled).
2. Installs `kustomize` and `helm` if missing.
3. Applies the Gateway API CRDs.
4. Installs and configures MetalLB.
5. Installs Istio in ambient mode.
6. Creates the single shared `home-gateway`.
7. Deploys the `httpbin` sample app and waits for it to be ready.

`kubeconfig` is written to `/etc/rancher/k3s/k3s.yaml`:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

## Verify

When the install finishes it prints the Gateway's assigned IP. Test the sample
app:

```bash
GW_IP=$(kubectl get svc -n istio-system home-gateway-istio \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://${GW_IP}/get
```

This IP is the **one** address for the whole cluster — every service is reached
through it.

## Adding a service

To expose a new service (e.g. Plex, Sonarr, Radarr): reuse the shared
`home-gateway` — do **not** create a new Gateway (that would consume another
MetalLB IP and defeats the single-entrypoint design).

1. Create a namespace labeled `istio.io/dataplane-mode: ambient` so its pods are
   enrolled in the ambient mesh.
2. Deploy the app's `Deployment` and `Service`.
3. Add an `HTTPRoute` whose `parentRef` points at `home-gateway` in
   `istio-system`, and use host/path rules to select the traffic for this
   service (see [`httpbin/httproute.yaml`](httpbin/httproute.yaml) for a working
   example).

All services share the single `home-gateway` IP; routing is done by the
`HTTPRoute` rules, not by separate load-balancer IPs.
