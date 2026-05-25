# Keycloak version upgrades (Docker Swarm)

> 🇬🇧 **English** · 🇪🇸 [Español](./UPGRADE.es.md)

## TL;DR — is it a hot reload?

**No.** Keycloak has no in-place hot reload of its version. A version bump means a
new image, which means containers are recreated. What gives you a **near
zero-downtime** upgrade is the **Swarm rolling update**: replicas are replaced one
at a time while the others keep serving, all sharing the same database.

This works because the topology is built for it (see `keycloak-stack.yml` /
`keycloak-stack.single.yml`):

- **Container healthcheck** (`/health/ready` via bash `/dev/tcp`) → Swarm only
  considers a new node "up" once Keycloak is actually READY, so it won't drain the
  next old node too early.
- **`update_config`**: `parallelism: 1` + `start-first` (single-host) or
  `stop-first` (multi-host, 1 replica/node) + `failure_action: pause`.
- **Traefik**: loadbalancer healthcheck (3s) drops a draining node fast, and a
  `retry` middleware absorbs the single in-flight request that races a SIGTERM.

Without the container healthcheck the upgrade drops to **HTTP 503 for ~20s**
(measured). With it, the service stays up.

## 1. Check rolling-update compatibility BEFORE upgrading

Keycloak only guarantees a mixed-version cluster works if the two versions are
compatible. Patch bumps (26.6.1 → 26.6.2) are always fine. Minor/major bumps must
be checked — if incompatible, a rolling upgrade is **not** safe and you need a
full-stop upgrade (downtime).

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

> Note: these commands need the same DB/feature config the server runs with to be
> meaningful; run them with your `.env` exported if your metadata depends on it.

## 2. Back up the database

Schema migration runs automatically on the first node of the new version and is
**not reversible**. Snapshot the DB first (external DB → use your DB's backup;
this stack does not manage it).

## 3. Rolling upgrade (compatible versions)

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

Each node takes ~50–60s (Quarkus augmentation + boot + cluster join). With
`parallelism: 1` the whole rollout is roughly `replicas × 60s`.

## 4. Full-stop upgrade (incompatible versions)

If §1 reports incompatible, do NOT rely on rolling. Accept a maintenance window:

```bash
docker service scale keycloak_keycloak=0     # stop all nodes
# bump the tag, then:
docker stack deploy -c keycloak-stack.yml keycloak
docker service scale keycloak_keycloak=3
```

## 5. Verify no outage during the rollout

Hammer the client-facing endpoint through Traefik and count non-200s:

```bash
total=0; fail=0
while true; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -m 3 https://<KEYCLOAK_HOSTNAME>/realms/master)
  total=$((total+1)); [ "$c" != 200 ] && { fail=$((fail+1)); echo "$(date +%T) $c"; }
  echo "total=$total fail=$fail"; sleep 0.25
done
```

`/realms/master` is a real, DB-backed 200 endpoint, so it's a stricter probe than
`/health`. A handful of transient retries during node drain is expected; a
sustained run of 503s means there was an outage — re-check the healthcheck config.

## 6. Rollback

```bash
docker service rollback keycloak_keycloak
```
Rolls back the image/config to the previous spec. ⚠️ It does **not** roll back DB
schema migrations — if the new version migrated the schema, restore the DB backup
from §2 instead.

## Measured results (this repo, single-host, 26.2 → 26.6.2)

| Setup | Non-200 during rollout |
|---|---|
| `start-first`, **no** container healthcheck | 75 / 1875 — incl. ~22s of sustained 503 (outage) |
| `start-first` + container healthcheck + retry | 2 / 610 — transient only, no outage |
