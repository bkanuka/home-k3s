# docker-compose → k8s migration

Status of moving the legacy docker-compose stack on the server
(`/mnt/main/docker-compose/*`, fronted by a host `nginx` on :80/:443 doing
path-based routing on `home.bkanuka.com` with the compose `oauth2-proxy`) into
this repo. End state: every app on its own `<app>.home.bkanuka.com` behind the
Istio gateway, then nginx and the compose oauth2-proxy are retired.

## Sealing secrets without seeing them

`platform/sealed-secrets/seal.sh` on the server checkout (`~/home-k3s`): write
the plaintext Secret there with a `python3 -I` one-liner that reads the value
from the app's live config file, seal, `rm` the plaintext, `cat` the sealed
file back into the local repo. Don't use `--fetch` on the server — kubeseal
can't verify the API cert from that kubeconfig and truncates `pub-cert.pem`;
`git checkout -- platform/sealed-secrets/pub-cert.pem` restores it.

## Rules

- Text config files live in this repo (ConfigMap via `configMapGenerator`,
  rendered over the hostPath by an initContainer on every start — see
  `applications/qbittorrent`). Secrets inside them become `__PLACEHOLDER__` +
  a SealedSecret.
- DB / sqlite / app-written state stays where it is on the server, mounted
  with `hostPath`.
- Anything under `/mnt/media` or `/mnt/nas` is mounted as an `nfs:` volume
  from `192.168.1.15` (`/mnt/main/media`, `/mnt/main/nas`) with `subPath`,
  not via the host's automount. `/mnt/main`, `/mnt/stripe`, `/mnt/working`
  are local disks → hostPath.
