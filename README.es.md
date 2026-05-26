# Keycloak HA — Docker Compose & Docker Swarm

> 🇬🇧 [English](./README.md) · 🇪🇸 **Español**

Keycloak (Gestión de Identidad y Accesos) como clúster de alta disponibilidad. Solo infraestructura-como-configuración.

**Elige el modo según el propósito:**

| Modo | Cuándo usarlo |
|---|---|
| **Docker Compose** (`docker-compose.yml`) | Desarrollo local / puesta en marcha rápida en una sola máquina. No requiere Swarm; iteración ágil. **No está pensado para producción.** |
| **Docker Swarm** (`keycloak-stack.yml` / `keycloak-stack.single.yml`) | QA, certificación y producción. HA en host único o multi-host (tolera la caída de un host en modo multi-host); actualizaciones graduales sin downtime. |

Mismo mecanismo de clustering (`jdbc-ping`), mismo stack de observabilidad — el modo de despliegue es la única diferencia.

## Arquitectura

```
            ┌─────────────┐         tu edge (externo, no está en este repo)
  clients → │ nginx (TLS) │  termina HTTPS, inyecta X-Forwarded-*
            └──────┬──────┘
                   │ HTTP :80
            ┌──────▼───────┐
            │   Traefik    │  balanceo L7 + health (3s) + retry
            └──────┬───────┘
          ┌────────┼────────┐
      ┌───▼──┐ ┌───▼──┐ ┌───▼──┐
      │ kc 1 │ │ kc 2 │ │ kc 3 │  Keycloak N×  (clúster Infinispan via jdbc-ping)
      └───┬──┘ └───┬──┘ └───┬──┘
          └────────┼────────┘
            ┌───────▼────────┐
            │ PostgreSQL ext │  estado compartido + descubrimiento de clúster
            └────────────────┘
  logs: Keycloak → stdout (JSON) → Alloy (1/host) → Loki externo  (independiente)
```

## Requisitos previos

Compartidos (ambos modos):

