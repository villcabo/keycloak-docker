# Keycloak HA on Docker Swarm

> 🇬🇧 **English** · 🇪🇸 [Español](./README.es.md)

Keycloak (Identity & Access Management) deployed as a high-availability cluster on
Docker Swarm: 3 Keycloak nodes behind Traefik, clustered via Infinispan
`jdbc-ping`, backed by an external PostgreSQL. Infrastructure-as-config only —
Compose/stack YAML, no application code.

## Architecture

```
            ┌─────────────┐         your edge (external, not in this repo)
  clients → │ nginx (TLS) │  terminates HTTPS, injects X-Forwarded-*
            └──────┬──────┘
                   │ HTTP :80  (upstream → Swarm nodes)
            ┌──────▼───────┐
            │   Traefik    │  L7 load balance + health (3s) + retry  ← in cluster
            └──────┬───────┘
          ┌────────┼────────┐
      ┌───▼──┐ ┌───▼──┐ ┌───▼──┐
      │ kc 1 │ │ kc 2 │ │ kc 3 │  Keycloak 3×  (Infinispan cluster via jdbc-ping)
      └───┬──┘ └───┬──┘ └───┬──┘
          └────────┼────────┘
            ┌───────▼────────┐
            │ PostgreSQL ext │  shared state + cluster discovery (jdbc-ping)
            └────────────────┘

  logs:  Keycloak → stdout (JSON) → Alloy (1/node) → external Loki   (independent)
```

- **TLS terminates upstream** in your nginx; Traefik speaks plain HTTP and trusts
  `X-Forwarded-*`. Balancing + health live **in the cluster** (Traefik), so nginx
  only needs one upstream.
- **Two topologies**: `keycloak-stack.yml` (multi-host, 1 node per host) and
  `keycloak-stack.single.yml` (single host, 3 replicas on one box).
- **Logging is optional and independent** — see [Monitoring](#monitoring-optional).

## Prerequisites

- A Docker Swarm (init with `docker swarm init` if you don't have one).
- An external **PostgreSQL** reachable from every Swarm node, with a `keycloak` DB.
- An **nginx** (or any L7 proxy) in front for TLS — see [Putting nginx in front](#putting-nginx-in-front).

## 1. Configure environment

```bash
cp .env.example .env
```

| Variable | Meaning |
|---|---|
| `DATABASE_URL` | JDBC URL, e.g. `jdbc:postgresql://db.internal:5432/keycloak` |
| `DATABASE_USERNAME` / `DATABASE_PASSWORD` | DB credentials |
| `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` | bootstrap admin (KC 26+) |
| `KEYCLOAK_HOSTNAME` | public hostname, e.g. `openid.sintesis.com.bo` |
| `KEYCLOAK_IMAGE_VERSION` | image tag (default `26.6.2`) |

Swarm does **not** read `.env` automatically — export it before deploying:

```bash
set -a; . ./.env; set +a
```

## 2. Create the overlay network (mind the MTU)

VXLAN overlay adds ~50 bytes of overhead. The overlay MTU must sit below the
underlay (1500) or JGroups/Infinispan traffic silently fragments and the cluster
breaks. Standard value is **1450** (lower on VPN/WireGuard ≈1400, nested cloud ≈1370).

```bash
docker network create -d overlay --attachable \
  --opt com.docker.network.driver.mtu=1450 keycloak-net
```

## 3a. Deploy — single host

All 3 replicas land on one node. No labels needed.

```bash
set -a; . ./.env; set +a
docker stack deploy -c keycloak-stack.single.yml keycloak

# watch until 3/3 and the container healthcheck reports healthy
watch -n3 'docker service ls --filter name=keycloak; \
           docker ps --filter name=keycloak_keycloak --format "{{.Names}} {{.Status}}"'
```

The first boot takes ~50–60s per node (Quarkus augmentation + boot + cluster join).
Confirm the cluster formed (must reach a 3-member view):

```bash
docker service logs keycloak_keycloak 2>&1 | grep ISPN000094 | tail -1
# → ...Received new cluster view... (3) [node, node, node]
```

## 3b. Deploy — multi host (3 nodes)

One Keycloak replica per labeled node. Label the 3 hosts first:

```bash
docker node update --label-add keycloak=true <node-1>
docker node update --label-add keycloak=true <node-2>
docker node update --label-add keycloak=true <node-3>

set -a; . ./.env; set +a
docker stack deploy -c keycloak-stack.yml keycloak
```

Traefik runs on a manager node (it needs the Swarm API). Verify placement and the
cluster view exactly as in the single-host case. The `jgroups_ping` table must hold
the **overlay** IPs (`10.x`), not gwbridge (`172.x`):

```bash
# from a host that can reach the DB:
psql "$DATABASE_URL_psql" -c "select name, ip, coord from jgroups_ping;"
```

## Putting nginx in front

Traefik is published on `:80` on every node (Swarm ingress mesh). Point nginx at
the Swarm nodes; Traefik (behind the mesh) load-balances across the 3 Keycloak
replicas and drops unhealthy ones. nginx terminates TLS and **must** send the
public `Host` header (so Traefik's router matches) and the `X-Forwarded-*` headers.

```nginx
upstream keycloak_swarm {
    # List several nodes for entrypoint HA; Traefik + mesh balance behind them.
    server node-1.internal:80 max_fails=3 fail_timeout=10s;
    server node-2.internal:80 max_fails=3 fail_timeout=10s;
    server node-3.internal:80 max_fails=3 fail_timeout=10s;
    keepalive 32;
}

server {
    listen 443 ssl;
    http2 on;
    server_name openid.sintesis.com.bo;          # = KEYCLOAK_HOSTNAME

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    location / {
        proxy_pass http://keycloak_swarm;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;        # must equal KEYCLOAK_HOSTNAME
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;        # TLS terminates here
        proxy_set_header X-Forwarded-Host  $host;
        # Retry the next node if one is draining (e.g. during a rolling upgrade)
        proxy_next_upstream error timeout http_502 http_503;
    }

    # Optional: redirect plain HTTP to HTTPS
}
```

> The Keycloak stacks also inject `X-Forwarded-Proto=https` at Traefik as a safety
> net (for anyone hitting Traefik directly). With nginx in front it's redundant but
> harmless.

## Upgrades

Version bumps are **not** a hot reload — they recreate containers via a Swarm
rolling update with a container healthcheck so the service stays up. Full
procedure, compatibility check, and measured zero-downtime results are in
[`UPGRADE.md`](./UPGRADE.md).

## Monitoring (optional)

Centralized logging is **independent** of the Keycloak stacks — deploy or skip it
without affecting Keycloak. Keycloak logs JSON to stdout
(`KC_LOG_CONSOLE_OUTPUT=json`); **Grafana Alloy** (one per node) reads each node's
Docker socket and ships to **your external Loki**. Loki and Grafana are **not**
deployed here.

```bash
cp monitoring/.env.example monitoring/.env     # set LOKI_REMOTE_URL, tenant, auth
set -a; . ./monitoring/.env; set +a
docker stack deploy -c monitoring/alloy-stack.yml keycloak-alloy
```

Alloy ships with labels `system / service / instance / level / env / host` and
`logger`/`thread` as structured metadata (matching the loki-docker contract). Query
in your Grafana, e.g. `{system="keycloak", service="keycloak"} | json`.

## Operations cheatsheet

```bash
docker service logs -f keycloak_keycloak           # follow logs (JSON)
docker service ps keycloak_keycloak                # task placement / state
docker service scale keycloak_keycloak=0           # full stop (maintenance)
docker stack rm keycloak                           # tear down
```

## License

MIT.
