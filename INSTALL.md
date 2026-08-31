# SIA Kubernetes Connector — guided install

`sia-connector-install.sh` builds the connector image for your environment, publishes it to a
registry you control, and installs the Helm chart.

It is one way to deploy the connector, not the only one — [README.md](README.md) covers
managing the Helm release directly, which is the better fit for teams that already have their
own image build and deployment pipeline.

> **Check your environment first.** `sia-connector-prerequisites.sh --check-only` runs every
> check this installer runs, changing nothing and needing no password, long before you have
> credentials or a maintenance window. **[PREREQUISITES.md](PREREQUISITES.md)** documents what
> each check means and what to do when it fails — and note that without `--check-only` that
> script goes on to build, publish and create the namespace and secrets itself.

This installer re-runs every one of those same checks itself, through the shared
`sia-connector-common.sh`, and creates nothing until all of them pass. A misconfiguration
therefore costs you a few seconds rather than a half-finished deployment you have to unpick.
All three files must sit in the same directory.

---

## Install

### 1. Fill in the parameters

```bash
cp sia-connector.env.example sia-connector.env
$EDITOR sia-connector.env          # fill in the REQUIRED block
chmod 600 sia-connector.env
```

One file serves the checks and the install alike. It deliberately holds no password.

### 2. Confirm the environment is ready

```bash
./sia-connector-prerequisites.sh --config ./sia-connector.env --check-only
```

Exit status 0 means every check passed. Keep `--check-only` on here: without it that script
also builds, publishes and creates the namespace and secrets, which the installer below does
for you anyway. See [PREREQUISITES.md](PREREQUISITES.md) for what each check covers and how to
act on a failure.

### 3. Install

```bash
./sia-connector-install.sh --config ./sia-connector.env
```

You will be prompted for the service-account password (masked), shown a summary of the target
cluster, and asked to confirm before anything is created.

Every parameter also works as a flag — `--help` lists the ones each script takes. Flags
override the config file.

> `./sia-connector-install.sh --check-only` runs the checks and stops, exactly like
> `sia-connector-prerequisites.sh`. It is kept so existing runbooks and pipelines do not
> break; new ones should call `sia-connector-prerequisites.sh`.

---

## After the build, before the push

The installer runs the freshly built image and asserts that the domain compiled into it
matches what you asked for, and that its architecture is right. If either is wrong it
**aborts without publishing**.

This is deliberate: the domain is baked in at build time and cannot be patched afterwards.
Catching it here costs seconds; catching it later means a rebuild, a re-push and a redeploy.

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

Every run writes a timestamped log next to the script, with credential values redacted:
`sia-connector-install-<UTC>.log`. Override the path with `--log-file`.

---

## Notes on handling secrets

- There is no `--password` flag. A password on a command line is visible to every user on the
  machine through `ps`, and stays in your shell history. Use the prompt, `--password-file`,
  or the `SIA_PASSWORD` environment variable.
- The `sia-auth` secret is created by generating YAML and piping it to `kubectl apply`, rather
  than `kubectl create secret --from-literal`, which would put the password in `kubectl`'s own
  argv.
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

The chart's pre-delete hook deregisters each connector from SIA before the pods are removed,
and cleans up the volumes. Allow up to a minute for it. Deleting the namespace afterwards
clears the remaining secrets and config maps.

Your registry and its images are left untouched.
