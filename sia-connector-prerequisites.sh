#!/usr/bin/env bash
# =============================================================================
# CyberArk SIA Kubernetes Connector — prerequisites and preparation
#
# Gets your environment completely ready to release the connector, and stops
# deliberately short of the release itself:
#
#     ./sia-connector-prerequisites.sh --config ./sia-connector.env
#
#   1. validates this machine, your cluster, your registry and your tenant
#      parameters, and stops before changing anything if any check fails
#   2. builds the connector image for your environment
#   3. verifies the built image, then publishes it to your registry
#   4. ensures the namespace
#   5. creates the image pull secret
#   6. creates the sia-auth secret
#
# It does NOT run `helm upgrade --install`. That one step is left to you.
#
# This DOES write to your cluster and your registry. Steps 2-6 are skipped
# entirely if any check in step 1 fails, and you are shown a summary and asked
# to confirm before the first of them runs. Use --check-only for step 1 alone,
# which changes nothing.
#
# See PREREQUISITES.md for what each check means and how to act on it.
# =============================================================================

set -euo pipefail
umask 077

# ---------------------------------------------------------------------------
# The checks themselves live in sia-connector-common.sh, shared with anything
# else in this distribution that has to validate an environment before acting.
# ---------------------------------------------------------------------------
_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_COMMON="${_SELF_DIR}/sia-connector-common.sh"
if [[ ! -f "${_COMMON}" ]]; then
  printf 'ERROR: cannot find sia-connector-common.sh next to this script.\n' >&2
  printf '       Expected it at: %s\n' "${_COMMON}" >&2
  printf '       The two files ship together in the sia-helm-charts distribution.\n' >&2
  printf '       Put them in the same directory and run this again.\n' >&2
  exit 1
fi
# shellcheck source=sia-connector-common.sh
source "${_COMMON}"

# ---------------------------------------------------------------------------
# Defaults for the preparation steps. Everything the checks use is defaulted
# in sia-connector-common.sh.
# ---------------------------------------------------------------------------
PULL_SECRET="sia-registry-creds"
SECRET_NAME="sia-auth"
KUBECTL_VERSION="v1.30.0"
BASE_IMAGE="alpine:latest"
PASSWORD_FILE=""
SIA_PASSWORD="${SIA_PASSWORD:-}"

# This script creates the sia-auth secret, so the checks should report on the
# credential that is about to go into it.
WANT_PASSWORD=true

