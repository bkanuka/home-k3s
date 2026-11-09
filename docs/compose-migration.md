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

## User to-do (as of 2026-11-08, after step 5)

Nothing here blocks the cluster; these are UI/external changes only the user can make.

- [ ] **Home Assistant**: Frigate integration host `192.168.1.10:5000` → `192.168.1.201:5000`.
- [ ] **Frigate+**: request a new model — type `yolov9`, size `s`, 320x320 — and
      paste the ID into `applications/frigate/config.yaml` (`model.path`). The
      current `e9f2bb62…` is yolonas 320 from the 2025-07-23 training.
- [ ] **Tautulli**: Settings → Plex Media Server → re-authenticate (stored token is
      rejected with 401). Address is pinned to `plex.plex.svc.cluster.local:32400`.
- [ ] **Sonarr & Radarr**: Settings → Connect → Plex → re-authenticate; host
      `plex.plex.svc.cluster.local`, port `32400`. (Radarr's Kodi notification to
      `osmc.home.bkanuka.com` 404s — fix or delete.)
- [ ] **Sonarr/Radarr/Tautulli/Paperless bookmarks & phone apps**: old
      `home.bkanuka.com/<app>` paths are gone; use `<app>.home.bkanuka.com`.
- [ ] **Cameras** (optional): set substreams to 1280x720 @ 5 fps (how-to comment
      above `detect:` in `applications/frigate/config.yaml`), then ask for the
      detect-on-substream change.
- [ ] **Cameras** (optional): rotate the admin password (it was echoed in an ffprobe
      error during the migration); then reseal `frigate-secrets` (see the
      `.yaml.example`) and commit.
- [ ] **Paperless**: Postgres 15 → 18 (upstream) is a dump/restore of `pgdata`;
      do it deliberately, separately.
