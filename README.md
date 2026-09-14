# SIA K8s Connector — Helm Chart

This Helm chart deploys the **SIA Kubernetes Connector** into your cluster.  
It is the recommended path for teams that prefer managing Helm releases directly.

---

## Prerequisites

| Tool | Minimum version | Needed for |
|------|----------------|------------|
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.24+ | Talking to your cluster |
| [Helm](https://helm.sh/docs/intro/install/) | 3.10+ | Installing the chart |
| [Docker](https://docs.docker.com/engine/install/) | any current, daemon running | Building the connector image |
| [curl](https://curl.se/) | any recent | The prerequisite checks and the maintenance plugin |
| [jq](https://jqlang.github.io/jq/) | 1.6+ | The `sia-maintenance` plugin only |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2 | Only if your registry is Amazon ECR |
| [gcloud CLI](https://cloud.google.com/sdk/docs/install) | any current | Only if your registry is Google Artifact / Container Registry |
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | any current | Only if your registry is Azure Container Registry |

You need only the cloud CLI for the prerequisite script you run — see [Verify all of this automatically](#verify-all-of-this-automatically) below.

You also need:

- `kubectl` configured and pointing at the target cluster before running any of the commands below.
- Permission on that cluster to create a namespace, a secret, a StatefulSet, and a **ClusterRole** — the chart grants the connector read access to node labels, which is cluster-scoped.
- A container registry you can push to. The image is built locally rather than pulled from CyberArk, because your environment's domain is compiled into it.
- From the SIA Admin Portal: your Connector Pool ID, Identity tenant ID, tenant subdomain, and a service account with permission to register connectors.

### Verify all of this automatically

`sia-connector-prerequisites.sh` checks every item above, plus the two things you cannot check from your own machine at all: whether your **cluster nodes** can reach your SIA environment, and whether the cluster has a StorageClass the connector's volume can actually bind to. It **installs nothing**.

There is one script per cloud, each fully self-contained. Run the one matching where your registry lives:

| Your registry | Script |
|---|---|
| Amazon ECR, or any other registry | `scripts/sia-connector-prerequisites.sh` |
| Google Artifact / Container Registry | `scripts/sia-connector-prerequisites-gcp.sh` |
| Azure Container Registry | `scripts/sia-connector-prerequisites-azure.sh` |

All three take the same flags and run the same checks in the same order; they differ only in how they talk to your registry.

```bash
cp scripts/sia-connector.env.example sia-connector.env
$EDITOR sia-connector.env          # fill in the REQUIRED block
chmod 600 sia-connector.env

./scripts/sia-connector-prerequisites.sh --config ./sia-connector.env
```

It exits 0 when every check passes and 1 if any of them fails, so it also works as a CI gate. It needs no password, and the only object it creates anywhere is a throwaway connectivity-probe pod, which it deletes again — pass `--skip-egress-check` to avoid even that.

Run it from the root of your clone and it finds both the chart archive and the connector build context on its own — no `CHART_REF` or `DOCKERFILE_DIR` needed. From anywhere else, pass `--chart-ref` and `--dockerfile-dir`.

Each check, and what to do when it fails, is documented in [prerequisites.md](docs/prerequisites.md).

---

## Installation

### 1. Get the chart

The chart ships in this repository, so a clone already has it — there is no Helm repository to add:

```bash
git clone https://github.com/cyberark/sia-helm-charts.git
cd sia-helm-charts
ls sia-k8s-connector/sia-connector-*.tgz
```

> **Note:** Helm cannot authenticate to a private GitHub repository, so `helm repo add` pointed at this repository will not work. Install from the archive, as every command below does.

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
helm upgrade --install sia-connector ./sia-k8s-connector/sia-connector-<CHART_VERSION>.tgz \
  --namespace sia-k8s-connector \
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

---

## Maintenance mode (upgrades & rollbacks)

> **Looking for a step-by-step operator walkthrough?**
> See the dedicated [Upgrade, Rollback & Uninstall guide](docs/upgrade-rollback-uninstall.md).

Each connector can host long-running sessions (up to 24 h). To avoid interrupting active sessions during an upgrade or rollback, place connectors into **maintenance mode** first: the SIA platform stops routing new sessions to them while existing sessions finish naturally.

The chart ships with a `helm sia-maintenance` plugin that calls the SIA API **directly from your local machine** — no Helm revision is created, so `helm history` stays clean and `helm rollback` always targets the correct previous chart version.

After a safe upgrade or rollback, disable maintenance mode manually with `helm sia-maintenance disable` once the rollout is healthy and you are ready to accept new sessions.

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
helm upgrade sia-connector ./sia-k8s-connector/sia-connector-<NEW_VERSION>.tgz \
  --namespace <NAMESPACE> \
  --reuse-values

# Step 4 — verify the rollout is healthy, then disable maintenance mode.
kubectl rollout status statefulset/sia-connector -n <NAMESPACE>
helm -n <NAMESPACE> sia-maintenance disable
```

### Fast upgrade (no session draining)

Use this when there are no active long-running sessions, or in non-production environments.

```bash
helm upgrade sia-connector ./sia-k8s-connector/sia-connector-<NEW_VERSION>.tgz \
  --namespace <NAMESPACE> \
  --reuse-values
```

---

### Safe rollback (graceful — drain sessions first)

Because `helm sia-maintenance enable` creates **no Helm revision**, `helm rollback` without a revision number always targets the correct immediately preceding chart version.

```bash
# Step 1 — enable maintenance mode.
#   The SIA platform stops routing new sessions to the connectors.
helm -n <NAMESPACE> sia-maintenance enable

# Step 2 — wait for in-flight sessions to drain (0–24 h).

# Step 3 — roll back to the previous chart version.
helm rollback sia-connector -n <NAMESPACE>

# Step 4 — verify the rollout is healthy, then disable maintenance mode.
kubectl rollout status statefulset/sia-connector -n <NAMESPACE>
helm -n <NAMESPACE> sia-maintenance disable
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

**Re-check the environment first**

Most install-time failures are an environment problem rather than a chart problem — a blocked egress path, no usable StorageClass, an expired registry token, insufficient RBAC. Re-running the prerequisite checks names the cause directly, and changes nothing:

```bash
./scripts/sia-connector-prerequisites.sh --config ./sia-connector.env
```

The transcript it writes (`sia-connector-prerequisites-<UTC>.log`, with credential values redacted) is a good thing to attach to a support ticket. Each check is documented in [prerequisites.md](docs/prerequisites.md).

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
