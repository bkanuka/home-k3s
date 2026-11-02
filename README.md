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
  repo's `platform/` and `applications/` directories and continuously reconciles
  the cluster to match, so deploying a service is just pushing a commit.

Bootstrap is deliberately tiny: `install.sh` installs k3s and brings up Argo CD,
and Argo CD installs **everything else** from git — the Gateway API CRDs, MetalLB,
Istio, the GPU plugin, Sealed Secrets, cert-manager, the gateway, and the apps.

## Architecture

```
LAN / Internet ──▶ MetalLB (L2, 192.168.1.200) ──▶ Istio Gateway "home-gateway"
                     ONE LoadBalancer IP              (Gateway API, class "istio")
                                                            │
   listeners:   :80 http (→HTTPS redirect)   :443 https (wildcard+apex TLS)   :32400 tcp (Plex passthrough)
                                                            │   routed by HOSTNAME
        ┌──────────────┬───────────────┬────────────────┬──┴────────────┬───────────────────┐
        ▼              ▼               ▼                ▼                ▼                   ▼
   plex.home…    httpbin.home…   auth.home…        argocd.home…   ddns-updater.home…   (future apps)
   HTTPRoute     HTTPRoute +     HTTPRoute         HTTPRoute      HTTPRoute +
   + TCPRoute    ext_authz 🔒    (oauth2-proxy)    (OIDC→Google)  ext_authz 🔒
        │
        ▼
   Service ──▶ Pod        🔒 = Google login (oauth2-proxy forward-auth) + per-app email allowlist
```

