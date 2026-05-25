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

- **`monitoring/alloy-stack.yml`** + **`monitoring/alloy-compose.yml`** + **`monitoring/config.alloy`** — optional, independent. Grafana Alloy reads each host's Docker socket and ships Keycloak's JSON logs to an **external** Loki. Loki/Grafana are NOT in this repo. Deploy/remove without touching Keycloak. Both Alloy files share the same `config.alloy` (swarm via Swarm config block, compose via bind-mount).

Edge: an external **nginx** terminates TLS and proxies to Traefik (`:80` on the host / Swarm nodes). Balancing + health live in the cluster (Traefik); nginx config is in the README.

Deploy steps, node labeling, MTU-aware `docker network create`, and the nginx upstream are all in `README.md`. Upgrade procedure in `UPGRADE.md`.

## Things that bite

- **Overlay MTU is load-bearing for clustering (Swarm only).** Create `keycloak-net` with `--opt com.docker.network.driver.mtu=1450` (lower on VPN/nested underlays). VXLAN adds ~50 bytes; too-high MTU silently fragments JGroups/Infinispan and breaks the cluster with no obvious error.

- **JGroups bind address differs by mode.** Both modes use `${JGROUPS_BIND_ADDR:-<default>}` — the default is mode-specific:
  - **Swarm**: default `match-address:10.*` (overlay interface). Swarm containers have two NICs: the overlay (`10.x`, inter-task) and `docker_gwbridge` (`172.x`, egress-only, not routable between hosts). Without the correct bind address, JGroups picks gwbridge and the cluster never forms (view stays `(1)`).
  - **Compose**: default `match-address:172.*` (bridge interface). Override if your `daemon.json` `default-address-pools` puts bridges on a non-172 subnet (e.g. `10.200.x`). Verify: `docker network inspect <project>_keycloak-net --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'`.
  - Confirm cluster formed: `select ip from jgroups_ping` shows the correct subnet IPs; logs reach `ISPN000094 ... (N) [...]`.

- **Traefik label placement differs by mode.** In `docker-compose.yml`, routing labels are **top-level `labels:`** (Traefik's docker provider reads container labels). In swarm stacks, they are under **`deploy.labels:`** (swarmmode reads service labels). Wrong placement → Traefik sees no containers (silent failure). Traefik is configured with `--providers.docker.swarmmode=true` for swarm files and `--providers.docker=true` (no swarmmode) for compose.

- **Clustering uses `jdbc-ping`, not TCPPING.** `KC_CACHE_STACK=jdbc-ping` discovers peers through a DB table — no peer IPs, no multicast, no `initial_hosts`. Don't reintroduce `JGROUPS_DISCOVERY_PROPERTIES`.

- **Container healthcheck uses bash `/dev/tcp` (no curl in the image) and is required for safe upgrades.** The distroless image has `bash` but no `curl`/`wget`, so it probes `:9000/health/ready` via `exec 3<>/dev/tcp/...`. It must be `[[ "$$l" == *200* ]]` — `$$` escapes Compose interpolation; a single `$l` becomes empty and the check fails forever. Without it, Docker/Swarm marks a node "up" the instant the process starts (not when Keycloak is READY ~50s later). See `UPGRADE.md`.

- **No zero-downtime upgrade in Docker Compose.** `docker compose up -d` restarts containers in-place — each replica is briefly unavailable (~50–60s) while it restarts. Zero-downtime rolling upgrade is a Swarm-only capability (governed by `update_config` + healthcheck gating). If you need zero-downtime, use a Swarm stack.

- **`docker stack deploy` doesn't read `.env`.** Source it: `set -a; . ./.env; set +a`. Same for `monitoring/.env`. `docker compose` also doesn't auto-export `.env` to the shell — source it the same way.

- **nginx must send `Host: <KEYCLOAK_HOSTNAME>` and `X-Forwarded-*`.** Traefik's router matches on `Host(${KEYCLOAK_HOSTNAME})`, and Keycloak (`KC_PROXY_HEADERS=xforwarded`) builds URLs from the forwarded headers — wrong/missing headers → wrong (http) redirect URLs.

- **HOST_NAME required for compose Alloy.** Compose has no `{{.Node.Hostname}}` template. Pass `HOST_NAME=$(hostname)` in the environment before starting `alloy-compose.yml`, or set it in `.env`. Without it, the `host` label in Loki will be empty or wrong. Swarm fills it automatically via the `{{.Node.Hostname}}` template in `alloy-stack.yml`.

- **Alloy collects all containers on the node** but `config.alloy` keeps only containers matching `.*keycloak.*`. Works for both swarm (`/<stack>_keycloak.<slot>.<hash>`) and compose (`/<project>-keycloak-<replica>`). Runs `user: root` to read the docker socket (prefer `group_add` with the docker GID when hardening). Promtail is deliberately avoided (EOL Feb 2026); Alloy is the successor.

## Versions

Keycloak `26.6.2` (override via `KEYCLOAK_IMAGE_VERSION`), PostgreSQL external, Traefik `v2.11`, Grafana Alloy `v1.16.1`.
