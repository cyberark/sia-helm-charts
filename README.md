# SIA K8s Connector — Helm Chart

This Helm chart deploys the **SIA Kubernetes Connector** into your cluster.  
It is the recommended path for teams that prefer managing Helm releases directly, without using the guided setup script.

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.24+ |
| [Helm](https://helm.sh/docs/intro/install/) | 3.10+ |
| [jq](https://jqlang.github.io/jq/) | 1.6+ |
| [curl](https://curl.se/) | any recent |

You must also have `kubectl` configured and pointing at the target cluster before running any of the commands below.

---

## Installation

### 1. Add the Helm repository

```bash
helm repo add sia https://raw.githubusercontent.com/cyberark/sia-helm-charts/main/
helm repo update
```

### 2. Create the namespace

```bash
kubectl create namespace sia-k8s-connector
```

### 3. Create the authentication secret

The connector reads its credentials from a Kubernetes secret named `sia-auth`.  
Create it before installing the chart:

```bash
kubectl create secret generic sia-auth \
  --from-literal=username="<SERVICE_ACCOUNT_USERNAME>" \
  --from-literal=password="<SERVICE_ACCOUNT_PASSWORD>" \
  --from-literal=idaptiveTenantId="<IDAPTIVE_TENANT_ID>" \
  --from-literal=tenantSubdomain="<TENANT_SUBDOMAIN>" \
  --namespace sia-k8s-connector
```

> **Note:** All four values are required. Obtain them from the SIA Admin Portal under your connector pool settings.

### 4. Create the image pull secret

If the connector image is hosted in a private registry, create a `docker-registry` secret so Kubernetes can pull it:

```bash
kubectl create secret docker-registry sia-registry-creds \
  --docker-server="<REGISTRY_SERVER>" \
  --docker-username="<REGISTRY_USERNAME>" \
  --docker-password="<REGISTRY_PASSWORD>" \
  --namespace sia-k8s-connector
```

For example:

```bash
kubectl create secret docker-registry sia-registry-creds \
  --docker-server="docker.io" \
  --docker-username="myuser" \
  --docker-password="mypassword" \
  --namespace sia-k8s-connector
```

> **Note:** Skip this step if the image repository is publicly accessible.

### 5. Install the chart

```bash
helm upgrade --install sia-connector sia/sia-k8s-connector \
  --namespace sia-k8s-connector \
  --version <CHART_VERSION> \
  --set connectorPoolId="<CONNECTOR_POOL_ID>" \
  --set replicaCount=1 \
  --set image.repository="docker.io/<IMAGE_REPOSITORY>" \
  --set image.tag="latest" \
  --set image.pullPolicy="Always" \
  --set imagePullSecrets[0].name="sia-registry-creds"
```

Replace every `<…>` placeholder with real values (see the table below).

#### Optional — behind a proxy

If your cluster nodes route outbound traffic through an HTTP/HTTPS proxy, pass it as an extra `--set`:

```bash
  --set proxy="https://proxy.example.com:8080"
```

---

## Configuration reference

| Parameter | Description | Required | Default |
|-----------|-------------|----------|---------|
| `connectorPoolId` | Connector Pool ID from the SIA Admin Portal | Yes | — |
| `replicaCount` | Number of connector pod replicas | No | `1` |
| `image.repository` | Docker image repository (e.g. `docker.io/cyberark/cms-k8s-connector`) | Yes | — |
| `image.tag` | Docker image tag — always use `latest` | No | `latest` |
| `image.pullPolicy` | Kubernetes image pull policy | No | `Always` |
| `imagePullSecrets[0].name` | Name of the `docker-registry` secret used to pull the image from a private registry | No | — |
| `proxy` | HTTP/HTTPS proxy URL for outbound connector traffic | No | `""` |
| `maintenanceRolloutTimeout` | Seconds the post-upgrade/post-rollback hook waits for the StatefulSet rollout to become healthy before disabling maintenance | No | `300` |

---

## Maintenance mode (upgrades & rollbacks)

> **Looking for a step-by-step operator walkthrough?**
> See the dedicated [Upgrade, Rollback & Uninstall guide](docs/upgrade-rollback-uninstall.md).

Each connector can host long-running sessions (up to 24 h). To avoid interrupting active sessions during an upgrade or rollback, place connectors into **maintenance mode** first: the SIA platform stops routing new sessions to them while existing sessions finish naturally.

The chart ships with a `helm sia-maintenance` plugin that calls the SIA API **directly from your local machine** — no Helm revision is created, so `helm history` stays clean and `helm rollback` always targets the correct previous chart version.

The chart also includes a `post-upgrade` / `post-rollback` hook that **automatically disables** maintenance mode once the new pods are verified healthy.

---

### Installing the `sia-maintenance` plugin

#### Prerequisites

The plugin runs locally and requires the following tools in your `PATH`:

| Tool | Purpose |
|------|---------|
| `kubectl` | Read the `sia-auth` Secret and connector ConfigMaps from the cluster |
| `curl` | Call the SIA REST API |
| `jq` | Parse JSON responses |
| `base64` | Decode Secret values |

#### Install from the chart repository

```bash
# Clone the chart repository (or use an existing local checkout)
git clone https://github.com/cyberark/sia-helm-charts.git
cd sia-helm-charts

# Install the plugin
helm plugin install ./plugins/sia-maintenance
```

#### Verify the installation

```bash
helm sia-maintenance --help
```

Expected output:

```
Usage: helm -n <namespace> sia-maintenance <enable|disable> [options]

Commands:
  enable   Put all connectors in the namespace into maintenance mode
  disable  Take all connectors out of maintenance mode
...
```

#### Uninstall the plugin

```bash
helm plugin uninstall sia-maintenance
```

---

### How the plugin works

When `enable` or `disable` is called, the plugin:

1. Reads `username`, `password`, `idaptiveTenantId`, and `tenantSubdomain` from the `sia-auth` Secret in the target namespace via `kubectl`.
2. Obtains an OAuth2 access token from the SIA identity endpoint.
3. Discovers all registered connectors by listing Kubernetes ConfigMaps whose name ends with `-connector-id` (written by each pod on first registration).
4. Calls `PUT /api/connectors/{id}/maintenance` for each connector.
5. Verifies the API response confirms the requested state; exits non-zero if any connector fails.

No Helm operation is performed. The plugin does not modify any Kubernetes resource.

> **Note:** Pass `-n <NAMESPACE>` to `helm` (before the plugin name), not to the subcommand.  
> Helm consumes the flag and exports it as `$HELM_NAMESPACE`, which the plugin reads.

```bash
helm -n <NAMESPACE> sia-maintenance enable    # correct
helm sia-maintenance enable -n <NAMESPACE>    # also works
```

---

### Safe upgrade (graceful — drain sessions first)

Use this flow when connectors have active sessions you do not want to interrupt.

```bash
# Step 1 — enable maintenance mode.
#   The SIA platform stops routing new sessions to the connectors.
#   Pods keep running; existing sessions continue until they finish.
helm -n <NAMESPACE> sia-maintenance enable

# Step 2 — wait for in-flight sessions to drain.
#   This can take anywhere from a few minutes up to 24 h depending on active sessions.
#   Monitor session counts in the SIA Admin Portal or connector logs.

# Step 3 — upgrade to the new chart version.
#   The post-upgrade hook waits for all pods to become healthy, then automatically
#   disables maintenance mode so new sessions can be routed again.
helm upgrade sia-connector ./sia-k8s-connector/sia-connector-<NEW_VERSION>.tgz \
  --namespace <NAMESPACE> \
  --reuse-values
```

If the post-upgrade hook fails (e.g. the rollout never becomes healthy), maintenance mode is left **enabled** intentionally — the connector will not accept new sessions on a broken deployment.

### Fast upgrade (no session draining)

Use this when there are no active long-running sessions, or in non-production environments.

```bash
helm upgrade sia-connector ./sia-k8s-connector/sia-connector-<NEW_VERSION>.tgz \
  --namespace <NAMESPACE> \
  --reuse-values
```

The post-upgrade hook still runs and disables maintenance mode after a healthy rollout (maintenance was never enabled, so this is a no-op on the API side).

---

### Safe rollback (graceful — drain sessions first)

Because `helm sia-maintenance enable` creates **no Helm revision**, `helm rollback` without a revision number always targets the correct immediately preceding chart version.

```bash
# Step 1 — enable maintenance mode.
#   The SIA platform stops routing new sessions to the connectors.
helm -n <NAMESPACE> sia-maintenance enable

# Step 2 — wait for in-flight sessions to drain (0–24 h).

# Step 3 — roll back to the previous chart version.
#   The post-rollback hook waits for all pods to become healthy, then automatically
#   disables maintenance mode.
helm rollback sia-connector -n <NAMESPACE>
```

To roll back to a specific revision (e.g. if there are multiple revisions in history):

```bash
helm history sia-connector -n <NAMESPACE>    # identify the target revision number
helm rollback sia-connector <REVISION> -n <NAMESPACE>
```

### Fast rollback (no session draining)

```bash
helm rollback sia-connector -n <NAMESPACE>
```

---

### Manual maintenance control

The plugin can also be used independently of any Helm operation — for example, to temporarily reduce load on connectors for maintenance windows unrelated to upgrades.

```bash
# Enable maintenance manually
helm -n <NAMESPACE> sia-maintenance enable

# ... perform maintenance work ...

# Disable maintenance manually when ready
helm -n <NAMESPACE> sia-maintenance disable
```

---

## Upgrading

To upgrade to a newer chart version without session draining (fast path):

```bash
helm upgrade sia-connector ./sia-k8s-connector/sia-connector-<NEW_VERSION>.tgz \
  --namespace <NAMESPACE> \
  --reuse-values
```

For a graceful upgrade that drains active sessions first, see the [Safe upgrade](#safe-upgrade-graceful--drain-sessions-first) flow above.

> **Tip:** Use `--reuse-values` to keep all previously set values.  
> Override individual values with additional `--set` flags as needed.

---

## Rolling back to the previous version

For a graceful rollback that drains active sessions first, see the [Safe rollback](#safe-rollback-graceful--drain-sessions-first) flow above.

For an immediate rollback:

```bash
helm rollback sia-connector -n <NAMESPACE>
```

> **Note:** Rollback is only supported to the immediately preceding Helm chart version. Rolling back further than one version is not supported.

---

---

## Uninstalling

```bash
helm uninstall sia-connector --namespace sia-k8s-connector
kubectl delete namespace sia-k8s-connector
```

> This also removes the `sia-auth` secret and all connector pods.

---

## Troubleshooting

**Check pod status**

```bash
kubectl get pods -n sia-k8s-connector
```

**View connector logs**

```bash
kubectl logs -n sia-k8s-connector -l app.kubernetes.io/instance=sia-connector --tail=100
```

**Describe a pod for events**

```bash
kubectl describe pod -n sia-k8s-connector <POD_NAME>
```
