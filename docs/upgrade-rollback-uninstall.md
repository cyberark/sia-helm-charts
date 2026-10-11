# SIA Kubernetes Connector — Upgrade, Rollback & Uninstall Guide

This guide walks operators through the day-2 lifecycle of the SIA Kubernetes
Connector Helm release: **upgrading** to a new chart version, **rolling back**
to the previous one, and **uninstalling** the release cleanly.

All three operations can interrupt long-running SIA sessions. This guide
explains how to use the shipped `helm sia-maintenance` plugin together with
the chart's built-in `pre-delete` hook so that active sessions drain
gracefully instead of being cut mid-flight.

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

### The pre-delete hook

`helm uninstall` triggers a `pre-delete` Job
(`templates/pre-delete-cleanup.yaml`) which:

1. Deregisters **every** connector discovered from `<statefulset>-<n>-connector-id`
   ConfigMaps in the namespace — including replicas that were scaled down before
   uninstall (`DELETE /api/connectors/{id}?force_delete=true`), so stale
   connector entries do not linger in the SIA Admin Portal.
2. Deletes **all** matching `connector-data-<statefulset>-<n>` PVCs (not only
   the current replica count).

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
helm repo add sia https://raw.githubusercontent.com/cyberark/sia-helm-charts/main/sia-k8s-connector
helm repo update sia
helm search repo sia/sia-connector --versions   # pick the version to upgrade to
export NEW_VERSION=<CHART_VERSION>

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
helm repo update sia
helm upgrade sia-connector sia/sia-connector \
  --version "${NEW_VERSION}" \
  --namespace "${NAMESPACE}" \
  --reuse-values

# ── Step 4 — verify rollout health, then disable maintenance mode ────────
kubectl rollout status statefulset/sia-connector -n "${NAMESPACE}"
helm -n "${NAMESPACE}" sia-maintenance disable
```

Verify the outcome:

```bash
helm history sia-connector    -n "${NAMESPACE}"
kubectl get pods              -n "${NAMESPACE}"
```

### 4.2 Fast upgrade (no session draining)

Use in non-production environments, or when no long-running sessions are
active.

```bash
helm repo add sia https://raw.githubusercontent.com/cyberark/sia-helm-charts/main/sia-k8s-connector
helm repo update sia
helm search repo sia/sia-connector --versions   # pick the version to upgrade to
export NEW_VERSION=<CHART_VERSION>

helm upgrade sia-connector sia/sia-connector \
  --version "${NEW_VERSION}" \
  --namespace "${NAMESPACE}" \
  --reuse-values
```

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
helm rollback sia-connector -n "${NAMESPACE}"

# ── Step 4 — verify rollout health, then disable maintenance mode ────────
kubectl rollout status statefulset/sia-connector -n "${NAMESPACE}"
helm -n "${NAMESPACE}" sia-maintenance disable
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
2. Lists every ConfigMap named `<statefulset>-<n>-connector-id` in the
   namespace and reads each `connector_id`.
3. Calls `DELETE /api/connectors/{id}?force_delete=true` for each discovered
   connector, including those from scaled-down replicas.
4. Deletes all `connector-data-<statefulset>-<n>` PVCs for this release.

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

### Maintenance mode is still enabled after upgrade or rollback

If you used the safe upgrade or rollback flow, maintenance mode stays enabled
until you disable it manually:

```bash
kubectl rollout status statefulset/sia-connector -n "${NAMESPACE}"
helm -n "${NAMESPACE}" sia-maintenance disable
```

If the rollout is not healthy, fix the underlying pod issue before disabling
maintenance — otherwise new sessions may be routed to a broken deployment.

```bash
kubectl get pods                   -n "${NAMESPACE}"
kubectl describe pod <POD_NAME>    -n "${NAMESPACE}"
kubectl logs -n "${NAMESPACE}" -l app.kubernetes.io/instance=sia-connector --tail=200
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

Chart **1.0.25+** deletes all `connector-data-<statefulset>-<n>` PVCs discovered
in the namespace, including those from scaled-down replicas. On older chart
versions, only PVCs up to the current replica count were removed. If cleanup
still fails or you are on an older chart, delete manually:

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
gracefully, then rolling back after a regression is detected. The version
numbers are illustrative — use one listed by
`helm search repo sia/sia-connector --versions`:

```bash
export NAMESPACE=sia-k8s-connector
export NEW_VERSION=1.0.24
helm repo add sia https://raw.githubusercontent.com/cyberark/sia-helm-charts/main/sia-k8s-connector

# 1. Enable maintenance and drain sessions
helm -n "${NAMESPACE}" sia-maintenance enable
# ... wait for session count to reach 0 ...

# 2. Upgrade
helm repo update sia
helm upgrade sia-connector sia/sia-connector \
  --version "${NEW_VERSION}" \
  --namespace "${NAMESPACE}" \
  --reuse-values

# 3. Verify rollout and disable maintenance
kubectl rollout status statefulset/sia-connector -n "${NAMESPACE}"
helm -n "${NAMESPACE}" sia-maintenance disable

# 4. Confirm release state
helm history sia-connector -n "${NAMESPACE}"
kubectl get pods           -n "${NAMESPACE}"

# ---- regression discovered ----

# 5. Enable maintenance again and drain
helm -n "${NAMESPACE}" sia-maintenance enable
# ... wait ...

# 6. Roll back to the previous revision (1.0.19)
helm rollback sia-connector -n "${NAMESPACE}"

# 7. Verify rollout and disable maintenance
kubectl rollout status statefulset/sia-connector -n "${NAMESPACE}"
helm -n "${NAMESPACE}" sia-maintenance disable

# 8. Confirm
helm history sia-connector -n "${NAMESPACE}"
```
