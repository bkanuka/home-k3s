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
LAN / Internet ──▶ MetalLB (L2, 192.168.1.200) ──▶ Istio Gateway "home-gateway"
                     ONE LoadBalancer IP              (Gateway API, class "istio")
                                                            │
   listeners:   :80 http (→HTTPS redirect)   :443 https (wildcard+apex TLS)   :32400 tcp (Plex passthrough)
                                                            │   routed by HOSTNAME
        ┌──────────────┬───────────────┬────────────────┬──┴────────────┬───────────────────┐
        ▼              ▼               ▼                ▼                ▼                   ▼
   plex.home…    httpbin.home…   authentik.home…   argocd.home…   ddns-updater.home…   (future apps)
   HTTPRoute     HTTPRoute +     HTTPRoute         HTTPRoute      HTTPRoute +
   + TCPRoute    ext_authz 🔒                                     ext_authz 🔒
        │
        ▼
   Service ──▶ Pod        🔒 = Authentik forward-auth (Google SSO) in front
```

> **One shared Gateway for everything.** The cluster has a *single* Gateway
> (`home-gateway` in `istio-system`), so MetalLB hands out exactly **one**
> LoadBalancer IP for the whole cluster. Each service does **not** get its own
> Gateway or IP — instead it publishes an `HTTPRoute` whose `parentRef` attaches
> to `home-gateway`. **Routing is by hostname**: every app is a subdomain of
> `home.bkanuka.com` (e.g. `plex.home.bkanuka.com`), selected via SNI/Host on the
> shared HTTPS listener. Some apps opt into **Authentik forward-auth** (see
> [Authentication](#authentication-authentik--google-sso)); Plex additionally gets
> a raw **TCP :32400** listener for its built-in Remote Access.

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
| **Core platform** | k3s, Gateway API CRDs, MetalLB, Istio (+ ext_authz config), the shared Gateway, cert-manager | Bootstrapped **imperatively by `install.sh`**. Not managed by Argo CD. |
| **Argo CD** | Argo CD itself + its route/config | **Bootstrapped once** by `install.sh`, then **self-managed** via git (`argocd/`). |
| **Applications** | Everything under `applications/` (httpbin, plex, ddns-updater, authentik, …) | Managed by **Argo CD from git**. |

```
git push ──▶ Argo CD ──┬─ watches applications/*  ──▶ one Application per folder
                       └─ watches argocd/          ──▶ manages Argo CD itself
                                                        │
                                                        ▼
                                          Deployment + Service + HTTPRoute
```

Argo CD manages `applications/` **and its own `argocd/` directory**, but never
touches MetalLB, Istio, or the Gateway — so a bad app sync can't take down the
networking core. Argo CD is bootstrapped once (`install.sh`) and thereafter
reconciles itself from git via a self-managing `Application`.

## Repository layout

| Path            | Purpose                                                            |
| --------------- | ----------------------------------------------------------------- |
| `install.sh`    | End-to-end installer — bootstraps the core platform + Argo CD.     |
| `kustomization.yaml` | Root kustomization for the **core platform only**.            |
| `metallb/`      | MetalLB manifests + `config.yaml` (IP pool & L2 advertisement).    |
| `istio/`        | Istio (ingress-only) install via Helm charts inflated by kustomize. |
| `gateway/`      | The single **shared Gateway** (`home-gateway`) — HTTP :80 + HTTPS :443 (wildcard + apex) + TCP :32400 (Plex) listeners. |
| `nvidia-device-plugin/` | NVIDIA k8s device plugin — advertises `nvidia.com/gpu` for GPU workloads (Plex). |
| `cert-manager/` | cert-manager (Helm) + Let's Encrypt `ClusterIssuer`s for gateway TLS. Gateway API integration needs the `--feature-gates=ExperimentalGatewayAPISupport=true` **and** `--enable-gateway-api` controller flags (see `cert-manager/kustomization.yaml`). |
| `cert-manager/webhook-gandi/` | SINTEF Gandi DNS-01 webhook — enables wildcard certs. |
| `argocd/`       | Self-managed Argo CD: kustomize install + config + HTTPRoute (`argocd.home.bkanuka.com`) + `ApplicationSet` + the self-managing `Application`. |
| `applications/` | **GitOps-managed services.** One folder per app; Argo CD deploys each at `<app>.home.bkanuka.com`. |
| `applications/httpbin/` | Sample app — `HTTPRoute` + an Authentik forward-auth `AuthorizationPolicy` (the reference for protecting a service). |
| `applications/plex/` | Plex Media Server (GPU transcode) — hostname `HTTPRoute` + a TCP `TCPRoute` on :32400 for built-in Remote Access. |
| `applications/ddns-updater/` | Dynamic DNS updater (Gandi) — keeps the apex A record current; UI protected by Authentik. |
| `applications/authentik/` | **Authentik** identity provider (plain manifests: server, worker, Postgres, Redis) — Google SSO + forward-auth. Config via blueprints. |

## Versions

Pinned in `install.sh`:

| Component     | Version   |
| ------------- | --------- |
| Kustomize     | 5.4.3     |
| Istio         | 1.29.2    |
| Gateway API   | v1.4.0    |
| MetalLB       | v0.16.0   |
| cert-manager  | v1.21.0   |
| cert-manager-webhook-gandi | v0.6.0 |
| NVIDIA device plugin | v0.19.3 |
| Argo CD       | v3.4.5 *(pinned in `argocd/kustomization.yaml`, since Argo CD is GitOps-managed)* |
| Authentik     | 2026.5.4 *(pinned in `applications/authentik/{server,worker}.yaml`)* |

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
7. Bootstraps Argo CD from `argocd/` (one `kustomize build | kubectl apply`),
   which also installs its self-managing `Application`.

After that, **Argo CD** deploys everything under `applications/` (including the
`httpbin` sample) directly from git, and reconciles its own `argocd/` directory.

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

**Argo CD manages itself, too.** `install.sh` bootstraps `argocd/` with a single
`kustomize build | kubectl apply`, which includes a self-managing `Application`
([`argocd/application.yaml`](argocd/application.yaml)) pointed at the `argocd/`
directory. After that, edits to Argo CD's install version, HTTPRoute, or config
are reconciled from git — no need to re-run `install.sh`.

> **Config changes needing a restart:** the insecure-mode setting
> ([`argocd/cmd-params-patch.yaml`](argocd/cmd-params-patch.yaml)) is read by
> `argocd-server` at startup. Argo CD will sync a change to it, but
> `argocd-server` won't pick it up until it restarts
> (`kubectl rollout restart deploy/argocd-server -n argocd`). Route changes in
> [`argocd/httproute.yaml`](argocd/httproute.yaml) take effect immediately.

Argo CD is exposed **through the shared gateway** at
**`https://argocd.home.bkanuka.com`** ([`argocd/httproute.yaml`](argocd/httproute.yaml)),
running in insecure/HTTP mode behind the gateway (which terminates TLS with the
wildcard cert) so it shares the single gateway IP with every other service.

```bash
# initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# then open the UI (user: admin):
#   https://argocd.home.bkanuka.com
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
Application as `Synced`/`Healthy`. `httpbin` is protected by Authentik, so a
browser hit to `https://httpbin.home.bkanuka.com` should redirect you to the
Google login. To test the raw route without auth, resolve the host to the gateway
IP and hit the outpost's ping (bypasses the auth check):

```bash
GW_IP=$(kubectl get svc -n istio-system home-gateway-istio \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# unauthenticated request -> 302 redirect to Authentik
curl -sk --resolve httpbin.home.bkanuka.com:443:${GW_IP} \
  -o /dev/null -w '%{http_code} -> %{redirect_url}\n' \
  https://httpbin.home.bkanuka.com/get
```

This IP is the **one** address for the whole cluster — every service is reached
through it, distinguished by **hostname** (`plex.`, `httpbin.`, `argocd.`, … all
under `home.bkanuka.com`).

## Adding a service

Deploying a new service (e.g. Plex, Sonarr, Radarr) is a **git operation** — no
`kubectl apply`, and no new Gateway (that would consume another MetalLB IP and
defeats the single-entrypoint design). Reuse the shared `home-gateway`.

1. Create a folder `applications/<name>/` with a `kustomization.yaml`.
2. In it, define:
   - a namespace for the app,
   - the app's `Deployment` and `Service`,
   - an `HTTPRoute` whose `parentRef` points at `home-gateway` in `istio-system`
     (`sectionName: https`), with `hostnames: [<name>.home.bkanuka.com]` — the
     folder name becomes the subdomain (the `ApplicationSet` also links it there).
     Add an HTTP→HTTPS redirect route (`sectionName: http`).
   Copy [`applications/httpbin/`](applications/httpbin/) as a working template.
3. `git commit` and `git push`.

Argo CD detects the new folder, creates an `Application`, and deploys it. All
services share the single `home-gateway` IP; routing is by **hostname**, not by
separate load-balancer IPs.

**To require login**, put the app behind Authentik forward-auth — see
[Authentication](#authentication-authentik--google-sso) and copy httpbin's
`AuthorizationPolicy` + outpost route carve-out. Otherwise the app is open to
anyone who can reach the gateway.

## Exposing services to the internet (TLS)

The gateway is reachable from the internet at `home.bkanuka.com` (and
subdomains). The pieces:

1. **Fixed LAN IP.** MetalLB pins the gateway to **`192.168.1.200`**
   ([`metallb/config.yaml`](metallb/config.yaml)).
2. **Dynamic DNS.** The WAN IP is dynamic, so **`ddns-updater`**
   ([`applications/ddns-updater/`](applications/ddns-updater/)) keeps the single
   apex **`home.bkanuka.com`** A record pointed at it via the Gandi API. Add a
   static wildcard **`*.home.bkanuka.com` CNAME → `home.bkanuka.com`** at Gandi so
   every service subdomain (e.g. `plex.home.bkanuka.com`) resolves through it —
   no need to list each subdomain in ddns-updater.
3. **Router port-forward (UniFi).** Forward inbound **TCP 443** to
   `192.168.1.200` (forward **80** too if you want HTTP→HTTPS redirects to work
   from outside; it is *not* needed for certificates — see below).
4. **TLS (wildcard + apex, DNS-01).** The gateway has two **HTTPS :443 listeners**
   — one for **`*.home.bkanuka.com`** and one for the apex **`home.bkanuka.com`**
   (wildcards don't match the apex) — both referencing the same TLS Secret. The
   `cert-manager.io/cluster-issuer: letsencrypt` annotation on the Gateway makes
   **cert-manager** issue **one** Let's Encrypt cert whose SANs are the union of
   both listener hostnames. The challenge is **DNS-01** via the Gandi webhook
   ([`cert-manager/webhook-gandi/`](cert-manager/webhook-gandi/)) — it creates a
   TXT record through the Gandi API, so it needs **no inbound ports** and covers
   every subdomain at once. Validate with the `letsencrypt-staging` issuer first
   to avoid production rate limits, then switch the annotation to `letsencrypt`.

Because the cert is a wildcard, exposing a new service needs **no gateway
change**: just give the app an `HTTPRoute` with `sectionName: https` for its
`<name>.home.bkanuka.com` host plus an HTTP→HTTPS redirect route (see
[`applications/plex/httproute.yaml`](applications/plex/httproute.yaml) as the
template).

> **⚠️ Gandi token — two files on the server (never in git).** Both consume the
> **same** (rotated) Gandi Personal Access Token, kept as files on the k3s host:
>
> ```bash
> # 1. ddns-updater — full provider config JSON (format: config.json.example).
> #    Mounted into the pod via hostPath (see applications/ddns-updater/).
> #    Must be readable/writable by UID 1000.
> /mnt/main/config/ddns-updater/config.json
>
> # 2. cert-manager Gandi webhook — a file containing ONLY the raw PAT:
> sudo mkdir -p /mnt/main/config/cert-manager
> printf '%s' '<YOUR_GANDI_PAT>' | sudo tee /mnt/main/config/cert-manager/gandi-pat >/dev/null
> ```
>
> `install.sh` turns file #2 into the `gandi-credentials` Secret at bootstrap
> (`kubectl create secret generic gandi-credentials -n cert-manager --from-file=pat=...`,
> applied idempotently); it aborts if the file is missing. Until both files
> exist, ddns-updater can't read its config and cert issuance fails at the DNS-01
> step.

## Authentication (Authentik + Google SSO)

Selected services sit behind **[Authentik](https://goauthentik.io/)**, which
brokers **login with Google** and gates access to a single user
(`bkanuka@gmail.com`). Authentik runs as an ordinary GitOps app
([`applications/authentik/`](applications/authentik/), plain manifests — server,
worker, PostgreSQL, Redis) at `authentik.home.bkanuka.com`.

**Enforcement is Istio `ext_authz` forward-auth** — the gateway asks Authentik's
embedded outpost to authorize each request, so no app needs to understand OIDC
and unprotected apps are untouched. The pieces:

1. **Provider** — an `envoyExtAuthzHttp` extension provider named `authentik` in
   Istio's `meshConfig` ([`istio/kustomization.yaml`](istio/kustomization.yaml))
   pointing at the outpost.
2. **Per-app opt-in** — an `AuthorizationPolicy` (`action: CUSTOM`, provider
   `authentik`) in `istio-system`, scoped by `hosts:` to just that app, with the
   outpost's `/outpost.goauthentik.io/*` paths excluded (`notPaths`). Living in
   the app's folder keeps auth co-located with the service it protects.
3. **Sign-in endpoints** — the app's `HTTPRoute` carves `/outpost.goauthentik.io/*`
   to `authentik-server` (cross-namespace, via a `ReferenceGrant` in the authentik
   namespace) so the login/callback runs on the app's own host (needed for cookies).

**Everything in Authentik is config-as-code** via **blueprints**
([`applications/authentik/blueprints.yaml`](applications/authentik/blueprints.yaml),
mounted into server+worker and auto-applied): the Google source, the single
permitted user, the access group, and one proxy-provider + application +
policy-binding per protected app. The Google client id/secret are **not** in git —
the blueprint reads them via `!Env` from the `authentik-secrets` Secret.

> **Google OAuth client** — create a *Web application* OAuth client in Google
> Cloud Console with the Authorized redirect URI **exactly**
> `https://authentik.home.bkanuka.com/source/oauth/callback/google/`.

> **⚠️ Authentik secret — one file on the server (never in git).** `install.sh`
> seeds the `authentik-secrets` Secret from a host env file
> ([`applications/authentik/secret.env.example`](applications/authentik/secret.env.example)
> documents it):
>
> ```bash
> /mnt/main/config/authentik/authentik.env   # session key, PG password,
>                                             # bootstrap admin pw, Google id/secret
> ```
>
> Until it exists, the Authentik pods stay pending. Admin UI:
> `authentik.home.bkanuka.com`, user `akadmin`, password = `AUTHENTIK_BOOTSTRAP_PASSWORD`.

**Currently protected:** `httpbin`, `ddns-updater`. To protect another app, add a
proxy provider + application + policy binding to the blueprint, register the
provider with the embedded outpost, and copy the `AuthorizationPolicy` + outpost
route carve-out (and extend the `ReferenceGrant`) — see `applications/httpbin/`.
