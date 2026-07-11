# home-k3s

A single-node [k3s](https://k3s.io/) setup for my home server. It runs Kubernetes
as the platform for self-hosted services such as **Plex**, **Sonarr**, and
**Radarr**.

Unlike a stock k3s install, this cluster swaps out the bundled components:

- **[Istio](https://istio.io/)** instead of Traefik for ingress, via the
  Kubernetes **Gateway API**. Runs **ingress-only** (control plane + Gateway) —
  no mesh data plane (no sidecars, no ambient/ztunnel, no istio-cni).
- **[MetalLB](https://metallb.universe.org/)** instead of k3s's ServiceLB
  (`klipper-lb`) for bare-metal `LoadBalancer` services, handing out real IPs
  from your LAN.
- **[Argo CD](https://argo-cd.readthedocs.io/)** for GitOps — it watches this
  repo's `applications/` directory and continuously reconciles the cluster to
  match, so deploying a service is just pushing a commit.

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
            Service ──▶ Pod
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
- **Istio** runs **ingress-only**: just the `istiod` control plane, which
  reconciles Gateway API resources and deploys the gateway's Envoy proxy. There
  is **no mesh data plane** — no sidecars, no ambient `ztunnel`, no `istio-cni`.
  The gateway routes to plain `ClusterIP` services; pods need no special labels.
  - *Why no mesh?* The mesh only adds pod-to-pod mTLS/policy, which is overkill
    for a home lab. Gateway-level auth (JWT / ext_authz) is enforced on the
    gateway proxy and does **not** require the mesh, so it can be added later
    without reintroducing ambient or sidecars.

### Core platform vs. applications (GitOps boundary)

There is a deliberate split in how things are deployed:

| Layer | What | How it's deployed |
| ----- | ---- | ----------------- |
| **Core platform** | k3s, Gateway API CRDs, MetalLB, Istio, the shared Gateway, Argo CD itself | Bootstrapped **imperatively by `install.sh`**. Not managed by Argo CD. |
| **Applications** | Everything under `applications/` (httpbin, and future Plex/Sonarr/Radarr) | Managed by **Argo CD from git**. |

```
git push ──▶ Argo CD (watches applications/*) ──▶ syncs one Application per folder
                                                        │
                                                        ▼
                                          Deployment + Service + HTTPRoute
```

Argo CD only ever touches `applications/`. It never manages MetalLB, Istio, the
Gateway, or itself — so a bad app sync can't take down the networking core.

## Repository layout

| Path            | Purpose                                                            |
| --------------- | ----------------------------------------------------------------- |
| `install.sh`    | End-to-end installer — bootstraps the core platform + Argo CD.     |
| `kustomization.yaml` | Root kustomization for the **core platform only**.            |
| `metallb/`      | MetalLB manifests + `config.yaml` (IP pool & L2 advertisement).    |
| `istio/`        | Istio (ingress-only) install via Helm charts inflated by kustomize. |
| `gateway/`      | The single **shared Gateway** (`home-gateway`) used by all services. |
| `argocd/`       | Argo CD `ApplicationSet` that watches `applications/*`.            |
| `applications/` | **GitOps-managed services.** One folder per app; Argo CD deploys each. |
| `applications/httpbin/` | Sample app — an `HTTPRoute` attached to the shared Gateway. |

## Versions

Pinned in `install.sh`:

| Component     | Version   |
| ------------- | --------- |
| Kustomize     | 5.4.3     |
| Istio         | 1.29.2    |
| Gateway API   | v1.4.0    |
| MetalLB       | v0.16.0   |
| Argo CD       | v3.4.5    |

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
5. Installs Istio (ingress-only — control plane + Gateway API).
6. Creates the single shared `home-gateway`.
7. Installs Argo CD and registers the `applications/` `ApplicationSet`.

After that, **Argo CD** deploys everything under `applications/` (including the
`httpbin` sample) directly from git.

`kubeconfig` is written to `/etc/rancher/k3s/k3s.yaml`:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

## GitOps with Argo CD

Once installed, Argo CD watches the `applications/*` directories in this repo. An
`ApplicationSet` ([`argocd/applicationset.yaml`](argocd/applicationset.yaml))
turns **each subfolder into an Argo CD `Application`** that is synced with
`prune` + `selfHeal` enabled — so the cluster always matches git, and manual
`kubectl` drift gets reverted.

Access the Argo CD UI:

```bash
# initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

kubectl port-forward -n argocd svc/argocd-server 8080:443
# open https://localhost:8080  (user: admin)
```

> **⚠️ Private repo access.** This repo is **private**, so Argo CD needs
> credentials to read it. Either make the repo public (it contains no secrets —
> only private LAN IPs), or register a repository credential in Argo CD:
>
> ```bash
> # using a GitHub personal access token with 'repo' scope
> argocd repo add https://github.com/bkanuka/home-k3s.git \
>   --username bkanuka --password <TOKEN>
> ```
>
> Until Argo CD can read the repo, the `ApplicationSet` will produce no
> Applications.

## Verify

The Argo CD UI (or `kubectl get applications -n argocd`) shows the `httpbin`
Application as `Synced`/`Healthy`. Then test it through the shared gateway:

```bash
GW_IP=$(kubectl get svc -n istio-system home-gateway-istio \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://${GW_IP}/get
```

This IP is the **one** address for the whole cluster — every service is reached
through it.

## Adding a service

Deploying a new service (e.g. Plex, Sonarr, Radarr) is a **git operation** — no
`kubectl apply`, and no new Gateway (that would consume another MetalLB IP and
defeats the single-entrypoint design). Reuse the shared `home-gateway`.

1. Create a folder `applications/<name>/` with a `kustomization.yaml`.
2. In it, define:
   - a namespace for the app,
   - the app's `Deployment` and `Service`,
   - an `HTTPRoute` whose `parentRef` points at `home-gateway` in `istio-system`,
     using host/path rules to select this service's traffic.
   Copy [`applications/httpbin/`](applications/httpbin/) as a working template.
3. `git commit` and `git push`.

Argo CD detects the new folder, creates an `Application`, and deploys it. All
services share the single `home-gateway` IP; routing is done by the `HTTPRoute`
rules, not by separate load-balancer IPs.