usage() {
  cat <<'EOF'
CyberArk SIA Kubernetes Connector — prerequisites and preparation

Validates your environment, then builds and publishes the connector image and
creates the namespace and secrets — everything the connector needs except the
Helm release itself, which is left to you.

  ./sia-connector-prerequisites.sh --config ./sia-connector.env --check-only  # validate
  ./sia-connector-prerequisites.sh --config ./sia-connector.env               # prepare

Nothing is created in your cluster or registry until every check passes, and
you are asked to confirm first. Exits 0 on success, 1 on failure.

Required parameters
  --root-domain <domain>          Your SIA environment domain (e.g. cyberark.cloud)
  --idaptive-tenant-id <id>       Identity tenant ID from the SIA Admin Portal
  --tenant-subdomain <name>       Your tenant subdomain
  --connector-pool-id <uuid>      Connector Pool ID from the SIA Admin Portal
  --username <user>               Service-account username
  --registry <host[/path]>        Your container registry

Password (never accepted as a flag value)
  Needed only for the sia-auth secret. Supply it via the SIA_PASSWORD
  environment variable, --password-file <path>, or the interactive masked
  prompt. Not required with --check-only.

Optional
  --namespace <ns>                Default: sia-k8s-connector
  --replicas <n>                  Default: 1
  --image-name <name>             Default: cms-k8s-connector
  --image-tag <tag>               Default: latest
  --pull-secret <name>            Default: sia-registry-creds
  --registry-username <user>      For registries needing docker login
  --registry-password-file <path> Password/token file for the above
  --chart-ref <url|file.tgz>      A chart archive or a Helm repo URL. Omit it and
                                  the newest archive in this distribution is used
  --chart-version <ver>           Default: newest available
  --storage-class <name>          Required if the cluster has no default
  --proxy <url>                   Outbound HTTP/HTTPS proxy for the connector
  --platform <os/arch>            Default: linux/amd64; checked against your nodes
  --kubectl-version <ver>         kubectl embedded in the image; default: v1.30.0
  --base-image <ref>              Image base layer; default: alpine:latest
  --dockerfile-dir <path>         Directory holding the connector Dockerfile
  --config <path>                 Read any of the above as KEY=value
  --log-file <path>               Default: ./sia-connector-prerequisites-<timestamp>.log

Behaviour
  --check-only                    Run the checks only; change nothing
  --skip-build                    Image is already built and pushed
  --skip-pull-secret              Registry is public, or the secret already exists
  --skip-egress-check             Do not create the throwaway connectivity-probe pod
  --yes                           Non-interactive; never prompt
  -h, --help                      This message
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing. --config is read first so explicit flags win regardless of
# ordering; then each argument is offered to the shared parser, and anything it
# does not recognise is handled here.
# ---------------------------------------------------------------------------
preparse_config "$@"

while [[ $# -gt 0 ]]; do
  if common_parse_arg "$@"; then
    shift "${ARG_SHIFT}"
    continue
  fi
  case "$1" in
    --pull-secret)            PULL_SECRET="${2:?}"; shift 2 ;;
    --kubectl-version)        KUBECTL_VERSION="${2:?}"; shift 2 ;;
    --base-image)             BASE_IMAGE="${2:?}"; shift 2 ;;
    --password-file)          PASSWORD_FILE="${2:?}"; shift 2 ;;
    --check-only)             CHECK_ONLY=true; shift ;;
    --yes|-y)                 ASSUME_YES=true; shift ;;
    -h|--help)                usage; exit 0 ;;
    --release|--cluster-name)
      die "$1 affects the Helm release, which this script does not run.
       Pass it to whichever step performs the release." ;;
    --password|--password=*)
      die "--password is not accepted: it would be visible in 'ps' and your shell history.
       Use SIA_PASSWORD, --password-file <path>, or the interactive prompt." ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done

setup_transcript "sia-connector-prerequisites"
make_tmpdir

log "${C_BOLD}CyberArk SIA Kubernetes Connector — prerequisites v${SIA_TOOLS_VERSION}${C_RESET}"
log "${C_DIM}$(date -u +'%Y-%m-%dT%H:%M:%SZ')  ·  transcript: ${LOG_FILE}${C_RESET}"

# ---------------------------------------------------------------------------
# Resolve the password (before the checks, so they can report on it). Not
# needed for --check-only, which creates no secret.
# ---------------------------------------------------------------------------
if [[ -z "${SIA_PASSWORD}" && -n "${PASSWORD_FILE}" ]]; then
  [[ -f "${PASSWORD_FILE}" ]] || die "password file not found: ${PASSWORD_FILE}"
  SIA_PASSWORD="$(<"${PASSWORD_FILE}")"
  SIA_PASSWORD="${SIA_PASSWORD%%$'\n'*}"
fi
if [[ -z "${SIA_PASSWORD}" && "${CHECK_ONLY}" == "false" ]]; then
  if [[ "${ASSUME_YES}" == "true" ]]; then
    die "no password supplied. Set SIA_PASSWORD or use --password-file (--yes disables prompting)."
  fi
  if [[ -r /dev/tty ]]; then
    read -rsp "Service-account password: " SIA_PASSWORD </dev/tty; echo
  else
    die "no password supplied and no terminal available to prompt."
  fi
fi

# =============================================================================
# CHECKS
# =============================================================================
run_prerequisite_checks

