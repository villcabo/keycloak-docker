# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Infrastructure-as-config (no application code) to run Keycloak as a HA cluster, behind
an external nginx (TLS), backed by an external PostgreSQL. Two deploy modes with distinct purposes:

- **Docker Compose** (`docker-compose.yml`) — **local development / single-machine spin-up only**. No Swarm needed; scale via `--scale`. Not intended for production (in-place restarts, brief downtime on upgrade).
- **Docker Swarm** (`keycloak-stack.yml` / `keycloak-stack.single.yml`) — **QA, certification, and production**. Single-host or multi-host; real HA (tolerates a host failure when multi-host); zero-downtime rolling upgrades via `update_config` + healthcheck gating.

Files: stack/compose YAML, a shared Alloy log-shipper config, and `.env` files (gitignored).

## Stacks

### Docker Compose

- **`docker-compose.yml`** — single-host. Traefik with `--providers.docker=true` (NOT swarmmode). Keycloak service with no `replicas:` key — topology is controlled by `--scale keycloak=N` on the CLI. Traefik labels are at the **top-level `labels:`** block (NOT under `deploy:`). `JGROUPS_BIND_ADDR` defaults to `match-address:172.*` (bridge network).

### Docker Swarm

Keycloak stacks define a **single** `keycloak` service with `replicas: N` (not N named services) — nodes are stateless and share the DB, so one service is what lets Traefik load-balance the tasks cleanly.

- **`keycloak-stack.yml`** — multi-host. `placement.max_replicas_per_node: 1` + constraint `node.labels.keycloak == true` → one replica per labeled host. `update_config.order: stop-first` (no room for an extra task at 1/node).
- **`keycloak-stack.single.yml`** — single-host. All replicas on one node, no placement constraints. `update_config.order: start-first` (room for the extra task during rollout).

### Monitoring

- Grafana Alloy ships Keycloak's JSON logs to an **external** Loki (Loki/Grafana are NOT in this repo). Optional in both modes. **Compose**: built into `docker-compose.yml` as the `alloy` service behind `profiles: ["monitoring"]` — `docker compose --profile monitoring up -d` (or `COMPOSE_PROFILES=monitoring` in `.env`); no separate file. **Swarm**: `monitoring/alloy-stack.yml` (separate stack, `mode: global`). Both share `monitoring/config.alloy` (compose bind-mounts it; swarm uses a Swarm config block). The compose `alloy` env has no `LOKI_REMOTE_URL:?` guard — compose interpolates the whole file even with the profile off, so a guard would break the plain `docker compose up`.

Edge: an external **nginx** terminates TLS and proxies to Traefik (`:80` on the host / Swarm nodes). Balancing + health live in the cluster (Traefik); nginx config is in the README.

Deploy steps, node labeling, MTU-aware `docker network create`, and the nginx upstream are all in `README.md`. Upgrade procedure in `UPGRADE.md`.

## Commands

No build/lint/test — this is config only. The dev loop is **edit YAML → validate → deploy**.

```bash
# Validate a file (export your .env or dummy vars first, or compose reads ./.env)
docker compose -f docker-compose.yml config -q
docker compose -f keycloak-stack.single.yml config -q

# Create/sync the single root .env from .env.example (preview diff + confirm + backup)
bash scripts/env-sync.sh

# Compose (dev) — N replicas on one host; add the profile for Alloy
docker compose up -d --scale keycloak=3
docker compose --profile monitoring up -d --scale keycloak=3

# Swarm (QA/prod) — export .env first (stack deploy ignores it), create the overlay once
set -a; . ./.env; set +a
docker network create -d overlay --attachable --opt com.docker.network.driver.mtu=1450 keycloak-net
docker stack deploy -c keycloak-stack.single.yml keycloak    # single-host
docker stack deploy -c keycloak-stack.yml keycloak           # multi-host (label nodes first)
docker stack deploy -c monitoring/alloy-stack.yml keycloak-alloy   # monitoring (swarm)

# Confirm the cluster formed (must reach a view of N)
docker service logs keycloak_keycloak 2>&1 | grep ISPN000094 | tail -1   # swarm
docker compose logs keycloak | grep ISPN000094 | tail -1                 # compose
```

Topology is set by `KEYCLOAK_REPLICAS` (swarm, default 3) or `--scale keycloak=N` (compose).

## Things that bite

- **Overlay MTU is load-bearing for clustering (Swarm only).** Create `keycloak-net` with `--opt com.docker.network.driver.mtu=1450` (lower on VPN/nested underlays). VXLAN adds ~50 bytes; too-high MTU silently fragments JGroups/Infinispan and breaks the cluster with no obvious error.

- **JGroups bind address differs by mode.** Both modes use `${JGROUPS_BIND_ADDR:-<default>}` — the default is mode-specific:
  - **Swarm**: default `match-address:10.*` (overlay interface). Swarm containers have two NICs: the overlay (`10.x`, inter-task) and `docker_gwbridge` (`172.x`, egress-only, not routable between hosts). Without the correct bind address, JGroups picks gwbridge and the cluster never forms (view stays `(1)`).
  - **Compose**: default `match-address:172.*` (bridge interface). Override if your `daemon.json` `default-address-pools` puts bridges on a non-172 subnet (e.g. `10.200.x`). Verify: `docker network inspect <project>_keycloak-net --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'`.
  - Confirm cluster formed: `select ip from jgroups_ping` shows the correct subnet IPs; logs reach `ISPN000094 ... (N) [...]`.

