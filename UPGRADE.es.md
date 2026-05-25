# Actualizaciones de versión de Keycloak

> 🇬🇧 [English](./UPGRADE.md) · 🇪🇸 **Español**

Un cambio de versión no es una recarga en caliente — los contenedores se recrean.

**Respaldar primero.** La migración de esquema se ejecuta automáticamente en el primer nodo de la nueva versión y **no es reversible**. Toma un snapshot de la base de datos externa antes de actualizar.

**Compatibilidad.** Los cambios de parche (26.6.1 → 26.6.2) siempre son seguros. Para cambios de minor o major, ejecutar la verificación de compatibilidad:

```bash
docker run --rm -v "$PWD:/out" --entrypoint /opt/keycloak/bin/kc.sh \
  quay.io/keycloak/keycloak:<ACTUAL> \
  update-compatibility metadata --file=/out/compat.json

docker run --rm -v "$PWD:/out" --entrypoint /opt/keycloak/bin/kc.sh \
  quay.io/keycloak/keycloak:<OBJETIVO> \
  update-compatibility check --file=/out/compat.json
# exit 0 → seguro.  non-zero → se requiere parada total (planificar ventana de mantenimiento).
```

---

## Actualización — Docker Compose

Breve interrupción por réplica. **La actualización gradual sin downtime es una capacidad exclusiva de Swarm.**

```bash
# 1. Cambiar KEYCLOAK_IMAGE_VERSION en .env
set -a; . ./.env; set +a
docker compose pull keycloak
docker compose up -d --scale keycloak=<N>
docker compose ps   # esperar a (healthy)
```

---

## Actualización — Docker Swarm

Actualización gradual — sin downtime. Swarm reemplaza las réplicas de a una, controlado por el healthcheck del contenedor.

```bash
# 1. Cambiar KEYCLOAK_IMAGE_VERSION en .env
set -a; . ./.env; set +a
docker stack deploy -c keycloak-stack.yml keycloak          # multi-host
# o
docker stack deploy -c keycloak-stack.single.yml keycloak   # host único

# Observar el rollout
watch -n2 'docker service ps keycloak_keycloak --format "{{.Name}} {{.Image}} {{.CurrentState}}"'
```

Rollback si es necesario:

```bash
docker service rollback keycloak_keycloak
# Nota: NO revierte las migraciones de esquema — restaurar el backup de la BD.
```