if (( FAIL_COUNT > 0 )); then
  log ""
  log "${C_RED}Prerequisites not met — nothing was created.${C_RESET}"
  log "Fix the items marked [FAIL] above and run this again."
  log "Transcript: ${LOG_FILE}   (safe to attach to a support ticket)"
  exit 1
fi

if [[ "${CHECK_ONLY}" == "true" ]]; then
  log ""
  log "${C_GREEN}All prerequisites met.${C_RESET} No changes were made (--check-only)."
  (( WARN_COUNT > 0 )) && log "Review the ${WARN_COUNT} warning(s) above before preparing."
  log "Transcript: ${LOG_FILE}"
  exit 0
fi

# =============================================================================
# PREPARE
# =============================================================================
log ""
log "About to prepare:"
log "  cluster    $(kubectl config current-context 2>/dev/null)"
log "  namespace  ${NAMESPACE}"
log "  registry   ${REGISTRY%%/*}"
log "  image      ${IMAGE_REMOTE}"
log "  secrets    ${PULL_SECRET}, ${SECRET_NAME}"
log ""
log "  The Helm release is NOT part of this. Nothing is deployed."
if ! confirm "Proceed?"; then
  log "Aborted. Nothing was created."
  exit 0
fi

# --- build ------------------------------------------------------------------
if [[ "${SKIP_BUILD}" == "true" ]]; then
  step "Skipping build (--skip-build)"
else
  step "Building ${IMAGE_LOCAL} for ${PLATFORM}"
  info "ROOT_DOMAIN=${ROOT_DOMAIN} is baked into the image and cannot be changed later"
  docker build \
    --platform "${PLATFORM}" \
    --build-arg BASE_IMAGE="${BASE_IMAGE}" \
    --build-arg ROOT_DOMAIN="${ROOT_DOMAIN}" \
    --build-arg KUBECTL_VERSION="${KUBECTL_VERSION}" \
    --tag "${IMAGE_LOCAL}" \
    "${DOCKERFILE_DIR}"
  [[ "${BASE_IMAGE}" == "alpine:latest" ]] && \
    warn "base image" "alpine:latest — use a hardened base for production"

  step "Verifying the built image before publishing"
  _baked="$(docker run --rm --platform "${PLATFORM}" --entrypoint /bin/sh "${IMAGE_LOCAL}" \
              -c 'printf %s "${ROOT_DOMAIN}"' 2>/dev/null || true)"
  _plat="$(docker image inspect "${IMAGE_LOCAL}" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null || true)"
  if [[ "${_baked}" != "${ROOT_DOMAIN}" ]]; then
    die "the image reports ROOT_DOMAIN='${_baked}', expected '${ROOT_DOMAIN}'.
       Not publishing. Rebuild with --build-arg ROOT_DOMAIN correctly set."
  fi
  ok "baked ROOT_DOMAIN" "${_baked}"
  if [[ "${_plat}" != "${PLATFORM}" ]]; then
    die "the image is ${_plat} but ${PLATFORM} was requested. Not publishing."
  fi
  ok "image platform" "${_plat}"
  if docker run --rm --platform "${PLATFORM}" --entrypoint /bin/sh "${IMAGE_LOCAL}" \
       -c 'command -v kubectl >/dev/null' 2>/dev/null; then
    ok "embedded kubectl" "present"
  else
    warn "embedded kubectl" "not found in the image"
  fi
fi

# --- registry login + push --------------------------------------------------
if [[ "${SKIP_BUILD}" == "true" ]]; then
  step "Skipping push (--skip-build)"
