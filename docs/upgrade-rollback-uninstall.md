# SIA Kubernetes Connector — Upgrade, Rollback & Uninstall Guide

This guide walks operators through the day-2 lifecycle of the SIA Kubernetes
Connector Helm release: **upgrading** to a new chart version, **rolling back**
to the previous one, and **uninstalling** the release cleanly.

All three operations can interrupt long-running SIA sessions. This guide
explains how to use the shipped `helm sia-maintenance` plugin together with
the chart's built-in `post-upgrade` / `post-rollback` / `pre-delete` hooks so
that active sessions drain gracefully instead of being cut mid-flight.

> If you have not yet installed the connector, see the top-level
> [README](../README.md) for the initial install flow. This guide assumes a
> working release named `sia-connector` in namespace `<NAMESPACE>`.

---

## Table of contents

1. [Concepts you need to know](#1-concepts-you-need-to-know)
2. [Prerequisites](#2-prerequisites)
3. [Install the `sia-maintenance` plugin](#3-install-the-sia-maintenance-plugin)
4. [Upgrade the connector](#4-upgrade-the-connector)
   - [Safe upgrade (drain sessions first)](#41-safe-upgrade-drain-sessions-first)
   - [Fast upgrade (no session draining)](#42-fast-upgrade-no-session-draining)
5. [Rollback the connector](#5-rollback-the-connector)
   - [Safe rollback (drain sessions first)](#51-safe-rollback-drain-sessions-first)
   - [Fast rollback (no session draining)](#52-fast-rollback-no-session-draining)
   - [Picking a specific revision](#53-picking-a-specific-revision)
6. [Uninstall the connector](#6-uninstall-the-connector)
7. [Manual maintenance control](#7-manual-maintenance-control)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Concepts you need to know

### Maintenance mode

Each connector replica registers itself with the SIA control plane on start-up
and can be toggled into **maintenance mode** via the SIA REST API. While in
maintenance mode:

- The SIA platform **stops routing new sessions** to that connector.
- The pod keeps running and **existing sessions finish naturally** (a session
  can last up to 24 hours).

Maintenance mode is the mechanism that turns a disruptive rolling restart into
a graceful upgrade/rollback.

### The `sia-maintenance` Helm plugin

The plugin ships in this repo under `plugins/sia-maintenance/`. It runs
locally on your workstation and calls the SIA REST API directly:

- Reads `username`, `password`, `idaptiveTenantId`, `tenantSubdomain`
  (and optional `devApiEndpoint`) from the `sia-auth` Secret in the target
  namespace via `kubectl`.
- Obtains an OAuth2 access token from the SIA identity endpoint.
- Discovers all registered connectors by listing ConfigMaps whose name ends
  with `-connector-id` (each pod writes one on first registration).
- Calls `PUT /api/connectors/{id}/maintenance` on every discovered connector
  with `{"maintenance": true}` (`enable`) or `{"maintenance": false}`
  (`disable`).

> **Key property:** the plugin performs **no Helm operation**. It creates no
> Helm revision and modifies no Kubernetes resource in the release. This
> matters because `helm rollback` without a revision number always targets
> the immediately preceding chart version — a stray Helm revision from
> "toggle maintenance" would silently make `helm rollback` point at the wrong
> release.

### The automatic post-hook

The chart includes a `post-upgrade` / `post-rollback` Job
(`templates/maintenance-hook.yaml`) that runs after every `helm upgrade` and
`helm rollback`. It:

1. Waits up to `maintenanceRolloutTimeout` seconds (default: `300`) for the
   StatefulSet rollout to become fully healthy
   (`readyReplicas == replicas` **and** `currentRevision == updateRevision`).
2. If the rollout is healthy, calls the SIA API to **disable maintenance
   mode** on every connector so new sessions start flowing again.
3. If the rollout **never becomes healthy**, the Job exits non-zero and
   **leaves maintenance mode enabled**. This is intentional — a broken
   deployment must not silently start accepting new sessions.

Because the hook always tries to disable maintenance on success, both the
"safe" and the "fast" flows use the exact same `helm upgrade` / `helm
rollback` commands. The only difference is whether you enable maintenance
first.

### The pre-delete hook

`helm uninstall` triggers a `pre-delete` Job
(`templates/pre-delete-cleanup.yaml`) which:

1. Deregisters each connector from the SIA control plane
   (`DELETE /api/connectors/{id}?force_delete=true`), so stale connector
   entries do not linger in the SIA Admin Portal.
2. Deletes the `PersistentVolumeClaims` created by the StatefulSet's
   `volumeClaimTemplates` (Helm does not delete PVCs by default).

Both steps are best-effort: failures are logged as warnings but do not block
uninstall.

---

## 2. Prerequisites

| Requirement | Notes |
|-------------|-------|
| `kubectl` 1.24+ | Configured for the target cluster and namespace |
| `helm` 3.10+ | Used for install, upgrade, rollback, uninstall |
| `curl` | Used by the plugin to call the SIA API from your workstation |
| `jq` 1.6+ | Used by the plugin to parse API responses |
| `base64` | Used by the plugin to decode Secret values |
| Cluster access | Read Secrets and ConfigMaps in the connector namespace |
| Network egress | Your workstation must reach the SIA tenant endpoints |
| A working release | `helm status sia-connector -n <NAMESPACE>` returns `deployed` |
| `sia-auth` Secret | Present in the namespace with `username`, `password`, `idaptiveTenantId`, `tenantSubdomain` keys |

Verify the release and secret exist:

```bash
export NAMESPACE=sia-k8s-connector

helm status sia-connector -n "${NAMESPACE}"
kubectl get secret sia-auth   -n "${NAMESPACE}"
```

---

## 3. Install the `sia-maintenance` plugin

Clone (or `git pull`) this chart repository to your workstation and install
the plugin from the local path:

```bash
git clone https://github.com/cyberark/sia-helm-charts.git
cd sia-helm-charts

helm plugin install ./plugins/sia-maintenance
```

Verify:

```bash
helm sia-maintenance --help
```

Expected output starts with:

```
Usage: helm -n <namespace> sia-maintenance <enable|disable> [options]

Commands:
  enable   Put all connectors in the namespace into maintenance mode
  disable  Take all connectors out of maintenance mode
...
```

> **Note:** Pass `-n <NAMESPACE>` **to `helm`, before the plugin name**. Helm
> consumes the flag and exports it as `$HELM_NAMESPACE`, which the plugin
> reads.
>
> ```bash
> helm -n <NAMESPACE> sia-maintenance enable    # recommended
> helm sia-maintenance enable -n <NAMESPACE>    # also works
> ```

To uninstall the plugin later:

```bash
helm plugin uninstall sia-maintenance
```

---

## 4. Upgrade the connector

### 4.1 Safe upgrade (drain sessions first)

Use this flow in production, or whenever connectors may be hosting active
long-running sessions you do not want to interrupt.

```bash
export NAMESPACE=sia-k8s-connector
export NEW_VERSION=1.0.24   # chart version you are upgrading to

# ── Step 1 — enable maintenance mode ─────────────────────────────────────
# The SIA platform stops routing new sessions to the connectors.
# Pods keep running so existing sessions continue.
# No Helm revision is created.
helm -n "${NAMESPACE}" sia-maintenance enable

# ── Step 2 — wait for in-flight sessions to drain ────────────────────────
# This can take anywhere from a few minutes up to 24 h depending on active
# sessions. Watch session counts in the SIA Admin Portal, or:
kubectl logs -n "${NAMESPACE}" -l app.kubernetes.io/instance=sia-connector \
  --tail=100 -f

# ── Step 3 — upgrade to the new chart version ────────────────────────────
# The post-upgrade hook waits for a healthy rollout, then automatically
# disables maintenance mode so new sessions start flowing again.
helm upgrade sia-connector \
  ./sia-k8s-connector/sia-connector-${NEW_VERSION}.tgz \
  --namespace "${NAMESPACE}" \
  --reuse-values
```

Verify the outcome:

```bash
helm history sia-connector    -n "${NAMESPACE}"
kubectl get pods              -n "${NAMESPACE}"
kubectl get jobs              -n "${NAMESPACE}"       # hook Jobs are cleaned up on success
```

> **What if the hook fails?** Maintenance mode is left **enabled** on
> purpose. See [Troubleshooting](#8-troubleshooting).

### 4.2 Fast upgrade (no session draining)

Use in non-production environments, or when no long-running sessions are
active.

```bash
helm upgrade sia-connector \
  ./sia-k8s-connector/sia-connector-${NEW_VERSION}.tgz \
  --namespace "${NAMESPACE}" \
  --reuse-values
```

The `post-upgrade` hook still runs. Because maintenance was never enabled,
disabling it is a no-op on the API side, but the healthy-rollout wait still
provides a useful sanity check.

> **Tip:** `--reuse-values` keeps every previously set value from the
> current release. Override individual values with extra `--set` flags as
> needed.

---

## 5. Rollback the connector

> **Supported scope:** Rollback is only supported to the **immediately
> preceding** chart version. Rolling back further than one version back is
> not tested and not supported.

Because `helm sia-maintenance enable` creates **no** Helm revision, a plain
`helm rollback sia-connector` always targets the correct previous release —
there is no need to compute revision numbers manually.

### 5.1 Safe rollback (drain sessions first)

```bash
export NAMESPACE=sia-k8s-connector

# ── Step 1 — enable maintenance mode ─────────────────────────────────────
helm -n "${NAMESPACE}" sia-maintenance enable

# ── Step 2 — wait for in-flight sessions to drain (0–24 h) ───────────────

# ── Step 3 — roll back to the previous chart version ─────────────────────
# The post-rollback hook waits for a healthy rollout, then automatically
# disables maintenance mode.
helm rollback sia-connector -n "${NAMESPACE}"
```

### 5.2 Fast rollback (no session draining)

```bash
helm rollback sia-connector -n "${NAMESPACE}"
```

### 5.3 Picking a specific revision

Inspect the release history to see which revision you want to roll back to
(useful when several upgrades have been applied):

```bash
helm history sia-connector -n "${NAMESPACE}"
```

Example output:

```
REVISION  UPDATED                   STATUS      CHART                  APP VERSION  DESCRIPTION
1         2026-08-01 10:00:00 UTC   superseded  sia-connector-1.0.16   latest       Install complete
2         2026-08-15 14:22:00 UTC   superseded  sia-connector-1.0.19   latest       Upgrade complete
3         2026-08-20 09:11:00 UTC   deployed    sia-connector-1.0.24   latest       Upgrade complete
```

Roll back to a specific revision:

```bash
helm rollback sia-connector <REVISION> -n "${NAMESPACE}"
```

For example, to return to `sia-connector-1.0.19`:

```bash
helm rollback sia-connector 2 -n "${NAMESPACE}"
```

The same `post-rollback` hook logic (wait for healthy rollout, then disable
maintenance) applies.

---

## 6. Uninstall the connector

Uninstall removes every Kubernetes resource created by the chart, including
pods, Services, ServiceAccount/Role/RoleBinding, StorageClass (only if the
chart created it), and — via the `pre-delete` hook — the connector's PVCs
and its SIA control-plane registration.

The `sia-auth` Secret and the image-pull Secret are **not** deleted by the
chart, because they were created outside the chart. Delete them manually if
you no longer need them.

```bash
export NAMESPACE=sia-k8s-connector

# Optional — drain sessions gracefully before uninstalling
helm -n "${NAMESPACE}" sia-maintenance enable
# ... wait for in-flight sessions to finish ...

# Uninstall. --wait blocks until the pre-delete hook completes.
helm uninstall sia-connector --namespace "${NAMESPACE}" --wait
```

What the `pre-delete` hook does behind the scenes:

1. Obtains an OAuth2 token from the SIA identity endpoint.
2. Reads each replica's connector ID from the
   `<pod>-connector-id` ConfigMap.
3. Calls `DELETE /api/connectors/{id}?force_delete=true` for each
   connector, removing it from the SIA Admin Portal.
4. Deletes the `connector-data-<statefulset>-<n>` PVCs created by the
   StatefulSet.

All steps are best-effort and log warnings on failure — they will not block
the uninstall.

Verify:

```bash
helm status sia-connector          -n "${NAMESPACE}"    # should return "release: not found"
kubectl get all,pvc,cm             -n "${NAMESPACE}"    # no chart resources left
```

Clean up the namespace and secrets if you are done:

```bash
kubectl delete secret sia-auth           -n "${NAMESPACE}" --ignore-not-found
kubectl delete secret sia-registry-creds -n "${NAMESPACE}" --ignore-not-found
kubectl delete namespace "${NAMESPACE}"
```

---

## 7. Manual maintenance control

The plugin is also useful independently of upgrades or rollbacks — for
example, to divert traffic away from connectors during an unrelated
maintenance window (network work, node draining, etc.).

```bash
# Divert traffic away from the connectors
helm -n "${NAMESPACE}" sia-maintenance enable

# ... perform your maintenance work ...

# Bring the connectors back into rotation
helm -n "${NAMESPACE}" sia-maintenance disable
```

Useful flags:

| Flag | Description | Default |
|------|-------------|---------|
| `--secret <name>` | Name of the `sia-auth` Secret to read credentials from | `sia-auth` |
| `--root-domain <domain>` | SIA root domain used to build the API URLs | `cyberark.cloud` |
| `-v`, `--verbose` | Extra debug output | off |

The `ROOT_DOMAIN` environment variable is an alternative to `--root-domain`.

---

## 8. Troubleshooting

### The post-upgrade / post-rollback hook failed and maintenance mode is stuck ON

This is by design: if the StatefulSet rollout never becomes healthy within
`maintenanceRolloutTimeout` seconds (default `300`), the hook exits non-zero
and leaves maintenance **enabled** so the broken deployment does not accept
new sessions.

Inspect what went wrong:

```bash
kubectl get pods                   -n "${NAMESPACE}"
kubectl describe pod <POD_NAME>    -n "${NAMESPACE}"
kubectl logs -n "${NAMESPACE}" -l app.kubernetes.io/instance=sia-connector --tail=200

# The hook itself runs as a Job; if it still exists check its logs:
kubectl get jobs                                        -n "${NAMESPACE}"
kubectl logs job/sia-connector-maintenance-disable      -n "${NAMESPACE}"
```

Once you have fixed the underlying issue and the pods are `Ready` again, you
have two options:

- **Preferred:** re-run the same `helm upgrade` (or `helm rollback`)
  command. The post-hook will run again, see a healthy rollout, and
  automatically disable maintenance.
- **Manual:** disable maintenance directly with the plugin:

  ```bash
  helm -n "${NAMESPACE}" sia-maintenance disable
  ```

### `No registered connectors found in namespace ...`

The plugin discovers connectors from ConfigMaps named `<pod>-connector-id`,
which each pod writes on first successful registration. If no such
ConfigMaps exist, either:

- the pods have not finished starting yet (`kubectl get pods -n "${NAMESPACE}"`),
- or registration itself is failing (check pod logs).

Wait for the pods to become `Ready` and register, then retry.

### `Secret 'sia-auth' not found or missing '...' key`

The plugin needs `username`, `password`, `idaptiveTenantId`, and
`tenantSubdomain` in the `sia-auth` Secret. Recreate it if any key is
missing:

```bash
kubectl -n "${NAMESPACE}" get secret sia-auth -o jsonpath='{.data}' | \
  jq 'keys'
```

If the Secret name is not the default, pass `--secret <name>`.

### `curl error ...` from the plugin

Your workstation must be able to reach the SIA identity and DPA endpoints:

- `https://<IDAPTIVE_TENANT_ID>.id.<ROOT_DOMAIN>` (OAuth2 token)
- `https://<TENANT_SUBDOMAIN>.dpa.<ROOT_DOMAIN>` (connector API)

Verify DNS and outbound connectivity, and check any corporate proxy
settings. If your SIA instance uses a non-default root domain, pass
`--root-domain <domain>` or set the `ROOT_DOMAIN` environment variable.

### `helm rollback` targets the wrong version

Confirm you did not accidentally introduce Helm revisions between upgrades.
Only `helm upgrade` (and `helm install`) should create revisions in the
history — `helm sia-maintenance enable`/`disable` must not:

```bash
helm history sia-connector -n "${NAMESPACE}"
```

If unexpected revisions exist, use `helm rollback sia-connector <REVISION>`
with the explicit revision number instead of the plain form.

### PVCs are left behind after `helm uninstall`

The `pre-delete` hook deletes PVCs on a best-effort basis. If it timed out
or the cluster refused the delete, clean them up manually:

```bash
kubectl get pvc                                   -n "${NAMESPACE}"
kubectl delete pvc -l app.kubernetes.io/instance=sia-connector \
                                                  -n "${NAMESPACE}"
```

### The connector still shows up in the SIA Admin Portal after uninstall

The deregistration step in the `pre-delete` hook is best-effort. If it
failed (for example because the workstation running `helm uninstall` had no
egress to the SIA control plane), remove the stale connector entries
manually from the SIA Admin Portal → **Connector Pools → \<your pool\> →
Connectors**.

---

## Appendix — end-to-end example

Complete session upgrading `sia-connector` from `1.0.19` to `1.0.24`
gracefully, then rolling back after a regression is detected:

```bash
export NAMESPACE=sia-k8s-connector

# 1. Enable maintenance and drain sessions
helm -n "${NAMESPACE}" sia-maintenance enable
# ... wait for session count to reach 0 ...

# 2. Upgrade
helm upgrade sia-connector \
  ./sia-k8s-connector/sia-connector-1.0.24.tgz \
  --namespace "${NAMESPACE}" \
  --reuse-values

# 3. Verify
helm history sia-connector -n "${NAMESPACE}"
kubectl get pods           -n "${NAMESPACE}"

# ---- regression discovered ----

# 4. Enable maintenance again and drain
helm -n "${NAMESPACE}" sia-maintenance enable
# ... wait ...

# 5. Roll back to the previous revision (1.0.19)
helm rollback sia-connector -n "${NAMESPACE}"

# 6. Confirm
helm history sia-connector -n "${NAMESPACE}"
```
