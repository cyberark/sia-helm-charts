# SIA Kubernetes Connector — guided installer

`sia-connector-install.sh` installs the CyberArk SIA Kubernetes Connector into your
cluster. It builds the connector image for your environment, publishes it to a registry
you control, and installs the Helm chart.

It runs a set of preflight checks first and **creates nothing until they all pass**, so a
misconfiguration costs you a few seconds rather than a half-finished deployment you have to
unpick.

---

## Before you start

| Tool | Needed for | Minimum |
|---|---|---|
| `kubectl` | Talking to your cluster | 1.24 |
| `helm` | Installing the chart | 3.10 |
| `docker` | Building the connector image | Any current version, daemon running |
| `aws` | Only if your registry is Amazon ECR | v2 |
| `curl`, `base64` | Internal use | Present on any Linux/macOS |

You also need:

- `kubectl` already pointed at the target cluster.
- Permission on that cluster to create a namespace, a secret, a StatefulSet, and a
  **ClusterRole** — the chart grants the connector read access to node labels, which is
  cluster-scoped.
- A container registry you can push to. The image is built locally rather than pulled from
  CyberArk because your environment's domain is compiled into it.
- From the SIA Admin Portal: your Connector Pool ID, Identity tenant ID, tenant subdomain,
  and a service account with permission to register connectors.

### Two files you need from CyberArk

This script does not download the product for you. It needs both of these, and preflight
fails with a clear message if either is missing:

| What | Why | Pass it with |
|---|---|---|
| **The Helm chart**, either a repository URL or a `sia-connector-<version>.tgz` archive | The chart that defines the connector's StatefulSet, RBAC and storage | `--chart-ref` |
| **The connector build context** — a directory holding `Dockerfile`, `entrypoint.sh` and `connector-aliases.sh` | The image is built locally, because your environment's domain is compiled into it and cannot be changed afterwards | `--dockerfile-dir`, or run this script from the root of the distribution and it is found automatically |

Both ship together in the `sia-helm-charts` distribution. If your copy of that distribution
is laid out as delivered, run the installer from its root and it will locate the build
context on its own; only `--chart-ref` then needs pointing at the chart archive.

Check an archive before installing from it:

```bash
helm show chart ./sia-connector-<version>.tgz
```

---

## Install

```bash
cp sia-connector.env.example sia-connector.env
$EDITOR sia-connector.env          # fill in the REQUIRED block
chmod 600 sia-connector.env
```

Validate everything without changing anything:

```bash
./sia-connector-install.sh --config ./sia-connector.env --check-only
```

Then install:

```bash
./sia-connector-install.sh --config ./sia-connector.env
```

You will be prompted for the service-account password (masked), shown a summary of the
target cluster, and asked to confirm before anything is created.

Every parameter also works as a flag — `./sia-connector-install.sh --help` lists them all.
Flags override the config file.

---

## What the preflight checks mean

Each prints `[ OK ]`, `[WARN]`, `[FAIL]` or `[SKIP]`. Warnings are advisory and do not stop
the install; a single failure stops it before anything is created.

### Parameters

Confirms nothing required is missing, that no value is still a `<placeholder>`, and that
your root domain is shaped like a domain. It also echoes the two URLs it derived, so you
can sanity-check them against your portal before going further.

### Tooling

Checks each tool is present *and usable* — notably that the Docker **daemon responds**,
not merely that the `docker` binary exists.

### Cluster

Prints the **target cluster context in bold** and asks you to confirm it. Installing into
the wrong cluster is the most damaging mistake available here, and it is an easy one to
make when you manage several.

If `kubectl` cannot reach the cluster at all, the check points at `KUBECONFIG` and mentions
a specific trap: `KUBECONFIG="~/path"` in double quotes does **not** expand the tilde, and
the resulting error (`current-context is not set`) reads like a cluster fault rather than a
quoting bug. Use `"$HOME/path"`.

### Permissions

Runs `kubectl auth can-i` for each object the chart creates, including the cluster-scoped
ClusterRole. Without this check, insufficient RBAC surfaces halfway through the Helm
install, leaving a partial release behind.

### Node architecture

Compares your nodes' CPU architecture against the image you are about to build. A mismatch
is a **failure**, and the check prints the corrected `--platform` value.

