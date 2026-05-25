# Keycloak version upgrades

> 🇬🇧 **English** · 🇪🇸 [Español](./UPGRADE.es.md)

A version bump is not a hot reload — containers are recreated.

**Backup first.** Schema migration runs automatically on the first node of the new version and is **not reversible**. Snapshot the external DB before upgrading.

**Compatibility.** Patch bumps (26.6.1 → 26.6.2) are always safe. For minor or major bumps, run the compatibility check:

```bash
docker run --rm -v "$PWD:/out" --entrypoint /opt/keycloak/bin/kc.sh \
  quay.io/keycloak/keycloak:<CURRENT> \
  update-compatibility metadata --file=/out/compat.json

docker run --rm -v "$PWD:/out" --entrypoint /opt/keycloak/bin/kc.sh \
  quay.io/keycloak/keycloak:<TARGET> \
  update-compatibility check --file=/out/compat.json
# exit 0 → safe.  non-zero → full-stop upgrade required (plan a maintenance window).
```

---

## Upgrade — Docker Compose

Brief downtime per replica. **Zero-downtime rolling upgrade is a Swarm-only capability.**

```bash
# 1. Bump KEYCLOAK_IMAGE_VERSION in .env
set -a; . ./.env; set +a
docker compose pull keycloak
docker compose up -d --scale keycloak=<N>
docker compose ps   # wait for (healthy)
```

---

## Upgrade — Docker Swarm

Rolling update — zero downtime. Swarm replaces replicas one at a time, gated by the container healthcheck.

```bash
# 1. Bump KEYCLOAK_IMAGE_VERSION in .env
set -a; . ./.env; set +a
docker stack deploy -c keycloak-stack.yml keycloak          # multi-host
# or
docker stack deploy -c keycloak-stack.single.yml keycloak   # single-host

# Watch the rollout
watch -n2 'docker service ps keycloak_keycloak --format "{{.Name}} {{.Image}} {{.CurrentState}}"'
```

Rollback if needed:

```bash
docker service rollback keycloak_keycloak
# Note: does NOT roll back DB schema migrations — restore the DB backup instead.
```
