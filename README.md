# SIA K8s Connector — Helm Chart

This Helm chart deploys the **SIA Kubernetes Connector** into your cluster.  
It is the recommended path for teams that prefer managing Helm releases directly, without using the guided setup script.

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.24+ |
| [Helm](https://helm.sh/docs/intro/install/) | 3.10+ |

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

### 4. Install the chart

```bash
helm upgrade --install sia-connector sia/sia-k8s-connector \
  --namespace sia-k8s-connector \
  --version <CHART_VERSION> \
  --set connectorPoolId="<CONNECTOR_POOL_ID>" \
  --set replicaCount=1 \
  --set image.repository="docker.io/<IMAGE_REPOSITORY>" \
  --set image.tag="latest" \
  --set image.pullPolicy="Always"
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
| `proxy` | HTTP/HTTPS proxy URL for outbound connector traffic | No | `""` |

---

## Upgrading

To upgrade an existing release to a newer chart version:

```bash
helm repo update
helm upgrade sia-connector sia/sia-k8s-connector \
  --namespace sia-k8s-connector \
  --version <NEW_CHART_VERSION> \
  --reuse-values
```

> **Tip:** Use `--reuse-values` to keep all previously set values without having to repeat them.  
> Override individual values with additional `--set` flags as needed.

---

## Rolling back to the previous version

To revert a release to its previous revision:

```bash
helm rollback sia-connector -n sia-k8s-connector
```

> **Note:** Rollback is only supported to the immediately preceding Helm chart version. Rolling back further than one version is not supported.

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
