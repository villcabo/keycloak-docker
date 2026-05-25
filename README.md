# Keycloak HA — Docker Compose & Docker Swarm

> 🇬🇧 **English** · 🇪🇸 [Español](./README.es.md)

Keycloak (Identity & Access Management) as an HA cluster. Infrastructure-as-config only.

**Choose your mode by purpose:**

| Mode | When to use |
|---|---|
| **Docker Compose** (`docker-compose.yml`) | Local development / quick single-machine spin-up. No Swarm needed; fast iteration. **Not intended for production.** |
| **Docker Swarm** (`keycloak-stack.yml` / `keycloak-stack.single.yml`) | QA, certification, and production. Single-host or multi-host HA (tolerates a host failure when multi-host); zero-downtime rolling upgrades. |

Same clustering mechanism (`jdbc-ping`), same observability stack — the deploy mode is the only difference.

## Architecture

```
            ┌─────────────┐         your edge (external, not in this repo)
  clients → │ nginx (TLS) │  terminates HTTPS, injects X-Forwarded-*
            └──────┬──────┘
                   │ HTTP :80
            ┌──────▼───────┐
            │   Traefik    │  L7 load balance + health (3s) + retry
            └──────┬───────┘
          ┌────────┼────────┐
      ┌───▼──┐ ┌───▼──┐ ┌───▼──┐
      │ kc 1 │ │ kc 2 │ │ kc 3 │  Keycloak N×  (Infinispan cluster via jdbc-ping)
      └───┬──┘ └───┬──┘ └───┬──┘
          └────────┼────────┘
            ┌───────▼────────┐
            │ PostgreSQL ext │  shared state + cluster discovery
            └────────────────┘
  logs: Keycloak → stdout (JSON) → Alloy (1/host) → external Loki  (independent)
```

## Prerequisites

Shared (both modes):

