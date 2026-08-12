# Contributing

Thanks for your interest in contributing to the SIA Helm charts. This document
outlines the process to help get your contribution accepted.

By participating in this project you agree to abide by our
[Code of Conduct](CODE_OF_CONDUCT.md).

## How to Contribute

1. Fork the repository and create a topic branch from `main`.
2. Make your change, and test it against a cluster (see below).
3. Ensure the chart still lints and templates cleanly.
4. Open a pull request describing the change and why it is needed.

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| [Helm](https://helm.sh/docs/intro/install/) | 3.10+ |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.24+ |

You should have `kubectl` configured against a test cluster before validating a
release end-to-end.

## Local Development

The chart source lives under [`sia-k8s-connector/`](sia-k8s-connector/).

### Lint and template

Validate the chart renders correctly before opening a PR:

```console
# Lint the chart for structural issues
$ helm lint sia-k8s-connector/

# Render the templates locally to inspect the generated manifests
$ helm template sia-connector sia-k8s-connector/
```

### Test on a cluster

Install your local changes into a namespace and verify the connector starts.
See the [README](README.md) for the full install flow, including creating the
`sia-auth` secret. In short:

```console
$ helm upgrade --install sia-connector sia-k8s-connector/ \
    --namespace sia-k8s-connector --create-namespace \
    --set connectorPoolId="<CONNECTOR_POOL_ID>" \
    --set image.repository="docker.io/<IMAGE_REPOSITORY>"

$ kubectl get pods -n sia-k8s-connector
```

### Package and publish

Releases are served directly from this repository. After bumping the chart
version in `Chart.yaml`, package the chart and regenerate the repository index:

```console
# Package the chart into sia-k8s-connector/
$ helm package sia-k8s-connector/ --destination sia-k8s-connector/

# Regenerate index.yaml (merges the new package into the existing index)
$ ./update-helm-index.sh
```

## Technical Requirements

* The chart must pass `helm lint`.
* Bump the chart `version` in `Chart.yaml` for any user-facing change.
* Keep the [README](README.md) configuration reference in sync with `values.yaml`.