- UI behind Google login (oauth2-proxy ext_authz AuthorizationPolicy +
  allowlist, copied from qbittorrent). API paths (`/api/*`) are exempt from
  Google login and the app validates its own API key — same as nginx's
  `auth_request off` today. (qbittorrent's stricter "must carry a Bearer
  header" variant is only needed there because of its subnet whitelist.)
- Each app's base-path setting is cleared when it moves off `/name/` prefixes.
  Inter-app URLs (`192.168.1.10:<port>`) become cluster DNS.

## Decisions (agreed 2026-11-08)

1. **Frigate LAN exposure**: add one IP to the MetalLB pool and give Frigate a
   `LoadBalancer` Service for `5000/tcp` (unauthenticated API for Home
   Assistant at 192.168.1.204), `1984/tcp` (go2rtc), `8554/tcp` (RTSP),
   `8555/tcp+udp` (WebRTC). Not hostNetwork.
2. **Stirling-pdf**: UI-only behind Google. Its login is off so it has no API
   key; no `/api` exemption.
3. **Paperless remote user**: switch `PAPERLESS_HTTP_REMOTE_USER_HEADER_NAME`
   to `HTTP_X_AUTH_REQUEST_EMAIL` and rename the paperless user `bkanuka` →
   `bkanuka@gmail.com` (nginx used to strip `@gmail.com` into a custom header).

## How the compose stack is run (matters for every cutover)

Each project is a systemd instance of `/etc/systemd/system/docker-compose@.service`
(`docker-compose@<project>.service`, `Restart=always`, `ExecStop` = `compose
down`). A plain `docker compose down` is undone by systemd within seconds. To
retire a project, run on the server (needs sudo, interactive):

    sudo systemctl disable --now docker-compose@<project>

Running instances as of 2026-11-08: ddns-updater, filebrowser, flaresolverr,
frigate, heimdall, jackett, oauth2-proxy, paperless, radarr, sonarr,
stirling-pdf, tautulli.

## Order / status

- [x] **1. Cleanup** (2026-11-08) — dead projects `authentik`, `ombi`,
      `rtorrent`, `transmission-wiregaurd`, `httpbin` downed; compose
      `ddns-updater` unit disabled. Compose dirs left in place.
- [x] **2. flaresolverr → jackett** (2026-11-08) — `applications/jackett/`
      (flaresolverr in the same namespace; only Jackett uses it). No `/api`
      exemption at the gateway (Jackett has no admin password, so its admin API
      would be open) — in-cluster consumers use the Service. **Transitional,
      removed in step 3**: `hostPort: 9117` and `BasePathOverride: /jackett`
      (+ the `/` → `/jackett/` redirect in httproute.yaml), because the compose
      Sonarr/Radarr call `192.168.1.10:9117/jackett/...`.
- [ ] **3. radarr, sonarr** — `applications/{sonarr,radarr}/` pushed; `UrlBase`
      cleared; `/api/*` and `/feed/*` exempt from Google login.
      Cutover: `sudo systemctl disable --now docker-compose@sonarr docker-compose@radarr`
      Then, via their APIs (key read in-container from config.xml):
      - indexers: baseUrl → `http://jackett.jackett.svc.cluster.local:9117/api/v2.0/indexers/<id>/results/torznab/`
        (no `/jackett`) with a **new** Jackett API key (the old one was printed
        in a Sonarr error message during step 2) — then re-seal jackett-apikey,
        clear `BasePathOverride`, drop the hostPort and the `/` redirect.
      - download client qBittorrent: `192.168.1.10:8973` (dead since the compose
        pia-qbittorrent stopped) → `qbittorrent.qbittorrent.svc.cluster.local:8888`
        (pod CIDR 10.42.0.0/16 is in qBittorrent's AuthSubnetWhitelist).
      - Plex notification: `192.168.1.10:32400` (dead) → `plex.plex.svc.cluster.local:32400`.
      Old URLs `home.bkanuka.com/sonarr|/radarr` stop working (new:
      `sonarr.home.bkanuka.com`); update any mobile apps.
- [ ] **4. tautulli, paperless, stirling-pdf, filebrowser** (independent)
- [ ] **5. frigate**
- [ ] **6. heimdall** as the `home.bkanuka.com` root → cut nginx over → retire
      nginx + compose oauth2-proxy. nginx also serves `unifi` (needs a k8s
      equivalent like `applications/ha`'s ServiceEntry first) and a stale
      `vouch` site.

## Per-app inventory

| App | Text config → repo | hostPath (stays put) | NFS | Auth |
|---|---|---|---|---|
| radarr | `config.xml` (API key → placeholder) | `/mnt/main/config/radarr` | `Unsorted`→`/downloads`, `Movies`→`/movies` | UI Google; `/api/*` exempt |
| sonarr | `config.xml` (API key → placeholder) | `/mnt/main/config/sonarr` (drop the `/dev/rtc` mount) | `Unsorted`→`/downloads`, `TV`→`/tv` | same |
| jackett | `Jackett/ServerConfig.json` (API key, admin pw → placeholders) | `Jackett/Indexers/`, `Jackett/DataProtection/` | — | UI Google; `/api/*` exempt |
| flaresolverr | none | none | — | ClusterIP only, no route (only jackett uses it) |
| tautulli | none — `config.ini` is UI-written and full of secrets, stays hostPath | `/mnt/main/config/tautulli`; ro `/mnt/main/config/plex/Library/Application Support/Logs` → `/plex-logs` | — | UI Google; `/api/v2` exempt |
| paperless-ngx | env vars → ConfigMap; `PAPERLESS_SECRET_KEY`, `POSTGRES_PASSWORD` → SealedSecret. Drop `FORCE_SCRIPT_NAME`/`STATIC_URL`, set `PAPERLESS_URL=https://paperless.home.bkanuka.com` | `paperless/pgdata` (postgres:15), `paperless/redis`, `paperless/data`, `paperless/export` | `nas/paperless`→media, `nas/paperless-consume`→consume | UI Google + remote-user header; `/api/*` exempt |
| stirling-pdf | `configs/custom_settings.yml` | `configs/` (H2 db, key, cert), `tessdata/`, `customFiles/`, `pipeline/` | — | UI Google only |
| filebrowser | `filebrowser.json` | `database.db`; `/mnt/main`, `/mnt/stripe`, `/mnt/working` | `/mnt/media`, `/mnt/nas` | UI Google; `/share/*`, `/api/public/*` exempt |
| heimdall | none | `/mnt/main/config/heimdall` (`www/app.sqlite`) | — | Google; hostname `home.bkanuka.com` |
| frigate | `config.yaml` (camera creds → placeholders); `PLUS_API_KEY` → SealedSecret | `/mnt/main/config/frigate` (`frigate.db` 1.3 GB, `model_cache/`, `yolov9/`); recordings `/mnt/stripe/nvr` | — | UI Google via `proxy.auth.header_map`; `:5000` unauthenticated on the LB IP |

Frigate extras: 1× `nvidia.com/gpu` (Plex has the other), `privileged`,
`/dev/dri`, 512 MB `/dev/shm` (emptyDir Memory), 1 GB `/tmp/cache`
(emptyDir Memory), `TZ` instead of `/etc/localtime`.

## Current state references

- Compose files: `/mnt/main/docker-compose/<project>/docker-compose.y*ml`
- nginx: `/etc/nginx/sites-enabled/{default,ha,unifi,vouch}`
- Compose oauth2-proxy config: `/mnt/main/config/oauth2-proxy/`
- `/mnt/main/config` has no ZFS snapshots — worth enabling, separately.