- **PostgreSQL** externo con esquema `keycloak`, accesible desde el/los host(s) con Keycloak.
- **nginx** externo (o cualquier proxy L7) para terminación TLS — ver [Configurar nginx al frente](#configurar-nginx-al-frente).
- Archivo `.env`: `cp .env.example .env` y completar todos los valores.

Específicos por modo:

- **Compose**: Docker Engine con el plugin Compose. No requiere Swarm.
- **Swarm**: Docker Swarm (`docker swarm init`). Red overlay creada manualmente (ver más abajo).

## Configurar

```bash
bash scripts/env-sync.sh   # crea .env desde .env.example (correlo de nuevo para fusionar vars nuevas)
# Completar todos los valores marcados como change_me
set -a; . ./.env; set +a   # exportar antes de cualquier comando de despliegue
```

Un único `.env` en la raíz cubre todos los modos (compose, swarm, monitoreo).
`scripts/env-sync.sh` lo re-sincroniza cuando `.env.example` suma variables nuevas:
conserva tus valores, agrega las keys nuevas, y muestra un diff para confirmar antes de aplicar.

Variables clave:

| Variable | Descripción |
|---|---|
| `DATABASE_URL` | URL JDBC, p. ej. `jdbc:postgresql://db.internal:5432/keycloak` |
| `DATABASE_USERNAME` / `DATABASE_PASSWORD` | Credenciales de la base de datos |
| `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` | Admin de arranque (KC 26+) |
| `KEYCLOAK_HOSTNAME` | Nombre de host público, p. ej. `openid.example.com` |
| `KEYCLOAK_IMAGE_VERSION` | Tag de la imagen (por defecto `26.6.2`) |
| `JGROUPS_BIND_ADDR` | Patrón de bind de JGroups — dejar sin valor para usar el default por modo |

**Nota sobre JGroups bind.** Default Compose: `match-address:172.*` (bridge). Default Swarm: `match-address:10.*` (overlay). Si tu `daemon.json` usa `default-address-pools` personalizados, verifica la subred real antes de desplegar:

```bash
docker network inspect <project>_keycloak-net --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

Si la subred no es `172.x`, configura `JGROUPS_BIND_ADDR=match-address:<prefijo>.*` en `.env`.

---

## Despliegue con Docker Compose

> **Desarrollo local / puesta en marcha rápida en una sola máquina.** Para QA o producción, utilizar los stacks de Swarm que se describen más abajo.

`docker-compose.yml` ejecuta Traefik + N réplicas de Keycloak en un único host. La topología se ajusta con `--scale`.

```bash
set -a; . ./.env; set +a
docker compose up -d --scale keycloak=3
docker compose ps   # esperar hasta que todos los contenedores estén (healthy)
```

Confirmar que el clúster se formó (debe mostrar una vista de 3 miembros):

```bash
docker compose logs keycloak | grep ISPN000094 | tail -1
# → ...Received new cluster view ... (3) [...]
```

Escalar — NO poner `replicas:` en `docker-compose.yml`; usar solo `--scale`:

```bash
docker compose up -d --scale keycloak=1   # un solo nodo
docker compose up -d --scale keycloak=2   # dos nodos
docker compose up -d --scale keycloak=3   # tres nodos (recomendado)
```

> **El dashboard de Traefik está APAGADO por defecto** (no se publica `:8080`). Para activarlo,
> poné `TRAEFIK_API_INSECURE=true` en `.env` **y** aplicá el overlay `traefik-dashboard.yml`:
> `docker compose -f docker-compose.yml -f traefik-dashboard.yml up -d`. Solo diagnóstico —
> protegerlo con firewall en producción. El puerto HTTP público se cambia con `TRAEFIK_HTTP_PORT`.

---

## Despliegue con Docker Swarm

> **Ruta para QA, certificación y producción.** Soporta HA en host único y multi-host, actualizaciones graduales sin downtime y rollouts con verificación de salud nativa de Swarm.

| Archivo | Cuándo usarlo |
|---|---|
| `keycloak-stack.single.yml` | Un solo nodo Swarm (todas las réplicas en un host) |
| `keycloak-stack.yml` | Swarm multi-host (una réplica por nodo etiquetado) |

**Red overlay (una sola vez):**

```bash
docker network create -d overlay --attachable \
  --opt com.docker.network.driver.mtu=1450 keycloak-net
```

VXLAN agrega ~50 bytes. MTU 1450 cabe en un underlay estándar de 1500; reducir a ~1400 en WireGuard/VPN.

**Host único:**

```bash
set -a; . ./.env; set +a
docker stack deploy -c keycloak-stack.single.yml keycloak
docker service logs keycloak_keycloak 2>&1 | grep ISPN000094 | tail -1
```

**Multi-host (3 nodos):** etiquetar los nodos primero, luego desplegar:

```bash
docker node update --label-add keycloak=true <node-1>
docker node update --label-add keycloak=true <node-2>
docker node update --label-add keycloak=true <node-3>
set -a; . ./.env; set +a
docker stack deploy -c keycloak-stack.yml keycloak
docker service ps keycloak_keycloak
```

> **Dashboard de Traefik opcional (swarm):** poné `TRAEFIK_API_INSECURE=true` y agregá el
> overlay: `docker stack deploy -c keycloak-stack.single.yml -c traefik-dashboard.yml keycloak`.

---

## Cheatsheet de topología

Compose = desarrollo. Swarm = QA/producción.

| Topología | Compose (desarrollo) | Swarm (QA/prod) |
|---|---|---|
| 1 nodo | `docker compose up -d --scale keycloak=1` | `replicas: 1` + deploy |
| 2 nodos | `docker compose up -d --scale keycloak=2` | `replicas: 2`, etiquetar 2 nodos |
| 3 nodos | `docker compose up -d --scale keycloak=3` | `replicas: 3`, etiquetar 3 nodos o usar archivo single-host |
| N nodos | `docker compose up -d --scale keycloak=N` | `replicas: N`, etiquetar N nodos |

---

## Configurar nginx al frente

La configuración de nginx es la misma para ambos modos. Solo difiere el target del upstream:
- **Compose**: `127.0.0.1:80` (Traefik en el host local).
- **Swarm**: una o más IPs de nodos Swarm en `:80` (malla de ingress).

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

## Monitoreo (opcional)

Grafana Alloy lee el socket Docker de cada host y envía los logs JSON de Keycloak a un Loki externo. Loki y Grafana **no** se despliegan aquí. Ambos modos comparten `monitoring/config.alloy`.

Ejemplo de consulta: `{system="keycloak", service="keycloak"} | json`

**Compose** — Alloy está integrado en `docker-compose.yml` detrás del profile `monitoring` (sin archivo aparte). Configurá `LOKI_REMOTE_URL` y `HOST_NAME` en `.env`, luego:

```bash
set -a; . ./.env; set +a
docker compose --profile monitoring up -d --scale keycloak=3
```

O poné `COMPOSE_PROFILES=monitoring` en `.env` y corré solo `docker compose up -d`.
`HOST_NAME` es requerido — compose no tiene template `{{.Node.Hostname}}`.

**Swarm:**

```bash
set -a; . ./.env; set +a
docker stack deploy -c monitoring/alloy-stack.yml keycloak-alloy
```

`HOST_NAME` se completa automáticamente via `{{.Node.Hostname}}`.

---

## Actualizaciones

Los cambios de versión recrean contenedores. Ver [`UPGRADE.es.md`](./UPGRADE.es.md) para el procedimiento completo.

**La actualización gradual sin downtime es una capacidad exclusiva de Swarm.** Compose reinicia los contenedores en el lugar (breve interrupción por réplica).

---

## Cheatsheet de operaciones

| Acción | Compose | Swarm |
|---|---|---|
| Seguir logs | `docker compose logs -f keycloak` | `docker service logs -f keycloak_keycloak` |
| Estado de contenedores | `docker compose ps` | `docker service ps keycloak_keycloak` |
| Escalar a N | `docker compose up -d --scale keycloak=N` | Editar `replicas: N` + `docker stack deploy` |
| Teardown | `docker compose down` | `docker stack rm keycloak` |
| Rollback | Re-desplegar con el tag anterior | `docker service rollback keycloak_keycloak` |

## Autor

<a href="https://github.com/villcabo"><img src="https://github.com/villcabo.png" width="80" alt="Bismarck Villca Soliz" align="left" style="margin-right: 16px; border-radius: 50%;" /></a>

**Bismarck Villca Soliz**

[![Website](https://img.shields.io/badge/Website-villcabo.github.io-222222?logo=githubpages&logoColor=white)](https://villcabo.github.io/)
[![GitHub](https://img.shields.io/badge/GitHub-villcabo-181717?logo=github)](https://github.com/villcabo)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-villcabo-0A66C2?logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGQ9Ik0yMC40NDcgMjAuNDUyaC0zLjU1NHYtNS41NjljMC0xLjMyOC0uMDI3LTMuMDM3LTEuODUyLTMuMDM3LTEuODUzIDAtMi4xMzYgMS40NDUtMi4xMzYgMi45Mzl2NS42NjdIOS4zNTFWOWgzLjQxNHYxLjU2MWguMDQ2Yy40NzctLjkgMS42MzctMS44NSAzLjM3LTEuODUgMy42MDEgMCA0LjI2NyAyLjM3IDQuMjY3IDUuNDU1djYuMjg2ek01LjMzNyA3LjQzM2MtMS4xNDQgMC0yLjA2My0uOTI2LTIuMDYzLTIuMDY1IDAtMS4xMzguOTItMi4wNjMgMi4wNjMtMi4wNjMgMS4xNCAwIDIuMDY0LjkyNSAyLjA2NCAyLjA2MyAwIDEuMTM5LS45MjUgMi4wNjUtMi4wNjQgMi4wNjV6bTEuNzgyIDEzLjAxOUgzLjU1NVY5aDMuNTY0djExLjQ1MnpNMjIuMjI1IDBIMS43NzFDLjc5MiAwIDAgLjc3NCAwIDEuNzI5djIwLjU0MkMwIDIzLjIyNy43OTIgMjQgMS43NzEgMjRoMjAuNDUxQzIzLjIgMjQgMjQgMjMuMjI3IDI0IDIyLjI3MVYxLjcyOUMyNCAuNzc0IDIzLjIgMCAyMi4yMjIgMGguMDAzeiIvPjwvc3ZnPg==)](https://www.linkedin.com/in/villcabo/)
[![Facebook](https://img.shields.io/badge/Facebook-bismarck.villca-1877F2?logo=facebook&logoColor=white)](https://www.facebook.com/bismarck.villca)
[![Email](https://img.shields.io/badge/Email-bismarck.villca%40gmail.com-D14836?logo=gmail&logoColor=white)](mailto:bismarck.villca@gmail.com)

<br clear="left" />

## Licencia

MIT.