> **One shared Gateway for everything.** The cluster has a *single* Gateway
> (`home-gateway` in `istio-system`), so MetalLB hands out exactly **one**
> LoadBalancer IP for the whole cluster. Each service does **not** get its own
> Gateway or IP — instead it publishes an `HTTPRoute` whose `parentRef` attaches
> to `home-gateway`. **Routing is by hostname**: every app is a subdomain of
> `home.bkanuka.com` (e.g. `plex.home.bkanuka.com`), selected via SNI/Host on the
> shared HTTPS listener. Some apps opt into **Google login** (see
> [Authentication](#authentication-google-login)); Plex additionally gets
> a raw **TCP :32400** listener for its built-in Remote Access.

- **k3s** is installed with `traefik` and `servicelb` disabled
  ([`k3s-config.yaml`](k3s-config.yaml)).
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

### Who deploys what

| Layer | What | How it's deployed |
| ----- | ---- | ----------------- |
| **k3s** | k3s itself, configured by [`k3s-config.yaml`](k3s-config.yaml) (`traefik` + `servicelb` off) | `install.sh` |
| **Argo CD** | Argo CD itself + its config | **Bootstrapped once** by `install.sh` (`kubectl apply -k argocd/base` + `argocd/apps`), then **self-managed** via git (`argocd/`, incl. its own HTTPRoute + webhook secret). |
| **Platform** | Everything under `platform/` — Gateway API CRDs, MetalLB (+ IP pool), Istio (+ ext_authz config), NVIDIA device plugin, Sealed Secrets, cert-manager (+ Gandi webhook + ClusterIssuers), the shared Gateway, oauth2-proxy | Managed by **Argo CD from git** (`platform` ApplicationSet). |
| **Applications** | Everything under `applications/` (httpbin, plex, ddns-updater, qbittorrent, …) | Managed by **Argo CD from git** (`applications` ApplicationSet). |

```
install.sh ──▶ k3s (k3s-config.yaml) ──▶ kubectl apply -k argocd/base, argocd/apps ──▶ Argo CD
                                                                                        │
git push ──▶ Argo CD ──┬─ watches platform/*      ──▶ gateway-api, metallb, istio, nvidia-device-plugin,
                       │                              sealed-secrets, cert-manager, gateway, oauth2-proxy
                       ├─ watches applications/*  ──▶ one Application per folder
                       └─ watches argocd/         ──▶ manages Argo CD itself
```

Nothing is ordered by script. Platform apps depend on each other only through
CRDs and classes (the `Gateway` needs the Gateway API CRDs and Istio's
`GatewayClass`; cert-manager's `SealedSecret` needs the sealed-secrets CRD;
Argo CD's own `HTTPRoute` needs the CRDs too), and every such app simply
retries until its dependency exists. Argo CD itself never depends on the gateway
— it pulls from GitHub outbound — so even if a bad commit broke the networking
core, pushing the fix is enough to recover; you'd lose the UI, not control.

## Secrets (Sealed Secrets)

Every secret in the cluster is committed to git **encrypted** as a `SealedSecret`
and decrypted in-cluster by the
[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) controller —
nothing is created out-of-band with `kubectl create secret`. The plaintext
`kind: Secret` manifest lives **in the app's own directory**, git-ignored and not
listed in its kustomization; [`platform/sealed-secrets/seal.sh`](platform/sealed-secrets/seal.sh)
turns it into the committed `<name>-sealed.yaml` beside it:

```
platform/oauth2-proxy/
├── oauth2-proxy-secret.yaml.example   # template (committed)
├── oauth2-proxy-secret.yaml           # plaintext (git-ignored, NOT in kustomization)
└── oauth2-proxy-secret-sealed.yaml    # SealedSecret (committed, in kustomization)
```

| Plaintext (git-ignored) | → SealedSecret in git | Argo CD app |
| ----------------------- | --------------------- | ----------- |
| `platform/cert-manager/gandi-credentials.yaml` | `platform/cert-manager/gandi-credentials-sealed.yaml` | `cert-manager` |
| `platform/oauth2-proxy/oauth2-proxy-secret.yaml` | `platform/oauth2-proxy/oauth2-proxy-secret-sealed.yaml` | `oauth2-proxy` |
| `applications/qbittorrent/pia-credentials.yaml` | `applications/qbittorrent/pia-credentials-sealed.yaml` | `qbittorrent` |
| `argocd/argocd-secret.yaml` (patch) | `argocd/argocd-secret-sealed.yaml` | `argocd` (self-managed) |

All four are applied by Argo CD; none ship as placeholders, so until a file is
sealed and pushed its app shows a build error in Argo CD (and `install.sh` lists
what's missing at the end).

The argocd one is **patched into** the server-managed `argocd-secret` (only
`webhook.github.secret` + `oidc.google.*` are added; `server.secretkey`,
`admin.password`, `tls.*` stay intact). The controller allows that only if the
*live* Secret carries `sealedsecrets.bitnami.com/patch: "true"` — set by
the `argocd-secret` patch in [`argocd/base/kustomization.yaml`](argocd/base/kustomization.yaml); annotations on
the SealedSecret itself are ignored.

```bash
# on the k3s host, once the controller is up:
cp platform/oauth2-proxy/oauth2-proxy-secret.yaml.example platform/oauth2-proxy/oauth2-proxy-secret.yaml
$EDITOR platform/oauth2-proxy/oauth2-proxy-secret.yaml
./platform/sealed-secrets/seal.sh --fetch platform/oauth2-proxy/oauth2-proxy-secret.yaml   # --fetch: first run / after key rotation
# then commit oauth2-proxy-secret-sealed.yaml + platform/sealed-secrets/pub-cert.pem
```

Plaintext files are git-ignored by name (`*secret*.yaml`, `*credentials*.yaml`,
minus `*-sealed.yaml`); `seal.sh` refuses to seal a file git would track.

> **Guardrail:** a pre-commit hook ([`.githooks/pre-commit`](.githooks/pre-commit))
> refuses any commit whose staged YAML/JSON contains a `kind: Secret` document
> (parsed with [`yq`](https://github.com/mikefarah/yq)) or whose staged content
> has a `PRIVATE KEY` block. Needs `yq` on your machine. Enable it once per clone:
>
> ```bash
> git config core.hooksPath .githooks
> ```

> **⚠️ The sealing key is the one thing you must not lose.** The controller's
> **private** key decrypts every SealedSecret. `install.sh` backs it up to
> `/mnt/main/config/sealed-secrets/master.key` and restores it on a rebuild — keep
> an **off-box copy** too. Lose it and a rebuilt cluster can't decrypt anything in
> git (you'd re-seal every secret from plaintext). The **public** cert
> (`platform/sealed-secrets/pub-cert.pem`) is safe to commit. Full details:
> [`platform/sealed-secrets/README.md`](platform/sealed-secrets/README.md).

## Repository layout

| Path            | Purpose                                                            |
| --------------- | ----------------------------------------------------------------- |
| `install.sh`    | Bootstrap: installs `k3s-config.yaml`, installs k3s, restores the Sealed Secrets key, applies Argo CD. Nothing else. |
| `k3s-config.yaml` | The k3s server config (`/etc/rancher/k3s/config.yaml`): disables `traefik` + `servicelb`, kubeconfig mode. |
| `.githooks/`    | `pre-commit` hook that blocks plaintext `kind: Secret` manifests / private keys (`git config core.hooksPath .githooks`). |
| `platform/`     | **Argo CD-managed cluster plumbing** — one folder = one Application (`platform` ApplicationSet). |
| `platform/gateway-api/` | Gateway API CRDs (experimental channel, for `TCPRoute`), from the pinned upstream release. |
| `platform/metallb/` | MetalLB (native manifest, L2) + `config.yaml` (IP pool & L2 advertisement, wave 1). |
| `platform/istio/` | Istio (ingress-only) `base` + `istiod` Helm charts, incl. the oauth2-proxy `ext_authz` provider and the alpha Gateway API flag. |
| `platform/nvidia-device-plugin/` | NVIDIA k8s device plugin — advertises `nvidia.com/gpu` for GPU workloads (Plex). |
| `platform/sealed-secrets/` | Sealed Secrets controller (Helm) — unseals committed `SealedSecret`s into real `Secret`s. `seal.sh <secret.yaml>` seals a git-ignored plaintext Secret into `<name>-sealed.yaml` beside it; see its README. |
| `platform/cert-manager/` | cert-manager (Helm) + the SINTEF Gandi DNS-01 webhook (`webhook-gandi/`, wave 1) + Let's Encrypt `ClusterIssuer`s (wave 2) for gateway TLS. Gateway API integration needs the `--feature-gates=ExperimentalGatewayAPISupport=true` **and** `--enable-gateway-api` controller flags (see its `kustomization.yaml`). |
| `platform/gateway/` | The single **shared Gateway** (`home-gateway`) — HTTP :80 + HTTPS :443 (wildcard + apex) + TCP :32400 (Plex) listeners. |
| `platform/oauth2-proxy/` | **Google login** for the gateway: oauth2-proxy as Istio's `ext_authz` backend at `auth.home.bkanuka.com`. Apps opt in with an `AuthorizationPolicy`; see [Authentication](#authentication-google-login). |
| `argocd/`       | Self-managed Argo CD. `base/` = install + config; `apps/` = the `platform` + `applications` ApplicationSets and the self-managing `Application`; plus its HTTPRoute (`argocd.home.bkanuka.com`) and the sealed webhook secret, which need CRDs that Argo CD itself installs. |
| `applications/` | **GitOps-managed services.** One folder per app; Argo CD deploys each at `<app>.home.bkanuka.com`. |
| `applications/httpbin/` | Sample app — `HTTPRoute` + Google-login `AuthorizationPolicy` + email `allowlist.yaml` (the reference for protecting a service). |
| `applications/plex/` | Plex Media Server (GPU transcode) — hostname `HTTPRoute` + a TCP `TCPRoute` on :32400 for built-in Remote Access. |
| `applications/ddns-updater/` | Dynamic DNS updater (Gandi) — keeps the apex A record current; UI behind Google login. |
| `applications/qbittorrent/` | qBittorrent over a PIA WireGuard tunnel; Web UI behind Google login. |

## Versions

| Component     | Version   | Pinned in |
| ------------- | --------- | --------- |
| Gateway API   | v1.4.0    | `platform/gateway-api/kustomization.yaml` |
| MetalLB       | v0.16.0   | `platform/metallb/kustomization.yaml` |
| Istio         | 1.29.2    | `platform/istio/kustomization.yaml` |
| NVIDIA device plugin | v0.19.3 | `platform/nvidia-device-plugin/daemonset.yaml` |
| Argo CD       | v3.4.5    | `argocd/base/kustomization.yaml` |
| Sealed Secrets | controller v0.38.4 (chart 2.19.1) | `platform/sealed-secrets/kustomization.yaml`; `kubeseal` v0.38.4 + `yq` v4.53.3 in `install.sh` |
| cert-manager  | v1.21.0   | `platform/cert-manager/kustomization.yaml` |
| cert-manager-webhook-gandi | v0.6.0 | `platform/cert-manager/webhook-gandi/kustomization.yaml` |
| oauth2-proxy  | v7.15.5   | `platform/oauth2-proxy/deployment.yaml` |

## Prerequisites

- A Linux host to act as the server (tested with k3s on amd64).
- `curl`, `sudo`, and `bash`. `kubectl` comes with k3s.
- No `kustomize` or `helm` on the host: Argo CD renders every kustomization
  (Helm charts included) in its repo-server. `install.sh` fetches `kubeseal` and
  `yq` for `seal.sh`. (For local `kustomize build --enable-helm` of a platform
  dir you need both, as before.)

## Configuration

Before installing, **edit the MetalLB address pool** in
[`platform/metallb/config.yaml`](platform/metallb/config.yaml) to match your
network. The IPs must be on your LAN subnet and outside your router's DHCP
range:

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

1. Installs `kubeseal` + `yq` if missing (for `seal.sh`).
2. Installs [`k3s-config.yaml`](k3s-config.yaml) as `/etc/rancher/k3s/config.yaml`
   (Traefik and ServiceLB disabled), installs k3s, and waits for the node.
3. Restores the Sealed Secrets sealing key from the host backup, if one exists
   (before the controller ever starts, so it adopts that key).
4. Bootstraps Argo CD: `kubectl apply -k argocd/base`, then `argocd/apps` (the
   ApplicationSets + self-managing `Application`).
5. On a first-ever install, waits for Argo CD to deploy the Sealed Secrets
   controller and backs up its freshly generated key.

After that, **Argo CD** deploys `platform/*` (Gateway API CRDs, MetalLB, Istio,
GPU plugin, Sealed Secrets, cert-manager, the shared gateway) and
`applications/*` (including the `httpbin` sample) directly from git, and
reconciles its own `argocd/` directory. Order between platform apps is by retry,
not scripting: the `Gateway` waits for the CRDs and Istio's `GatewayClass`,
cert-manager's `SealedSecret` waits for the sealed-secrets CRD, and so on.

> **First-ever install:** no `*-sealed.yaml` exists in git yet, so the apps that
> list one (`cert-manager`, `argocd`, `oauth2-proxy`, `qbittorrent`) show a build
> error until you seal and push — `install.sh` prints exactly which. See
> [Secrets](#secrets-sealed-secrets).

`kubeconfig` is written to `/etc/rancher/k3s/k3s.yaml`:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

## GitOps with Argo CD

Once installed, Argo CD watches the `platform/*` and `applications/*`
directories in this repo. Two `ApplicationSet`s
([`argocd/apps/`](argocd/apps/)) turn **each subfolder into an Argo CD
`Application`** synced with `prune` + `selfHeal` — so the cluster always matches
git, and manual `kubectl` drift gets reverted. The `platform` set additionally
uses server-side apply, `SkipDryRunOnMissingResource` and unlimited retries,
because platform apps create CRs for CRDs that sibling apps provide, and
`ignoreDifferences` for the webhook `caBundle`s that istiod, MetalLB and
cert-manager rewrite at runtime.
Platform kustomizations inflate Helm charts, enabled by
`kustomize.buildOptions: --enable-helm` in
[`argocd/base/cm-patch.yaml`](argocd/base/cm-patch.yaml).

**Argo CD manages itself, too.** `install.sh` bootstraps with `kubectl apply -k
argocd/base` and `argocd/apps`; the latter includes a self-managing `Application`
([`argocd/apps/application-argocd.yaml`](argocd/apps/application-argocd.yaml))
pointed at the `argocd/` directory (base + apps + the sealed webhook secret).
After that, edits to Argo CD's install version, HTTPRoute, or config are
reconciled from git — no need to re-run `install.sh`.

> **Config changes needing a restart:** the insecure-mode setting
> ([`argocd/base/cmd-params-patch.yaml`](argocd/base/cmd-params-patch.yaml)) is read by
> `argocd-server` at startup. Argo CD will sync a change to it, but
> `argocd-server` won't pick it up until it restarts
> (`kubectl rollout restart deploy/argocd-server -n argocd`). Route changes in
> [`argocd/base/httproute.yaml`](argocd/base/httproute.yaml) take effect immediately.

Argo CD is exposed **through the shared gateway** at
**`https://argocd.home.bkanuka.com`** ([`argocd/base/httproute.yaml`](argocd/base/httproute.yaml)),
running in insecure/HTTP mode behind the gateway (which terminates TLS with the
wildcard cert) so it shares the single gateway IP with every other service.

**SSO straight to Google (OIDC).** Argo CD is OIDC-native, so it uses its
built-in OIDC client against Google — *not* the oauth2-proxy forward-auth — and
the `argocd` CLI works too. Google clients are confidential, so the client
id/secret live in `argocd-secret` (sealed; see
[`argocd/argocd-secret.yaml.example`](argocd/argocd-secret.yaml.example)) and
[`argocd/base/cm-patch.yaml`](argocd/base/cm-patch.yaml) references them as
`$oidc.google.clientId` / `$oidc.google.clientSecret`. Google issues no groups
claim for personal accounts, so
[`argocd/base/rbac-patch.yaml`](argocd/base/rbac-patch.yaml) grants `role:admin`
**per email** with `policy.default: ""` — that list is Argo CD's allowlist;
any other Google account can sign in but sees nothing. Log in via the **"Log in
via Google"** button. The OAuth client needs
`https://argocd.home.bkanuka.com/auth/callback` as an authorized redirect URI.

> **Break-glass local admin.** The built-in `admin` account is intentionally left
> enabled as a fallback for when SSO is unavailable (OIDC misconfig, Google
> unreachable, the OIDC secret not yet sealed). Its initial password:
>
> ```bash
> kubectl -n argocd get secret argocd-initial-admin-secret \
>   -o jsonpath='{.data.password}' | base64 -d; echo
> # UI: https://argocd.home.bkanuka.com  (user: admin)
> ```

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
> Until Argo CD can read the repo, the `ApplicationSet`s produce no
> Applications — and since the whole platform (MetalLB, Istio, cert-manager, …)
> is Argo CD-managed, nothing beyond bare k3s + Argo CD comes up.

## Verify

The Argo CD UI (or `kubectl get applications -n argocd`) shows the `httpbin`
Application as `Synced`/`Healthy`. `httpbin` requires Google login, so a
browser hit to `https://httpbin.home.bkanuka.com` should bounce you to Google
and back. From the shell, an unauthenticated request should be a 302 to
`accounts.google.com`:

```bash
GW_IP=$(kubectl get svc -n istio-system home-gateway-istio \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# unauthenticated request -> 302 to Google (via oauth2-proxy)
curl -sk --resolve httpbin.home.bkanuka.com:443:${GW_IP} \
  -o /dev/null -w '%{http_code} -> %{redirect_url}\n' \
  https://httpbin.home.bkanuka.com/get
# oauth2-proxy itself: health + the decisions it makes
kubectl -n oauth2-proxy logs deploy/oauth2-proxy --tail=20
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

**To require login**, copy httpbin's `authorizationpolicy.yaml` (Google login)
and `allowlist.yaml` (which accounts) into the app's folder, change the host and
emails, and list them in its `kustomization.yaml` — see
[Authentication](#authentication-google-login). Otherwise the app is open to
anyone who can reach the gateway.

## Exposing services to the internet (TLS)

The gateway is reachable from the internet at `home.bkanuka.com` (and
subdomains). The pieces:

1. **Fixed LAN IP.** MetalLB pins the gateway to **`192.168.1.200`**
   ([`platform/metallb/config.yaml`](platform/metallb/config.yaml)).
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
   ([`platform/cert-manager/webhook-gandi/`](platform/cert-manager/webhook-gandi/)) — it creates a
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
> # 2. cert-manager Gandi webhook — a plaintext Secret manifest (key `pat`),
> #    git-ignored, in the repo checkout: copy the .example and fill in the PAT.
> platform/cert-manager/gandi-credentials.yaml   # from the .example beside it
> ```
>
> File #2 is **sealed into git** as
> [`platform/cert-manager/gandi-credentials-sealed.yaml`](platform/cert-manager/gandi-credentials-sealed.yaml)
> by `platform/sealed-secrets/seal.sh platform/cert-manager/gandi-credentials.yaml`, then unsealed in-cluster
> by the Sealed Secrets controller. See
> [Secrets (Sealed Secrets)](#secrets-sealed-secrets). Until the PAT is sealed and
> committed, cert issuance fails at the DNS-01 step; until ddns-updater's
> `config.json` exists it can't update DNS. (File #1 is a hostPath mount, **not** a
> k8s Secret, so it is not sealed.)

## Authentication (Google login)

Selected services require **login with a Google account**, and each such service
has its own list of **which** accounts may use it. Two layers, deliberately
separate:

1. **AuthN — [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/)**
   ([`platform/oauth2-proxy/`](platform/oauth2-proxy/)), a single stateless pod
   that talks to Google and acts as Istio's **`ext_authz`** backend. It only
   answers "who is this?" — *any* Google account can sign in
   (`OAUTH2_PROXY_EMAIL_DOMAINS=*`). Its sign-in flow lives on
   **`auth.home.bkanuka.com`** (the one Google redirect URI,
   `https://auth.home.bkanuka.com/oauth2/callback`) and the session cookie is
   scoped to **`.home.bkanuka.com`**, so a login is shared by every app and
   protected apps need no auth paths of their own.
2. **AuthZ — Istio, per app.** oauth2-proxy returns the user's email as
   `x-auth-request-email` on every allowed request (the gateway *overwrites* this
   header from the ext_authz response, so clients can't forge it), and the app's
   own `allowlist.yaml` denies anyone not on its list.

Each protected app carries two `AuthorizationPolicy` objects in its folder
(they target the gateway, so they live in `istio-system`, but are owned by the
app's Argo CD Application):

- [`authorizationpolicy.yaml`](applications/httpbin/authorizationpolicy.yaml) —
  `action: CUSTOM`, provider `oauth2-proxy`, scoped by `hosts:` to the app.
  Unauthenticated → 302 to Google → back to the original URL.
- [`allowlist.yaml`](applications/httpbin/allowlist.yaml) — `action: DENY` for
  that host when `x-auth-request-email` is **not** in the list. Edit the list to
  grant/revoke access to that app alone. An app without an `allowlist.yaml` is
  open to anyone who can log in.

> **Why DENY and not ALLOW?** Istio `ALLOW` policies are workload-scoped: the
> first one attached to `home-gateway` flips *every* host on the gateway to
> default-deny, and rules from different apps' ALLOW policies are OR'd — so app
> A's "allow anything that isn't me" would silently allow app B. `DENY` only
> ever affects what it matches, which keeps each app's list independent.

Istio evaluates CUSTOM → DENY → ALLOW, so by the time the allowlist runs the
user is logged in; an unlisted user gets Envoy's bare `403 RBAC: access denied`.
The provider itself (`oauth2-proxy` in `meshConfig.extensionProviders`, with the
headers forwarded each way) is in
[`platform/istio/kustomization.yaml`](platform/istio/kustomization.yaml).

> **Google OAuth client** — create a *Web application* OAuth client in Google
> Cloud Console with the Authorized redirect URIs
> `https://auth.home.bkanuka.com/oauth2/callback` (oauth2-proxy) and
> `https://argocd.home.bkanuka.com/auth/callback` (Argo CD). Its id/secret and a
> random cookie secret go in the sealed
> [`platform/oauth2-proxy/oauth2-proxy-secret.yaml.example`](platform/oauth2-proxy/oauth2-proxy-secret.yaml.example);
> the same id/secret go in [`argocd/argocd-secret.yaml.example`](argocd/argocd-secret.yaml.example).

**Currently protected:** `httpbin`, `ddns-updater`, `qbittorrent`. To protect
another app, copy httpbin's `authorizationpolicy.yaml` + `allowlist.yaml`,
change the host and the emails, and list both in the app's `kustomization.yaml`
— no change to oauth2-proxy or Istio is needed.

> **Apps that speak OIDC natively** (like Argo CD) should use their own OIDC
> client against Google instead of forward-auth — see
> [GitOps with Argo CD](#gitops-with-argo-cd). Forward-auth is for apps with no
> auth of their own.
