# SIA Kubernetes Connector — prerequisite checks

`sia-connector-prerequisites.sh` validates that this machine, your cluster, your registry
and your tenant parameters are ready to run the connector. It **installs nothing**, needs
**no password**, and exits 0 when every check passes and 1 if any of them fails — so it
also works as a CI gate.

Run it as often as you like, before you have credentials, a registry or a maintenance
window. The only object it creates anywhere is a throwaway connectivity-probe pod, which it
deletes again; `--skip-egress-check` avoids even that.

Its transcript is a good thing to attach to a support ticket — it captures your whole
environment without exposing secrets.

---

## Before you start

| Tool | Needed for | Minimum |
|---|---|---|
| `kubectl` | Talking to your cluster | 1.24 |
| `helm` | Reading the chart | 3.10 |
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

### Two things the checks need from your working copy

These scripts do not download the product for you. Both of the following are delivered in
this repository, alongside the scripts:

| What | Why | Found how |
|---|---|---|
| **The Helm chart** — `sia-k8s-connector/sia-connector-<version>.tgz` | Defines the connector's StatefulSet, RBAC and storage | Automatically; the newest archive present is used. `--chart-ref` pins a specific one, or names a Helm repository URL |
| **The connector build context** — `sia-k8s-connector/docker/`, holding `Dockerfile`, `entrypoint.sh` and `connector-aliases.sh` | The image is built locally, because your environment's domain is compiled into it and cannot be changed afterwards | Automatically. `--dockerfile-dir` overrides |

**Run the script from the root of your clone** and both are located without any flags. That
is the only thing the automatic lookup depends on — from anywhere else, pass `--chart-ref`
and `--dockerfile-dir` explicitly.

Check an archive yourself if you want to:

```bash
helm show chart ./sia-k8s-connector/sia-connector-<version>.tgz
```

---

## Run the checks

### 1. Fill in the parameters

```bash
cp sia-connector.env.example sia-connector.env
$EDITOR sia-connector.env          # fill in the REQUIRED block
chmod 600 sia-connector.env
```

The file deliberately holds no password. Values only a later install needs are ignored here
rather than rejected, so one file serves both.

Confirm nothing you meant to set is still commented out — a value can look set and be
silently ignored:

```bash
grep -vE '^\s*(#|$)' sia-connector.env
```

### 2. Run

```bash
./sia-connector-prerequisites.sh --config ./sia-connector.env
```

Every parameter also works as a flag; `--help` lists them all, and flags override the
config file.

### Flags it does not take

It rejects, with a message telling you why, anything that only affects an install:
`--release`, `--pull-secret`, `--cluster-name`, `--kubectl-version`, `--base-image`, and
every form of the password.

`--check-only` and `--yes` are accepted and ignored — this script never changes anything and
never prompts, so both are already true of it.

---

## What each check means

Each prints `[ OK ]`, `[WARN]`, `[FAIL]` or `[SKIP]`. Warnings are advisory; a single
failure means the environment is not ready.

### Parameters

Confirms nothing required is missing, that no value is still a `<placeholder>`, and that
your root domain is shaped like a domain. It also echoes the two URLs it derived, so you can
sanity-check them against your portal before going further.

An unedited copy of the example file fails here on all six required values at once. If that
happens, you copied it but did not save your edits.

### Tooling

Checks each tool is present *and usable* — notably that the Docker **daemon responds**, not
merely that the `docker` binary exists.

### Cluster

Prints the **target cluster context in bold**. Deploying into the wrong cluster is the most
damaging mistake available here, and it is an easy one to make when you manage several.

If `kubectl` cannot reach the cluster at all, the check points at `KUBECONFIG` and mentions a
specific trap: `KUBECONFIG="~/path"` in double quotes does **not** expand the tilde, and the
resulting error (`current-context is not set`) reads like a cluster fault rather than a
quoting bug. Use `"$HOME/path"`.

### Permissions

