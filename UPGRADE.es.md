> 🇬🇧 [English](./UPGRADE.md) · 🇪🇸 **Español**

# Actualizaciones de versión de Keycloak (Docker Swarm)

## TL;DR — ¿es una recarga en caliente?

**No.** Keycloak no tiene recarga en caliente de su versión. Un cambio de versión implica una
nueva imagen, lo que implica que los contenedores se recrean. Lo que permite una actualización
con **tiempo de inactividad casi nulo** es la **actualización gradual de Swarm**: las réplicas
se reemplazan de a una mientras las demás siguen sirviendo tráfico, todas compartiendo la
misma base de datos.

Esto funciona porque la topología está construida para ello (ver `keycloak-stack.yml` /
`keycloak-stack.single.yml`):

- **Healthcheck del contenedor** (`/health/ready` vía bash `/dev/tcp`) → Swarm solo
  considera "activo" a un nuevo nodo una vez que Keycloak está realmente LISTO, por lo que no
  drena el siguiente nodo antiguo demasiado pronto.
- **`update_config`**: `parallelism: 1` + `start-first` (host único) o
  `stop-first` (multi-host, 1 réplica/nodo) + `failure_action: pause`.
- **Traefik**: el healthcheck del balanceador de carga (3s) descarta rápidamente un nodo en
  drenado, y un middleware `retry` absorbe la única solicitud en vuelo que compite con un SIGTERM.

Sin el healthcheck del contenedor, la actualización produce **HTTP 503 durante ~20s**
(medido). Con él, el servicio permanece disponible.

## 1. Verificar compatibilidad de actualización gradual ANTES de actualizar

Keycloak solo garantiza que un clúster con versiones mixtas funciona si las dos versiones son
compatibles. Los cambios de parche (26.6.1 → 26.6.2) siempre son seguros. Los cambios de
minor/major deben verificarse — si son incompatibles, una actualización gradual **no** es
segura y se necesita una actualización con parada total (downtime).

```bash
# On a node running the CURRENT version, dump its metadata:
docker run --rm -v "$PWD:/out" --entrypoint /opt/keycloak/bin/kc.sh \
  quay.io/keycloak/keycloak:<CURRENT> \
  update-compatibility metadata --file=/out/compat.json

# Against the TARGET version, check it:
docker run --rm -v "$PWD:/out" --entrypoint /opt/keycloak/bin/kc.sh \
  quay.io/keycloak/keycloak:<TARGET> \
  update-compatibility check --file=/out/compat.json
# exit 0 → rolling update is safe.  non-zero → full-stop upgrade required.
```

> Nota: estos comandos necesitan la misma configuración de DB/features que usa el servidor
> para ser significativos; ejecútalos con tu `.env` exportado si tu metadata depende de él.

## 2. Respaldar la base de datos

La migración de esquema se ejecuta automáticamente en el primer nodo de la nueva versión y
**no es reversible**. Toma un snapshot de la base de datos primero (BD externa → usa el
mecanismo de backup de tu BD; este stack no lo gestiona).

## 3. Actualización gradual (versiones compatibles)

```bash
# 1. Bump the tag (.env for prod stacks, or the image line for local)
#    KEYCLOAK_IMAGE_VERSION=26.6.2

# 2. (optional) start the health monitor in another terminal — see §5

# 3. Re-deploy: Swarm performs the rolling update per update_config
set -a; . ./.env; set +a
docker stack deploy -c keycloak-stack.yml keycloak          # multi-host
# or
docker stack deploy -c keycloak-stack.single.yml keycloak   # single-host

# 4. Watch it roll
watch -n2 'docker service ps keycloak_keycloak --format "{{.Name}} {{.Image}} {{.CurrentState}}"'
docker service inspect keycloak_keycloak --format '{{.UpdateStatus.State}}'  # → completed
```

Cada nodo toma ~50–60s (augmentación de Quarkus + boot + unión al clúster). Con
`parallelism: 1` el rollout completo es aproximadamente `réplicas × 60s`.

## 4. Actualización con parada total (versiones incompatibles)

Si el §1 reporta incompatibilidad, NO confíes en la actualización gradual. Acepta una ventana
de mantenimiento:

```bash
docker service scale keycloak_keycloak=0     # stop all nodes
# bump the tag, then:
docker stack deploy -c keycloak-stack.yml keycloak
docker service scale keycloak_keycloak=3
```

## 5. Verificar que no hubo interrupción durante el rollout

Golpea el endpoint del cliente a través de Traefik y cuenta las respuestas no-200:

```bash
total=0; fail=0
while true; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -m 3 https://<KEYCLOAK_HOSTNAME>/realms/master)
  total=$((total+1)); [ "$c" != 200 ] && { fail=$((fail+1)); echo "$(date +%T) $c"; }
  echo "total=$total fail=$fail"; sleep 0.25
done
```

`/realms/master` es un endpoint real respaldado por la BD que devuelve 200, por lo que es una
sonda más estricta que `/health`. Unos pocos reintentos transitorios durante el drenado de un
nodo son esperables; una secuencia sostenida de 503 indica que hubo una interrupción —
revisa la configuración del healthcheck.

## 6. Rollback

```bash
docker service rollback keycloak_keycloak
```
Revierte la imagen/configuración al spec anterior. ⚠️ Esto **no** revierte las migraciones de
esquema de la base de datos — si la nueva versión migró el esquema, restaura el backup de la
base de datos del §2.

## Resultados medidos (este repo, host único, 26.2 → 26.6.2)

| Configuración | Respuestas no-200 durante el rollout |
|---|---|
| `start-first`, **sin** healthcheck de contenedor | 75 / 1875 — incluye ~22s de 503 sostenidos (interrupción) |
| `start-first` + healthcheck de contenedor + retry | 2 / 610 — solo transitorios, sin interrupción |
