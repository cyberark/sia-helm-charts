# SIA Kubernetes Connector — prerequisites and preparation

`sia-connector-prerequisites.sh` gets your environment ready to release the connector, in
two phases:

1. **Checks** — validates this machine, your cluster, your registry and your tenant
   parameters. Nothing is touched, and the script stops here if any check fails.
2. **Preparation** — builds the connector image, verifies it, publishes it to your registry,
   ensures the namespace, and creates the image pull secret and the `sia-auth` secret.

It stops deliberately short of `helm upgrade --install`. That one step is yours to run.

**`--check-only` runs phase 1 alone.** In that mode it changes nothing and needs no
password, so it is safe to run as often as you like — before you have credentials, a
registry or a maintenance window — and it works as a CI gate. Exit status is 0 on success
and 1 on failure in either mode.

Phase 2 writes to your cluster and your registry, so you are shown a summary of exactly what
will be touched and asked to confirm before the first change. `--yes` skips that prompt for
non-interactive use.

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


## Workflow

### 1. Fill in the parameters

```bash
cp scripts/sia-connector.env.example sia-connector.env
$EDITOR sia-connector.env          # fill in the REQUIRED block
chmod 600 sia-connector.env
```

The file deliberately holds no password — the script refuses to run if it assigns one, since
config files get copied and committed by accident. Phase 2 needs the service-account password
for the `sia-auth` secret; supply it by the interactive masked prompt, `--password-file
<path>`, or the `SIA_PASSWORD` environment variable. `--check-only` needs none.

Confirm nothing you meant to set is still commented out — a value can look set and be
silently ignored:

```bash
grep -vE '^\s*(#|$)' sia-connector.env
```

### 2. Check, without changing anything

```bash
./scripts/sia-connector-prerequisites.sh --config ./sia-connector.env --check-only
```

### 3. Prepare

```bash
./scripts/sia-connector-prerequisites.sh --config ./sia-connector.env
```

Re-runs the checks, then builds, publishes and creates the namespace and secrets — after
asking you to confirm. See [What it does after the checks](#what-it-does-after-the-checks).

Every parameter also works as a flag; `--help` lists them all, and flags override the
config file.

### Flags it does not take

Two, both rejected with a message telling you why:

- `--release` and `--cluster-name` affect only the Helm release, which this script does not
  run.
- `--password` in any form. A password on a command line is visible to every user on the
  machine through `ps` and stays in your shell history. Use the prompt, `--password-file`, or
  `SIA_PASSWORD`.

---

## What each check means

Each prints `[ OK ]`, `[WARN]`, `[FAIL]` or `[SKIP]`. Warnings are advisory; a single
failure means the environment is not ready.

### Parameters

Confirms nothing required is missing, that no value is still a `<placeholder>`, and that
your root domain is shaped like a domain. It also echoes the two URLs it derived, so you can
sanity-check them against your portal before going further.

An unedited copy of the example file fails here on the required values that are still empty.
If that happens, you copied it but did not save your edits.

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

### metrics-server

A **warning only**. Without it the chart's HorizontalPodAutoscaler reports `<unknown>`
forever. Nothing breaks — your connectors still run at the replica count you asked for — but
the autoscaler cannot act. Install metrics-server if you want autoscaling, or disable the
HPA with `--set autoscaling.enabled=false`.

### Registry

For Amazon ECR, verifies that the AWS CLI is present and that your credentials are valid.
It also warns that ECR tokens expire after **12 hours**, which is why a cluster that pulled
fine this morning can fail this evening.

---

## What it does after the checks

Skipped entirely with `--check-only`, and skipped if any check failed. You are asked to
confirm before the first of these runs.

### 1. Build the connector image

`docker build` for your `--platform`, with `ROOT_DOMAIN`, the base image and the embedded
kubectl version passed in as build arguments. `--skip-build` skips this and the push, for an
image you have already published.

### 2. Verify the image before publishing

Runs the freshly built image and asserts that the domain compiled into it matches what you
asked for, and that its architecture is right. If either is wrong it **aborts without
publishing**.

This is deliberate: the domain is baked in at build time and cannot be patched afterwards.
Catching it here costs seconds; catching it later means a rebuild, a re-push and a redeploy.

### 3. Publish it

Authenticates to your registry — `docker login`, or `aws ecr get-login-password` for ECR,
where the repository is also created if it does not exist — then tags and pushes.

Note that the chart sets `imagePullPolicy=Always`, so moving an existing tag changes what any
other release using that tag will run after its next restart.

### 4. Ensure the namespace

Created if absent, left alone if present.

### 5. Create the image pull secret

A `dockerconfigjson` secret, named by `--pull-secret` (default `sia-registry-creds`), so the
cluster can pull the image you just pushed. `--skip-pull-secret` skips it, for a public
registry or a secret you manage yourself.

### 6. Create the `sia-auth` secret

The connector's own credentials: `username`, `password`, `idaptiveTenantId` and
`tenantSubdomain`. The connector reads all four as environment variables at start-up.

Both secrets are written by generating YAML and piping it to `kubectl apply`, rather than
`kubectl create secret --from-literal`, which would place the credential in `kubectl`'s own
argv where any local user could read it.

### What is left

Nothing is deployed. The script closes by listing what now exists — namespace, both secrets,
and the published image reference — and the Helm release remains the one outstanding step.

---

## Transcript

Every run writes a timestamped log next to the script, with credential values redacted:
`sia-connector-prerequisites-<UTC>.log`. Override the path with `--log-file`.

Both that log and your filled-in `sia-connector.env` are generated locally and are listed in
`.gitignore`, so neither is committed by accident.