This matters more than it sounds. Building on an Apple Silicon Mac for x86_64 nodes
succeeds locally and fails only once the pod tries to start, as
`Init:ErrImagePull` / *no match for platform in manifest* — an error that gives no hint
about its cause.

### Storage

The chart requests a 1Gi volume per replica. If your cluster has no default StorageClass
and you have not passed `--storage-class`, the volume is created with no class and never
binds — the pod waits forever with no obvious explanation. So that combination is a
**failure**, and the message names Amazon EKS Auto Mode as the usual cause.

If the class binds lazily (`WaitForFirstConsumer`), the check says so, because a briefly
`Pending` volume is then normal rather than a problem.

### Existing release

If the namespace already holds a release, its chart version is compared with the target and
you are told whether this is a reinstall, an upgrade, or a **downgrade**.

### metrics-server

A **warning only**. Without it the chart's HorizontalPodAutoscaler reports `<unknown>`
forever. Nothing breaks — your connectors still run at the replica count you asked for —
but the autoscaler cannot act. Install metrics-server if you want autoscaling, or disable
the HPA:

```bash
helm upgrade sia-connector <chart> -n <namespace> --reuse-values \
  --set autoscaling.enabled=false
```

### Connectivity from inside the cluster

Creates a short-lived pod that tries to reach your SIA identity and API hosts, then deletes
it. This is the one thing that cannot be tested from your laptop: your machine may have
internet access while your cluster nodes do not. Blocked egress is a common cause of an
install that looks perfect until the connector fails to register.

Failures here are warnings, not errors — the output is intended for your network team. If
egress requires a proxy, re-run with `--proxy <url>`.

Skip it with `--skip-egress-check` if pod creation is restricted in your environment.

### Registry

For Amazon ECR, verifies that the AWS identity you are authenticated as actually owns the
account in the registry hostname — an inherited `AWS_PROFILE` pointing at the wrong account
is easy to miss. It also warns that ECR tokens expire after **12 hours**, which is why a
cluster that pulled fine this morning can fail this evening.

---

## After the build, before the push

The installer runs the freshly built image and asserts that the domain compiled into it
matches what you asked for, and that its architecture is right. If either is wrong it
**aborts without publishing**.

This is deliberate: the domain is baked in at build time and cannot be patched afterwards.
Catching it here costs seconds; catching it later means a rebuild, a re-push and a
redeploy.

---

## If the connector does not come up

The installer waits for the pod, then watches the log for registration. If that does not
happen it diagnoses the specific cause rather than printing a wall of output:

| What it reports | What to do |
|---|---|
| Credentials rejected (`access_denied`) | The username or password is wrong. Tenant IDs were already validated. |
| Authenticated but not authorised (401/403) | The service account cannot provision connectors — check its role in the portal. |
| Architecture mismatch | Rebuild with the `--platform` value it prints. |
| Cannot pull the image | Pull secret missing, wrong, or its token expired. Re-run to refresh it, then restart the StatefulSet. |
| Volume never bound | No usable StorageClass — re-run with `--storage-class`. |
| No response at all | Node egress is blocked. It prints an in-cluster probe command to hand to your network team. |

---

## Transcript

Every run writes a timestamped log next to the script
(`sia-connector-install-<UTC>.log`), with credential values redacted. A `--check-only`
transcript is a good thing to attach to a support ticket — it captures your whole
environment without exposing secrets.

---

## Notes on handling secrets

- There is no `--password` flag. A password on a command line is visible to every user on
  the machine through `ps`, and stays in your shell history. Use the prompt,
  `--password-file`, or the `SIA_PASSWORD` environment variable.
- The `sia-auth` secret is created by generating YAML and piping it to `kubectl apply`,
  rather than `kubectl create secret --from-literal`, which would put the password in
  `kubectl`'s own argv.
- The config file is designed to hold no secrets, so it is safe to keep in version control
  alongside your other deployment configuration.
- `alpine:latest` is the default image base for convenience. For production, pass
  `--base-image` pointing at a hardened, scanned base; the installer warns when you use the
  default.

---

## Uninstall

```bash
helm uninstall sia-connector --namespace sia-k8s-connector --wait
kubectl delete namespace sia-k8s-connector
```

The chart's pre-delete hook deregisters each connector from SIA before the pods are
removed, and cleans up the volumes. Allow up to a minute for it. Deleting the namespace
afterwards clears the remaining secrets and config maps.

Your registry and its images are left untouched.
