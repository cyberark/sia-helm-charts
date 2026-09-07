#!/usr/bin/env bash
# =============================================================================
# CyberArk SIA Kubernetes Connector — prerequisites and preparation
#
# Gets your environment completely ready to release the connector, and stops
# deliberately short of the release itself:
#
#     ./scripts/sia-connector-prerequisites.sh --config ./sia-connector.env
#
#   1. validates this machine, your cluster, your registry and your tenant
#      parameters, and stops before changing anything if any check fails
#   2. builds the connector image for your environment
#   3. verifies the built image, then publishes it to your registry
#   4. ensures the namespace
#   5. creates the image pull secret
#
# It does NOT run `helm upgrade --install`. That one step is left to you.
#
# Use --check-only for phase 1 alone (changes nothing).
#
# See docs/prerequisites.md for what each check means and how to act on it.
# =============================================================================

set -euo pipefail
umask 077

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
KUBECTL_VERSION="v1.30.0"
BASE_IMAGE=""

usage() {
  cat <<'EOF'
CyberArk SIA Kubernetes Connector — prerequisites and preparation

Validates your environment, then builds and publishes the connector image and
creates the namespace and secrets — everything the connector needs except the
Helm release itself, which is left to you.

  ./scripts/sia-connector-prerequisites.sh --config ./sia-connector.env --check-only  # validate only
  ./scripts/sia-connector-prerequisites.sh --config ./sia-connector.env               # validate + prepare

Nothing is created until every check passes, and you are asked to confirm first.
Exits 0 on success, 1 on failure.

Tenant parameters (from the SIA Admin Portal)
  --root-domain <domain>          Your SIA environment domain (e.g. cyberark.cloud)
  --idaptive-tenant-id <id>       Identity tenant ID
  --tenant-subdomain <name>       Your tenant subdomain

Infrastructure
  --registry <host[/path]>        Your container registry
  --registry-username <user>      For registries needing docker login
  --registry-password-file <path> Password/token file for the above
  --namespace <ns>                Default: sia-k8s-connector
  --image-name <name>             Default: cms-k8s-connector
  --image-tag <tag>               Default: latest
  --pull-secret <name>            Default: sia-registry-creds
  --platform <os/arch>            Default: linux/amd64; checked against your nodes
  --dockerfile-dir <path>         Directory holding the connector Dockerfile
  --kubectl-version <ver>         kubectl embedded in the image; default: v1.30.0
  --base-image <ref>              Image base layer; required
  --config <path>                 Full path to sia-connector.env config file

Behaviour
  --check-only                    Run the checks only; change nothing
  --skip-build                    Image is already built and pushed; skip build + push
  --skip-pull-secret              Registry is public, or the secret already exists
  --serve-local-repo              Build local chart index and start localhost HTTP server in background
  --local-repo-port <port>        Local chart repo server port; default: 18080
  --yes                           Non-interactive; never prompt
  -h, --help                      This message
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
preparse_config "$@"

# If --config was not given, fall back to sia-connector.env in the current
# directory. Fail immediately if that file also does not exist.
_CONF_FILE="${_SELF_DIR}/sia-connector.env"

if [[ -z "${CONFIG_FILE}" ]]; then
  if [[ -f "${_CONF_FILE}" ]]; then
    CONFIG_FILE="${_CONF_FILE}"
    set -a; source "${_CONF_FILE}"; set +a
  else
    die "no --config given and ${_CONF_FILE} not found."
  fi
fi

while [[ $# -gt 0 ]]; do
  if common_parse_arg "$@"; then
    shift "${ARG_SHIFT}"
    continue
  fi
  case "$1" in
    --pull-secret)            PULL_SECRET="${2:?}"; shift 2 ;;
    --kubectl-version)        KUBECTL_VERSION="${2:?}"; shift 2 ;;
    --base-image)             BASE_IMAGE="${2:?}"; shift 2 ;;
    --check-only)             CHECK_ONLY=true; shift ;;
    --yes|-y)                 ASSUME_YES=true; shift ;;
    -h|--help)                usage; exit 0 ;;
    --release|--cluster-name)
      die "$1 affects the Helm release, which this script does not run.
       Pass it to whichever step performs the release." ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done

setup_transcript "${_SELF_DIR}/sia-connector-prerequisites"
make_tmpdir

log "${C_BOLD}CyberArk SIA Kubernetes Connector — prerequisites v${SIA_TOOLS_VERSION}${C_RESET}"
log "${C_DIM}$(date -u +'%Y-%m-%dT%H:%M:%SZ')  ·  transcript: ${LOG_FILE}${C_RESET}"

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
log "Ready for SIA connector deployment:"
log "  Cluster:          $(kubectl config current-context 2>/dev/null)"
log "  Namespace:        ${NAMESPACE}"
log "  Registry:         ${REGISTRY%%/*}"
log "  Image:            ${IMAGE_REMOTE}"
log "  Registry secret:  ${PULL_SECRET}"
[[ "${SERVE_LOCAL_REPO}" == "true" ]] && log "  Local Chart Repo:  http://localhost:${LOCAL_REPO_PORT}/sia-k8s-connector/"
log ""
if ! confirm "Proceed?"; then
  log "Aborted. Nothing was created."
  exit 0
fi

WARN_COUNT=0
# --- build ------------------------------------------------------------------
if [[ "${SKIP_BUILD}" == "true" ]]; then
  step "Skipping build (--skip-build)"
else
  [[ -z "${BASE_IMAGE}" ]] && die "BASE_IMAGE is not set. Set it in sia-connector.env or pass --base-image."
  step "Building ${IMAGE_LOCAL} for ${PLATFORM}"
  info "ROOT_DOMAIN=${ROOT_DOMAIN} is baked into the image and cannot be changed later"
  docker build \
    --platform "${PLATFORM}" \
    --build-arg BASE_IMAGE="${BASE_IMAGE}" \
    --build-arg ROOT_DOMAIN="${ROOT_DOMAIN}" \
    --build-arg KUBECTL_VERSION="${KUBECTL_VERSION}" \
    --tag "${IMAGE_LOCAL}" \
    "${DOCKERFILE_DIR}"
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
  # Written via a temp file rather than --from-literal so the credential
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

# --- optional local chart repo ----------------------------------------------
if [[ "${SERVE_LOCAL_REPO}" == "true" ]]; then
  prepare_and_serve_local_repo "sia-k8s-connector" "${LOCAL_REPO_PORT}"
fi


# =============================================================================
# DONE
# =============================================================================
heading "Ready for SIA connector deployment"
log "  Namespace: ${NAMESPACE}"
log "  Docker Image URI: ${IMAGE_REMOTE}"
[[ "${SKIP_PULL_SECRET}" == "false" ]] && log "  Registry secret:  ${PULL_SECRET}"
log ""
(( WARN_COUNT > 0 )) && log "" && log "  Review the ${WARN_COUNT} warning(s) above."
log ""
log "  Transcript: ${LOG_FILE}"
exit 0