- External **PostgreSQL** with a `keycloak` schema, reachable from host(s) running Keycloak.
- External **nginx** (or any L7 proxy) for TLS termination — see [Putting nginx in front](#putting-nginx-in-front).
- A `.env` file: `cp .env.example .env` and fill in all values.

Mode-specific:

- **Compose**: Docker Engine with Compose plugin. No Swarm required.
- **Swarm**: Docker Swarm (`docker swarm init`). Overlay network created manually (see below).

## Configure

```bash
bash scripts/env-sync.sh   # create .env from .env.example (run again later to merge new vars)
# Fill in every value marked change_me
set -a; . ./.env; set +a   # export before any deploy command
```

A single `.env` at the repo root covers all modes (compose, swarm, monitoring).
`scripts/env-sync.sh` re-syncs it when `.env.example` gains new variables: it keeps
your values, adds the new keys, and shows a diff for confirmation before applying.

Key variables:

| Variable | Meaning |
|---|---|
| `DATABASE_URL` | JDBC URL, e.g. `jdbc:postgresql://db.internal:5432/keycloak` |
| `DATABASE_USERNAME` / `DATABASE_PASSWORD` | DB credentials |
| `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` | Bootstrap admin (KC 26+) |
| `KEYCLOAK_HOSTNAME` | Public hostname, e.g. `openid.example.com` |
| `KEYCLOAK_IMAGE_VERSION` | Image tag (default `26.6.2`) |
| `JGROUPS_BIND_ADDR` | JGroups bind pattern — leave unset to use the per-mode default |

**JGroups bind note.** Compose default: `match-address:172.*` (bridge). Swarm default: `match-address:10.*` (overlay). If your `daemon.json` uses custom `default-address-pools`, verify the actual subnet before deploying:

```bash
docker network inspect <project>_keycloak-net --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

If the subnet is not `172.x`, set `JGROUPS_BIND_ADDR=match-address:<prefix>.*` in `.env`.

---

## Deploy with Docker Compose

> **Local development / quick single-machine spin-up.** For QA or production, use the Swarm stacks below.

`docker-compose.yml` runs Traefik + N Keycloak replicas on a single host. Scale with `--scale`.

```bash
set -a; . ./.env; set +a
docker compose up -d --scale keycloak=3
docker compose ps   # wait until all containers are (healthy)
```

Confirm cluster formed (must show a 3-member view):

```bash
docker compose logs keycloak | grep ISPN000094 | tail -1
# → ...Received new cluster view ... (3) [...]
```

Scale cheat — do NOT put `replicas:` in `docker-compose.yml`; use `--scale` only:

```bash
docker compose up -d --scale keycloak=1   # single node
docker compose up -d --scale keycloak=2   # two nodes
docker compose up -d --scale keycloak=3   # three nodes (recommended)
```

> Traefik dashboard on `:8080` is diagnostic-only. **Firewall it in production.**

---

## Deploy with Docker Swarm

> **QA, certification, and production path.** Supports single-host and multi-host HA, zero-downtime rolling upgrades, and native Swarm health-gated rollouts.

| File | When to use |
|---|---|
| `keycloak-stack.single.yml` | Single Swarm node (all replicas on one host) |
| `keycloak-stack.yml` | Multi-host Swarm (one replica per labeled node) |

**One-time overlay network:**

```bash
docker network create -d overlay --attachable \
  --opt com.docker.network.driver.mtu=1450 keycloak-net
```

VXLAN adds ~50 bytes. MTU 1450 fits a standard 1500 underlay; lower to ~1400 on WireGuard/VPN.

**Single-host:**

```bash
set -a; . ./.env; set +a
docker stack deploy -c keycloak-stack.single.yml keycloak
docker service logs keycloak_keycloak 2>&1 | grep ISPN000094 | tail -1
```

**Multi-host (3 nodes):** label the nodes first, then deploy:

```bash
docker node update --label-add keycloak=true <node-1>
docker node update --label-add keycloak=true <node-2>
docker node update --label-add keycloak=true <node-3>
set -a; . ./.env; set +a
docker stack deploy -c keycloak-stack.yml keycloak
docker service ps keycloak_keycloak
```

---

## Topology cheat-sheet

Compose = development. Swarm = QA/production.

| Topology | Compose (dev) | Swarm (QA/prod) |
|---|---|---|
| 1 node | `docker compose up -d --scale keycloak=1` | `replicas: 1` + deploy |
| 2 nodes | `docker compose up -d --scale keycloak=2` | `replicas: 2`, label 2 nodes |
| 3 nodes | `docker compose up -d --scale keycloak=3` | `replicas: 3`, label 3 nodes or use single-host file |
| N nodes | `docker compose up -d --scale keycloak=N` | `replicas: N`, label N nodes |

---

## Putting nginx in front

nginx config is the same for both modes. Only the upstream target differs:
- **Compose**: `127.0.0.1:80` (Traefik on the local host).
- **Swarm**: one or more Swarm node IPs on `:80` (ingress mesh).

```nginx
upstream keycloak_backend {
    server node-1.internal:80 max_fails=3 fail_timeout=10s;
    server node-2.internal:80 max_fails=3 fail_timeout=10s;
    server node-3.internal:80 max_fails=3 fail_timeout=10s;
    keepalive 32;
}

server {
    listen 443 ssl;
    http2 on;
    server_name openid.example.com;           # = KEYCLOAK_HOSTNAME

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    location / {
        proxy_pass http://keycloak_backend;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_next_upstream error timeout http_502 http_503;
    }
}
```

---

## Monitoring (optional)

Grafana Alloy reads the Docker socket on each host and ships Keycloak's JSON logs to an external Loki. Loki and Grafana are **not** deployed here. Both modes share `monitoring/config.alloy`.

Query example: `{system="keycloak", service="keycloak"} | json`

**Compose** — Alloy is built into `docker-compose.yml` behind the `monitoring` profile (no separate file). Set `LOKI_REMOTE_URL` and `HOST_NAME` in `.env`, then:

```bash
set -a; . ./.env; set +a
docker compose --profile monitoring up -d --scale keycloak=3
```

Or set `COMPOSE_PROFILES=monitoring` in `.env` and just run `docker compose up -d`.
`HOST_NAME` is required — compose has no `{{.Node.Hostname}}` template.

**Swarm:**

```bash
set -a; . ./.env; set +a
docker stack deploy -c monitoring/alloy-stack.yml keycloak-alloy
```

`HOST_NAME` is filled automatically via `{{.Node.Hostname}}`.

---

## Upgrades

Version bumps recreate containers. See [`UPGRADE.md`](./UPGRADE.md) for the full procedure.

**Zero-downtime rolling upgrade is a Swarm-only capability.** Compose restarts containers in-place (brief downtime per replica).

---

## Operations cheatsheet

| Action | Compose | Swarm |
|---|---|---|
| Follow logs | `docker compose logs -f keycloak` | `docker service logs -f keycloak_keycloak` |
| Container status | `docker compose ps` | `docker service ps keycloak_keycloak` |
| Scale to N | `docker compose up -d --scale keycloak=N` | Edit `replicas: N` + `docker stack deploy` |
| Tear down | `docker compose down` | `docker stack rm keycloak` |
| Rollback | Re-deploy with previous tag | `docker service rollback keycloak_keycloak` |

## License

MIT.