- **Traefik label placement differs by mode.** In `docker-compose.yml`, routing labels are **top-level `labels:`** (the `docker` provider reads container labels). In swarm stacks, they are under **`deploy.labels:`** (the `swarm` provider reads service labels). Wrong placement → Traefik sees no containers (silent failure). Traefik **v3** splits these into two providers: compose uses `--providers.docker=true`; swarm stacks use `--providers.swarm=true` (+ `--providers.swarm.endpoint`/`.network`). v2's `--providers.docker.swarmmode=true` is gone.

- **Traefik dashboard is OFF by default; toggled by env + an overlay file (YAML has no port conditional).** Base files publish only `${TRAEFIK_HTTP_PORT:-80}:80` and set `--api.insecure=${TRAEFIK_API_INSECURE:-false}`. The `:8080` publish lives in `traefik-dashboard.yml`, layered with an extra `-f`/`-c` when wanted (`-f docker-compose.yml -f traefik-dashboard.yml` / `-c keycloak-stack.*.yml -c traefik-dashboard.yml`). Enabling needs **both** `TRAEFIK_API_INSECURE=true` (serves the API) **and** the overlay (publishes the port). Ports merge additively across files; `command` does NOT (it replaces), which is why the API flag is env-driven in the base instead of added by the overlay.

- **Traefik v3 Swarm provider polls — `refreshSeconds` must be low for zero-downtime.** The `swarm` provider discovers tasks by polling (default **15s**), so during a rolling update Traefik keeps routing to an already-drained task for up to 15s → bursts of 503. The swarm stacks set `--providers.swarm.refreshSeconds=2s` (measured on a hot deployment: 15s → 28/698 failed, 2s → 0/727). The flag is `refreshSeconds`, **not** `refreshInterval` (that one crashes Traefik: "field not found"). Compose's `docker` provider is event-driven, so this only applies to swarm.

- **Clustering uses `jdbc-ping`, not TCPPING.** `KC_CACHE_STACK=jdbc-ping` discovers peers through a DB table — no peer IPs, no multicast, no `initial_hosts`. Don't reintroduce `JGROUPS_DISCOVERY_PROPERTIES`.

- **Container healthcheck uses bash `/dev/tcp` (no curl in the image) and is required for safe upgrades.** The distroless image has `bash` but no `curl`/`wget`, so it probes `:9000/health/ready` via `exec 3<>/dev/tcp/...`. It must be `[[ "$$l" == *200* ]]` — `$$` escapes Compose interpolation; a single `$l` becomes empty and the check fails forever. Without it, Docker/Swarm marks a node "up" the instant the process starts (not when Keycloak is READY ~50s later). See `UPGRADE.md`.

- **No zero-downtime upgrade in Docker Compose.** `docker compose up -d` restarts containers in-place — each replica is briefly unavailable (~50–60s) while it restarts. Zero-downtime rolling upgrade is a Swarm-only capability (governed by `update_config` + healthcheck gating). If you need zero-downtime, use a Swarm stack.

- **`docker stack deploy` doesn't read `.env`.** Source it: `set -a; . ./.env; set +a`. `docker compose` also doesn't auto-export `.env` — source it the same way. A **single root `.env`** covers all modes (compose, swarm, monitoring); `scripts/env-sync.sh` creates it from `.env.example` and re-merges new keys later (preview + confirm + backup), keeping your overrides.

- **nginx must send `Host: <KEYCLOAK_HOSTNAME>` and `X-Forwarded-*`.** Traefik's router matches on `Host(${KEYCLOAK_HOSTNAME})`, and Keycloak (`KC_PROXY_HEADERS=xforwarded`) builds URLs from the forwarded headers — wrong/missing headers → wrong (http) redirect URLs.

- **HOST_NAME required for compose Alloy.** Compose has no `{{.Node.Hostname}}` template. Set `HOST_NAME` in `.env` (or `HOST_NAME=$(hostname)`) before enabling the `monitoring` profile. Without it, the `host` label in Loki will be empty or wrong. Swarm fills it automatically via the `{{.Node.Hostname}}` template in `alloy-stack.yml`.

- **Alloy collects all containers on the node** but `config.alloy` keeps only containers matching `.*keycloak.*`. Works for both swarm (`/<stack>_keycloak.<slot>.<hash>`) and compose (`/<project>-keycloak-<replica>`). Runs `user: root` to read the docker socket (prefer `group_add` with the docker GID when hardening). Promtail is deliberately avoided (EOL Feb 2026); Alloy is the successor.

## Versions & .env conventions

Keycloak `26.6.2` (`KEYCLOAK_IMAGE_VERSION`), Traefik `v3.7.1`, Grafana Alloy `v1.16.1` (`ALLOY_VERSION`), PostgreSQL external. Swarm replicas via `KEYCLOAK_REPLICAS` (default 3).

Every default lives in the YAML as `${VAR:-default}`. In `.env.example`: the component **version opens each section** (commented, with its default); **uncommented = REQUIRED** (no sane default — DB URL/password, admin password, hostname); **commented = optional** (shown with its default). To make a var commentable, give it a `${VAR:-default}` in the YAML. Passwords never get a default.

Install/deploy details (with secrets) go in `install-notes.local.md` **on the target server**, never in this repo — `*.local.md` is gitignored.
