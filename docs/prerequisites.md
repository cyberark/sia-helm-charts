# SIA Kubernetes Connector — prerequisites and preparation

## Pick the script for your cloud

There is one script per cloud, and they are **fully self-contained** — pick the one that
matches where your registry lives and ignore the other two. Each carries its own copy of
every check, so the file you run is the whole story; there is no shared library to read
alongside it.

| Your registry | Script | Cloud CLI |
|---|---|---|
| `<account>.dkr.ecr.<region>.amazonaws.com`, or anything else | [`sia-connector-prerequisites.sh`](../scripts/sia-connector-prerequisites.sh) | `aws` |
| `<location>-docker.pkg.dev/<project>/<repo>`, `gcr.io/<project>` | [`sia-connector-prerequisites-gcp.sh`](../scripts/sia-connector-prerequisites-gcp.sh) | `gcloud` |
| `<name>.azurecr.io` (also `.cn`, `.us`) | [`sia-connector-prerequisites-azure.sh`](../scripts/sia-connector-prerequisites-azure.sh) | `az` |

All three take the same flags, run the same checks in the same order, print the same output
format and use the same exit codes. They differ only in how they authenticate to the
registry, whether they have to create the repository before pushing, and how they build the
image pull secret. The AWS script also handles any generic registry via `docker login`.

Everything below applies to all three; the cloud-specific parts are called out where they
differ. Substitute your own script name for `sia-connector-prerequisites.sh` in the commands.

---

Each script gets your environment ready to release the connector, in two phases:

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
| `aws` | The AWS script, if your registry is Amazon ECR | v2 |
| `gcloud` | The GCP script | Any current version |
| `az` | The Azure script | Any current version |
| `gke-gcloud-auth-plugin` | GKE, only if your kubeconfig references it | Any current version |
| `kubelogin` | Entra-integrated AKS, only if your kubeconfig references it | Any current version |
| `curl`, `base64` | Internal use | Present on any Linux/macOS |

You need only the cloud CLI belonging to the script you run. The two credential plugins are
asked for only when your kubeconfig actually references them — which is independent of where
your registry lives, so a GKE cluster pushing to ECR needs `gke-gcloud-auth-plugin` and the
AWS script.

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

This is the one check that differs per script. Each looks for the mistake specific to its
own cloud.

**AWS** — the AWS CLI is present and the credentials are valid; the ECR repository exists or
will be created on push. Warns that ECR tokens expire after **12 hours**, which is why a
cluster that pulled fine this morning can fail this evening.

**GCP** — the active account can see the project, and the Artifact Registry repository exists
and is of `DOCKER` format. Artifact Registry keeps the repository in the *registry path*
rather than in the image name, so `<host>/<project>` alone is not a valid push target; that
is reported against the parameter instead, because it is wrong whichever credential you use.
If your active `gcloud` project differs from the one in the registry path you are told — it
is easy to inherit one pointing elsewhere. `gcr.io` is accepted but flagged as deprecated.

**Azure** — the subscription can see the registry, its login server matches what you passed,
and `publicNetworkAccess` is not `Disabled` (which would need a private endpoint to push).
ACR creates the repository on first push, so there is nothing to pre-create.

#### Token lifetimes differ sharply, and it matters

ECR tokens last about 12 hours, `gcloud` access tokens about **1 hour**, and ACR access
tokens about **3 hours**. A pull secret built from a short-lived token survives the install —
the connector pulls its image once at start-up — but the next restart or rescheduling fails
with `ImagePullBackOff`, long after anything obviously happened. The GCP and Azure scripts
therefore warn at the moment they create the secret, so it lands in the warning count, and
name the durable alternative:

| Cloud | Durable alternative |
|---|---|
| GCP | Grant the node service account `roles/artifactregistry.reader`, then `--skip-pull-secret` |
| GCP | Or `--registry-username _json_key --registry-password-file <key.json>` |
| Azure | `az aks update -n <cluster> -g <group> --attach-acr <name>`, then `--skip-pull-secret` |
| Azure | Or a service principal with `AcrPull` via `--registry-username`/`--registry-password-file` |

On GCP and Azure an explicit `--registry-username` **takes precedence** over the cloud token
path. This is the reverse of the AWS script's ordering, and deliberate: on those two clouds
the explicit credential is the one that does not expire, so it should win. The AWS script
keeps the AWS CLI first, so an inherited `--registry-username` cannot quietly displace it.

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

Authenticates to your registry, creates the repository if that registry will not accept a
push without one, then tags and pushes:

| Script | Authentication | Repository |
|---|---|---|
| AWS | `aws ecr get-login-password`, or `docker login` for a generic registry | Created if absent (ECR) |
| GCP | `gcloud auth print-access-token` piped into `docker login` | Created if absent (Artifact Registry); on first push for `gcr.io` |
| Azure | `az acr login` | Created on first push |

The GCP script pipes a token into `docker login` rather than running `gcloud auth
configure-docker`, which would install a credential helper into this machine's docker config
permanently. Only the push about to happen is authenticated.

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