- [ ] **ZFS**: `/mnt/main/config` has no snapshots — add a periodic snapshot task.
- [ ] **Step 6 cutover**: check https://home.bkanuka.com, then `sudo systemctl
      disable --now nginx docker-compose@heimdall docker-compose@oauth2-proxy`.
- [ ] **Homepage widgets needing your credentials** (stubs in
      `applications/homepage/services.yaml`): qBittorrent WebUI password, Home
      Assistant long-lived token, TrueNAS API key, Argo CD API token — add to
      the secret (see `.yaml.example`), reseal, uncomment the widget.

Decisions for step 6: no UniFi route (use 192.168.1.1 directly), no legacy
`home.bkanuka.com/<app>` redirects.

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
- [x] **3. radarr, sonarr** (2026-11-08) — `applications/{sonarr,radarr}/`;
      `UrlBase` cleared; `/api/*` and `/feed/*` exempt from Google login (app
      validates the key). Via their APIs: indexers → `jackett.jackett.svc`
      with a rotated Jackett key (old one had been printed in an error
      message); download client → `qbittorrent.qbittorrent.svc:8888`; Jackett's
      transitional hostPort/base path removed. **Leftover for the user**: the
      Plex notification in both apps has an invalid Plex auth token
      (pre-existing) — re-authenticate in Settings → Connect → Plex, host
      `plex.plex.svc.cluster.local:32400`. Radarr's Kodi notification to
      `osmc.home.bkanuka.com` 404s (pre-existing). Old `home.bkanuka.com/sonarr`
      and `/radarr` URLs are gone.
- [x] **4. tautulli, paperless, stirling-pdf, filebrowser** (2026-11-08) —
      compose units were disabled *before* the push this time (two postmasters
      on one pgdata would not see each other's lock). Gotchas hit:
      - Paperless: `enableServiceLinks: false` is required — the `paperless`
        Service injects `PAPERLESS_PORT=tcp://...`, which paperless-ngx reads
        as its listen port. Images follow upstream's compose file
        (`apache/tika:3.3.1.0` — the ghcr.io/paperless-ngx/tika image is gone —
        `gotenberg:8.38`, `valkey:9-alpine`). Valkey can't read the Redis 7.4
        dump; the old one is kept as `paperless/redis/dump.rdb.redis7`.
        Postgres stays at **15** (upstream is 18): moving needs a dump/restore
        of `pgdata`, a separate task. Paperless user renamed `bkanuka` →
        `bkanuka@gmail.com` to match the email header.
      - filebrowser: settings come from env; the DB's Base URL was already
        empty, nothing to reset.
      - **Leftover for the user**: Tautulli's stored Plex token is rejected
        (401 via both the Service and 192.168.1.200) — re-authenticate in
        Settings → Plex Media Server (address is pinned to
        `plex.plex.svc.cluster.local:32400` by the initContainer).
- [x] **5. frigate** (2026-11-08) — `applications/frigate/`; LAN ports on
      **192.168.1.201** (`frigate-lan` LoadBalancer), UI behind Google with
      Frigate's own auth off. Config tuned at the same time (cameras via go2rtc,
      predator-only alerts, motion-only continuous retention; see the comment
      block in config.yaml for how to move detect to 1280x720 substreams once
      the cameras have them). **Leftovers for the user**: point Home
      Assistant's Frigate integration at `192.168.1.201:5000` (was
      `192.168.1.10:5000`); consider rotating the cameras' admin password (it
      was echoed in an ffprobe error during the migration) and resealing
      `frigate-secrets`.
      Later the same day: upgraded to **0.18.2-tensorrt** (config pre-migrated
      to the tiered `record.motion` schema, `version: 0.18-0`, ffmpeg pinned to
      7.0 for the go2rtc `#hardware` transcode; `frigate.db.0.16.1` is the
      pre-upgrade backup on the server) and switched to the Frigate+ 320x320
      model. `chicken` is a Frigate+ *candidate* label: the models emit
      chickens as `bird`. Next model to request in Frigate+: type `yolov9`,
      size `s`, 320x320 (CUDA-graph accelerated in 0.17+; yolonas is not).
- [ ] **6. homepage replaces heimdall; retire nginx + compose oauth2-proxy** —
      `applications/homepage/` (gethomepage.dev) is live on `home.bkanuka.com`
      (gateway `https-apex` listener) and `homepage.home.bkanuka.com`, config in
      git, widget keys sealed (2026-11-08). Heimdall was not migrated: its only
      state was the tile list. nginx on the server is already unreachable by
      name (every `*.home.bkanuka.com` and the apex resolve to the public IP,
      which the router forwards to the gateway); `unifi`/`vouch` sites are dead
      and are not being recreated.
      Cutover (user): `sudo systemctl disable --now nginx docker-compose@heimdall docker-compose@oauth2-proxy`
      Afterwards nothing from `/mnt/main/docker-compose` runs; the dirs and
      `/mnt/main/config/{heimdall,oauth2-proxy}` can be archived or deleted.

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
| frigate | `config.yaml` (camera creds → placeholders); `PLUS_API_KEY` → SealedSecret | `/mnt/main/config/frigate` (`frigate.db` 1.3 GB, `model_cache/`, `yolov9/`); recordings `/mnt/main/nvr` (11 TB) | — | UI Google via `proxy.auth.header_map`; `:5000` unauthenticated on the LB IP |

Frigate extras: 1× `nvidia.com/gpu` (Plex has the other), `privileged`,
`/dev/dri`, 512 MB `/dev/shm` (emptyDir Memory), 1 GB `/tmp/cache`
(emptyDir Memory), `TZ` instead of `/etc/localtime`.

## Current state references

- Compose files: `/mnt/main/docker-compose/<project>/docker-compose.y*ml`
- nginx: `/etc/nginx/sites-enabled/{default,ha,unifi,vouch}`
- Compose oauth2-proxy config: `/mnt/main/config/oauth2-proxy/`
- `/mnt/main/config` has no ZFS snapshots — worth enabling, separately.