Runs `kubectl auth can-i` for each object the chart creates, including the cluster-scoped
ClusterRole. Without this check, insufficient RBAC surfaces halfway through the Helm install,
leaving a partial release behind.

### Node architecture

Compares your nodes' CPU architecture against the image you are about to build. A mismatch is
a **failure**, and the check prints the corrected `--platform` value.

This matters more than it sounds. Building on an Apple Silicon Mac for x86_64 nodes succeeds
locally and fails only once the pod tries to start, as `Init:ErrImagePull` / *no match for
platform in manifest* — an error that gives no hint about its cause.

### Storage

The chart requests a 1Gi volume per replica. If your cluster has no default StorageClass and
you have not passed `--storage-class`, the volume is created with no class and never binds —
the pod waits forever with no obvious explanation. So that combination is a **failure**, and
the message names Amazon EKS Auto Mode as the usual cause.

If the class binds lazily (`WaitForFirstConsumer`), the check says so, because a briefly
`Pending` volume is then normal rather than a problem.

### Existing release

If the namespace already holds a release, its chart version is compared with the target and
you are told whether this would be a reinstall, an upgrade, or a **downgrade**.

### metrics-server

A **warning only**. Without it the chart's HorizontalPodAutoscaler reports `<unknown>`
forever. Nothing breaks — your connectors still run at the replica count you asked for — but
the autoscaler cannot act. Install metrics-server if you want autoscaling, or disable the
HPA with `--set autoscaling.enabled=false`.

### Chart source

Resolves the chart you are going to deploy and reports the version it found.

With `CHART_REF` unset — the normal case — it takes the newest
`sia-k8s-connector/sia-connector-<version>.tgz` in your working copy and verifies the archive
really is a chart before anything else happens. The line it prints names the exact file and
version, so you can confirm you are deploying what you think you are. Several versions in one
working copy is fine; they are compared by version order, not filename order.

A **failure** here means it found no archive, which in practice means you are not running from
the root of your clone. Either `cd` there, or name the chart explicitly:

```bash
--chart-ref ./sia-k8s-connector/sia-connector-<version>.tgz
```

`--chart-ref` also accepts a Helm repository URL, if your organisation republishes the chart
to an internal registry. In that case the check adds the repo, reads its index and lists the
available versions, failing if the version you pinned is not among them. Note that a Helm
repository must serve `index.yaml` at exactly the URL you give it, and that Helm cannot
authenticate to a private GitHub repository — so a URL pointing back at this repository will
not work. Use the archive in your clone.

### Registry

For Amazon ECR, verifies that the AWS identity you are authenticated as actually owns the
account in the registry hostname — an inherited `AWS_PROFILE` pointing at the wrong account
is easy to miss. It also warns that ECR tokens expire after **12 hours**, which is why a
cluster that pulled fine this morning can fail this evening.

### Connectivity from inside the cluster

Creates a short-lived pod that tries to reach your SIA identity and API hosts, then deletes
it. This is the one thing that cannot be tested from your laptop: your machine may have
internet access while your cluster nodes do not. Blocked egress is a common cause of a
deployment that looks perfect until the connector fails to register.

**Any HTTP status proves egress works** — these endpoints require authentication, so `401`,
`403` and even `5xx` all count as reachable. Only a curl failure (`000`, no response at all)
means DNS, routing or a firewall is in the way. Failures here are warnings, not errors; the
output is intended for your network team. If egress requires a proxy, re-run with
`--proxy <url>`.

Because this is the only check you cannot perform yourself, it is skipped for as few reasons
as possible: an unreachable cluster, missing or placeholder tenant parameters, no namespace
it is allowed to create a pod in, or `--skip-egress-check`. An unrelated failure elsewhere
does not suppress it.

---

## Transcript

Every run writes a timestamped log next to the script, with credential values redacted:
`sia-connector-prerequisites-<UTC>.log`. Override the path with `--log-file`.

Both that log and your filled-in `sia-connector.env` are generated locally and are listed in
`.gitignore`, so neither is committed by accident.