else
  step "Authenticating to ${REGISTRY%%/*}"
  if is_ecr; then
    aws ecr get-login-password --region "$(ecr_region)" \
      | docker login --username AWS --password-stdin "${REGISTRY%%/*}"
    aws ecr describe-repositories --repository-names "${IMAGE_NAME}" --region "$(ecr_region)" >/dev/null 2>&1 \
      || aws ecr create-repository --repository-name "${IMAGE_NAME}" --region "$(ecr_region)" \
           --image-scanning-configuration scanOnPush=true >/dev/null
  elif [[ -n "${REGISTRY_USERNAME}" ]]; then
    docker login --username "${REGISTRY_USERNAME}" --password-stdin "${REGISTRY%%/*}" \
      < "${REGISTRY_PASSWORD_FILE}"
  else
    info "using this machine's existing docker credentials"
  fi

  step "Pushing ${IMAGE_REMOTE}"
  info "the chart sets imagePullPolicy=Always, so moving an existing tag changes what"
  info "any other release using it will run after its next restart"
  docker tag "${IMAGE_LOCAL}" "${IMAGE_REMOTE}"
  docker push "${IMAGE_REMOTE}"
fi

# --- namespace --------------------------------------------------------------
step "Ensuring namespace ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# --- image pull secret ------------------------------------------------------
if [[ "${SKIP_PULL_SECRET}" == "true" ]]; then
  step "Skipping image pull secret (--skip-pull-secret)"
else
  step "Creating image pull secret ${PULL_SECRET}"
  if is_ecr; then
    _reg_user="AWS"
    _reg_pass="$(aws ecr get-login-password --region "$(ecr_region)")"
  elif [[ -n "${REGISTRY_USERNAME}" ]]; then
    _reg_user="${REGISTRY_USERNAME}"
    _reg_pass="$(<"${REGISTRY_PASSWORD_FILE}")"
  else
    die "cannot create a pull secret without registry credentials.
       Supply --registry-username and --registry-password-file, or pass --skip-pull-secret
       if the registry is public or the secret already exists."
  fi
  # Written via a 0600 temp file rather than --from-literal, so the credential
  # never appears in this process's argv (and therefore never in 'ps').
  _dockercfg="${TMPDIR_SELF}/dockercfg.json"
  printf '{"auths":{"%s":{"auth":"%s"}}}' \
    "${REGISTRY%%/*}" "$(printf '%s:%s' "${_reg_user}" "${_reg_pass}" | base64 | tr -d '\n')" \
    > "${_dockercfg}"
  kubectl create secret generic "${PULL_SECRET}" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="${_dockercfg}" \
    -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  unset _reg_pass
  rm -f "${_dockercfg}"
fi

# --- auth secret ------------------------------------------------------------
# Generated as YAML with base64 values rather than `--from-literal`, which would
# place the password in kubectl's argv where any local user could read it.
step "Creating ${SECRET_NAME} secret"
_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
cat > "${TMPDIR_SELF}/sia-auth.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
data:
  username: $(_b64 "${SIA_USERNAME}")
  password: $(_b64 "${SIA_PASSWORD}")
  idaptiveTenantId: $(_b64 "${IDAPTIVE_TENANT_ID}")
  tenantSubdomain: $(_b64 "${TENANT_SUBDOMAIN}")
EOF
kubectl apply -f "${TMPDIR_SELF}/sia-auth.yaml"
rm -f "${TMPDIR_SELF}/sia-auth.yaml"

# =============================================================================
# DONE — everything but the release
# =============================================================================
heading "Ready to release"
log "  In namespace ${NAMESPACE}:"
log "    namespace     ready"
[[ "${SKIP_PULL_SECRET}" == "false" ]] && log "    ${PULL_SECRET}   image pull secret"
log "    ${SECRET_NAME}      connector credentials"
log ""
log "  In your registry:"
log "    ${IMAGE_REMOTE}"
log ""
log "  Chart resolved:"
log "    ${CHART_NAME}-${CHART_VERSION}  (${CHART_INSTALL_REF})"
log ""
log "  Nothing is deployed. The Helm release is the remaining step."
(( WARN_COUNT > 0 )) && log "" && log "  Review the ${WARN_COUNT} warning(s) above."
log ""
log "  Transcript: ${LOG_FILE}"
exit 0
