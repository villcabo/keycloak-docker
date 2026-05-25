> 🇬🇧 [English](./README.md) · 🇪🇸 **Español**

# Keycloak HA en Docker Swarm

Keycloak (Gestión de Identidad y Accesos) desplegado como clúster de alta disponibilidad sobre
Docker Swarm: 3 nodos de Keycloak detrás de Traefik, agrupados mediante Infinispan
`jdbc-ping`, respaldados por un PostgreSQL externo. Solo infraestructura-como-configuración —
YAML de Compose/stack, sin código de aplicación.

## Arquitectura

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

- **TLS termina en el upstream** (en tu nginx); Traefik habla HTTP plano y confía en
  `X-Forwarded-*`. El balanceo y el health check viven **dentro del clúster** (Traefik),
  por lo que nginx solo necesita un upstream.
- **Dos topologías**: `keycloak-stack.yml` (multi-host, 1 nodo por host) y
  `keycloak-stack.single.yml` (host único, 3 réplicas en una misma máquina).
- **El logging es opcional e independiente** — ver [Monitoreo](#monitoreo-opcional).

## Requisitos previos

- Un Docker Swarm (inicialízalo con `docker swarm init` si aún no tienes uno).
- Un **PostgreSQL** externo accesible desde cada nodo del Swarm, con una base de datos `keycloak`.
- Un **nginx** (o cualquier proxy L7) al frente para TLS — ver [Configurar nginx al frente](#configurar-nginx-al-frente).

## 1. Configurar el entorno

```bash
cp .env.example .env
```

| Variable | Descripción |
|---|---|
| `DATABASE_URL` | URL JDBC, p. ej. `jdbc:postgresql://db.internal:5432/keycloak` |
| `DATABASE_USERNAME` / `DATABASE_PASSWORD` | Credenciales de la base de datos |
| `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` | Admin de arranque (KC 26+) |
| `KEYCLOAK_HOSTNAME` | Nombre de host público, p. ej. `openid.sintesis.com.bo` |
| `KEYCLOAK_IMAGE_VERSION` | Tag de la imagen (por defecto `26.6.2`) |

Swarm **no** lee `.env` automáticamente — expórtalo antes de desplegar:

```bash
set -a; . ./.env; set +a
```

## 2. Crear la red overlay (ojo con el MTU)

El overlay VXLAN añade ~50 bytes de overhead. El MTU del overlay debe ser menor que el del
underlay (1500), de lo contrario el tráfico de JGroups/Infinispan se fragmenta silenciosamente
y el clúster falla. El valor estándar es **1450** (menor en VPN/WireGuard ≈1400, cloud anidado ≈1370).

```bash
docker network create -d overlay --attachable \
  --opt com.docker.network.driver.mtu=1450 keycloak-net
```

## 3a. Despliegue — host único

Las 3 réplicas se ubican en un solo nodo. No se necesitan etiquetas.

```bash
set -a; . ./.env; set +a
docker stack deploy -c keycloak-stack.single.yml keycloak

# watch until 3/3 and the container healthcheck reports healthy
watch -n3 'docker service ls --filter name=keycloak; \
           docker ps --filter name=keycloak_keycloak --format "{{.Names}} {{.Status}}"'
```

El primer arranque toma ~50–60s por nodo (augmentación de Quarkus + boot + unión al clúster).
Confirma que el clúster se formó (debe alcanzar una vista de 3 miembros):

```bash
docker service logs keycloak_keycloak 2>&1 | grep ISPN000094 | tail -1
# → ...Received new cluster view... (3) [node, node, node]
```

## 3b. Despliegue — multi-host (3 nodos)

Una réplica de Keycloak por nodo etiquetado. Etiqueta los 3 hosts primero:

```bash
docker node update --label-add keycloak=true <node-1>
docker node update --label-add keycloak=true <node-2>
docker node update --label-add keycloak=true <node-3>

set -a; . ./.env; set +a
docker stack deploy -c keycloak-stack.yml keycloak
```

Traefik corre en un nodo manager (necesita la API de Swarm). Verifica el placement y la
vista del clúster igual que en el caso de host único. La tabla `jgroups_ping` debe contener
las IPs **overlay** (`10.x`), no las de gwbridge (`172.x`):

```bash
# from a host that can reach the DB:
psql "$DATABASE_URL_psql" -c "select name, ip, coord from jgroups_ping;"
```

## Configurar nginx al frente

Traefik se publica en `:80` en cada nodo (malla de ingress de Swarm). Apunta nginx a los
nodos del Swarm; Traefik (detrás de la malla) balancea la carga entre las 3 réplicas de
Keycloak y descarta las no saludables. nginx termina TLS y **debe** enviar la cabecera
`Host` pública (para que el router de Traefik coincida) y las cabeceras `X-Forwarded-*`.

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

> Los stacks de Keycloak también inyectan `X-Forwarded-Proto=https` en Traefik como
> red de seguridad (para quien acceda a Traefik directamente). Con nginx al frente es
> redundante pero inofensivo.

## Actualizaciones

Los cambios de versión **no** son una recarga en caliente — recrean contenedores mediante una
actualización gradual de Swarm con un healthcheck de contenedor para que el servicio
permanezca disponible. El procedimiento completo, la verificación de compatibilidad y los
resultados medidos de zero-downtime están en
[`UPGRADE.es.md`](./UPGRADE.es.md).

## Monitoreo (opcional)

El logging centralizado es **independiente** de los stacks de Keycloak — despliégalo u
omítelo sin afectar a Keycloak. Keycloak escribe JSON en stdout
(`KC_LOG_CONSOLE_OUTPUT=json`); **Grafana Alloy** (uno por nodo) lee el socket Docker de
cada nodo y envía los logs a **tu Loki externo**. Loki y Grafana **no** se despliegan aquí.

```bash
cp monitoring/.env.example monitoring/.env     # set LOKI_REMOTE_URL, tenant, auth
set -a; . ./monitoring/.env; set +a
docker stack deploy -c monitoring/alloy-stack.yml keycloak-alloy
```

Alloy envía logs con las etiquetas `system / service / instance / level / env / host` y
`logger`/`thread` como metadatos estructurados (siguiendo el contrato de loki-docker). Consulta
en tu Grafana, p. ej. `{system="keycloak", service="keycloak"} | json`.

## Cheatsheet de operaciones

```bash
docker service logs -f keycloak_keycloak           # follow logs (JSON)
docker service ps keycloak_keycloak                # task placement / state
docker service scale keycloak_keycloak=0           # full stop (maintenance)
docker stack rm keycloak                           # tear down
```

## Licencia

MIT.
