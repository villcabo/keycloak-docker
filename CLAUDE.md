# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Infrastructure-as-config (no application code) to run Keycloak as a 3-node HA cluster on **Docker Swarm**, behind an external nginx (TLS), backed by an external PostgreSQL. Only stack YAML, an Alloy log-shipper config, and `.env` files (gitignored).

## Stacks

Everything runs with `docker stack deploy`, never `docker compose`. The Keycloak stacks define a **single** `keycloak` service with `replicas: 3` (not 3 named services) — nodes are stateless and share the DB, so one service is what lets Traefik load-balance the tasks cleanly.

- **`keycloak-stack.yml`** — multi-host. `placement.max_replicas_per_node: 1` + constraint `node.labels.keycloak == true` → one replica per labeled host. `update_config.order: stop-first` (no room for an extra task at 1/node).
- **`keycloak-stack.single.yml`** — single-host. All 3 replicas on one node, no placement constraints. `update_config.order: start-first` (room for the extra task during rollout).
- **`monitoring/alloy-stack.yml`** + **`monitoring/config.alloy`** — optional, independent. Grafana Alloy (`mode: global`, 1/node) reads each node's Docker socket and ships Keycloak's JSON logs to an **external** Loki. Loki/Grafana are NOT in this repo. Deploy/remove without touching Keycloak.

Edge: an external **nginx** terminates TLS and proxies to Traefik (`:80` on the Swarm nodes). Balancing + health live in the cluster (Traefik); nginx config is in the README.

Deploy steps, node labeling, MTU-aware `docker network create`, and the nginx upstream are all in `README.md`. Upgrade procedure in `UPGRADE.md`.

## Things that bite

- **Overlay MTU is load-bearing for clustering.** Create `keycloak-net` with `--opt com.docker.network.driver.mtu=1450` (lower on VPN/nested underlays). VXLAN adds ~50 bytes; too-high MTU silently fragments JGroups/Infinispan and breaks the cluster with no obvious error.
- **JGroups must be pinned to the overlay interface or the cluster never forms.** Swarm containers have two NICs: the overlay (`10.x`, inter-task) and `docker_gwbridge` (`172.x`, egress-only, **not routable between hosts**). By default JGroups picks the gwbridge, registers `172.x` in `jgroups_ping`, and every node ends up alone (cluster view `(1)`). Fix (in the stacks): `JAVA_OPTS_APPEND: -Djgroups.bind.address=match-address:10.*`. Verified empirically. Bump `10.*` if your overlay IPAM isn't `10.0.0.0/8`. Confirm: `select ip from jgroups_ping` shows overlay IPs and logs reach `ISPN000094 ... (3) [...]`.
- **Clustering uses `jdbc-ping`, not TCPPING.** `KC_CACHE_STACK=jdbc-ping` discovers peers through a DB table — no peer IPs, no multicast, no `initial_hosts`. Don't reintroduce `JGROUPS_DISCOVERY_PROPERTIES`.
- **Swarm reads service labels from `deploy.labels`, not top-level `labels`.** Traefik routing labels live under `deploy:`. Traefik runs with `--providers.docker.swarmmode=true` on a manager node.
- **Container healthcheck uses bash `/dev/tcp` (no curl in the image) and is required for safe upgrades.** The distroless image has `bash` but no `curl`/`wget`, so it probes `:9000/health/ready` via `exec 3<>/dev/tcp/...`. It must be `[[ "$$l" == *200* ]]` — `$$` escapes Compose interpolation; a single `$l` becomes empty and the check fails forever. Without it, Swarm marks a node "up" the instant the process starts (not when Keycloak is READY ~50s later), so rolling upgrades drop to 503. See `UPGRADE.md`.
- **Upgrade ≠ hot reload.** Version bumps recreate containers via rolling update; multi-host uses `stop-first`, single-host `start-first`. Run `kc.sh update-compatibility check` before minor/major bumps. See `UPGRADE.md`.
- **`docker stack deploy` doesn't read `.env`.** Source it: `set -a; . ./.env; set +a`. Same for `monitoring/.env`.
- **nginx must send `Host: <KEYCLOAK_HOSTNAME>` and `X-Forwarded-*`.** Traefik's router matches on `Host(${KEYCLOAK_HOSTNAME})`, and Keycloak (`KC_PROXY_HEADERS=xforwarded`) builds URLs from the forwarded headers — wrong/missing headers → wrong (http) redirect URLs.
- **Alloy collects all containers on the node** but `config.alloy` keeps only swarm services matching `.*keycloak.*`. It runs `user: root` to read the docker socket (prefer `group_add` with the docker GID when hardening). Promtail is deliberately avoided (EOL Feb 2026); Alloy is the successor.

## Versions

Keycloak `26.6.2` (override via `KEYCLOAK_IMAGE_VERSION`), PostgreSQL external, Traefik `v2.11`, Grafana Alloy `v1.16.1`.
