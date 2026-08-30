#!/usr/bin/env bash
# =============================================================================
# CyberArk SIA Kubernetes Connector — guided installer
#
# Builds the connector image for your environment, publishes it to your own
# container registry, and installs the Helm chart into your cluster.
#
# Check your prerequisites first — this makes no changes at all:
#
#     ./sia-connector-prerequisites.sh --config ./sia-connector.env
#
# Then install:
#
#     ./sia-connector-install.sh --config ./sia-connector.env
#
# This script re-runs every one of those same checks itself, and nothing is
# created in your cluster or registry until all of them pass. The separate
# prerequisites script is simply that gate on its own, safe to run any time.
#
# See README.md for the parameter reference and INSTALL.md for the full guide.
# =============================================================================

set -euo pipefail
umask 077

# ---------------------------------------------------------------------------
# The prerequisite checks live in sia-connector-common.sh, shared with
# sia-connector-prerequisites.sh so the two can never disagree about what
# "ready to install" means.
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
# Defaults the install needs and the checks do not. Everything the checks use
# is defaulted in sia-connector-common.sh.
# ---------------------------------------------------------------------------
RELEASE="sia-connector"
PULL_SECRET="sia-registry-creds"
KUBECTL_VERSION="v1.30.0"
BASE_IMAGE="alpine:latest"
SECRET_NAME="sia-auth"
ROLLOUT_TIMEOUT="300"
REGISTER_TIMEOUT="180"
CLUSTER_NAME=""
PASSWORD_FILE=""
SIA_PASSWORD="${SIA_PASSWORD:-}"

# Unlike the prerequisites script, this one is about to put the credential in a
# Secret, so the checks should report on it.
WANT_PASSWORD=true

usage() {
  cat <<'EOF'
CyberArk SIA Kubernetes Connector — guided installer

Builds the connector image for your environment, publishes it to your own
container registry, and installs the Helm chart into your cluster.

  ./sia-connector-prerequisites.sh --config ./sia-connector.env   # validate
  ./sia-connector-install.sh --config ./sia-connector.env          # install

The installer re-runs every prerequisite check itself, and nothing is created
in your cluster or registry until all of them pass.

Required parameters
  --root-domain <domain>          Your SIA environment domain (e.g. cyberark.cloud)
  --idaptive-tenant-id <id>       Identity tenant ID from the SIA Admin Portal
  --tenant-subdomain <name>       Your tenant subdomain
  --connector-pool-id <uuid>      Connector Pool ID from the SIA Admin Portal
  --username <user>               Service-account username
  --registry <host[/path]>        Your container registry

Password (never accepted as a flag value)
  SIA_PASSWORD environment variable, or --password-file <path>,
  or an interactive masked prompt.

Optional
  --namespace <ns>                Default: sia-k8s-connector
  --release <name>                Default: sia-connector
  --replicas <n>                  Default: 1
  --image-name <name>             Default: cms-k8s-connector
  --image-tag <tag>               Default: latest
  --chart-ref <url|file.tgz>      Helm repo URL or a local chart archive
  --chart-version <ver>           Default: newest available
  --pull-secret <name>            Default: sia-registry-creds
  --registry-username <user>      For registries needing docker login
  --registry-password-file <path> Password/token file for the above
  --storage-class <name>          Required if the cluster has no default
  --proxy <url>                   Outbound HTTP/HTTPS proxy for the connector
  --cluster-name <name>           Label connectors as <name>\<pod>; default: k8s
  --platform <os/arch>            Default: linux/amd64
  --kubectl-version <ver>         kubectl embedded in the image; default: v1.30.0
  --base-image <ref>              Image base layer; default: alpine:latest
  --dockerfile-dir <path>         Directory holding the connector Dockerfile
  --config <path>                 Read any of the above as KEY=value
  --log-file <path>               Default: ./sia-connector-install-<timestamp>.log

Behaviour
  --check-only                    Run the prerequisite checks only; change
                                  nothing. Equivalent to running
                                  ./sia-connector-prerequisites.sh
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
# does not recognise is an install-only flag handled here.
# ---------------------------------------------------------------------------
preparse_config "$@"

while [[ $# -gt 0 ]]; do
  if common_parse_arg "$@"; then
    shift "${ARG_SHIFT}"
    continue
  fi
  case "$1" in
    --release)                RELEASE="${2:?}"; shift 2 ;;
    --pull-secret)            PULL_SECRET="${2:?}"; shift 2 ;;
    --cluster-name)           CLUSTER_NAME="${2:?}"; shift 2 ;;
    --kubectl-version)        KUBECTL_VERSION="${2:?}"; shift 2 ;;
    --base-image)             BASE_IMAGE="${2:?}"; shift 2 ;;
    --password-file)          PASSWORD_FILE="${2:?}"; shift 2 ;;
    --check-only)             CHECK_ONLY=true; shift ;;
    --yes|-y)                 ASSUME_YES=true; shift ;;
    -h|--help)                usage; exit 0 ;;
    --password|--password=*)
      die "--password is not accepted: it would be visible in 'ps' and your shell history.
       Use SIA_PASSWORD, --password-file <path>, or the interactive prompt." ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done

setup_transcript "sia-connector-install"
make_tmpdir

log "${C_BOLD}CyberArk SIA Kubernetes Connector — installer v${SIA_TOOLS_VERSION}${C_RESET}"
log "${C_DIM}$(date -u +'%Y-%m-%dT%H:%M:%SZ')  ·  transcript: ${LOG_FILE}${C_RESET}"

# ---------------------------------------------------------------------------
# Resolve the password (before the checks, so they can report on it)
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
# PREREQUISITE CHECKS  (identical to ./sia-connector-prerequisites.sh)
# =============================================================================
run_prerequisite_checks

if (( FAIL_COUNT > 0 )); then
  log ""
  log "${C_RED}Preflight failed — nothing was created.${C_RESET}"
  log "Fix the items marked [FAIL] above and run again."
  log "Transcript: ${LOG_FILE}"
  exit 1
fi

if [[ "${CHECK_ONLY}" == "true" ]]; then
  log ""
  log "${C_GREEN}Preflight passed.${C_RESET} No changes were made (--check-only)."
  (( WARN_COUNT > 0 )) && log "Review the ${WARN_COUNT} warning(s) above before installing."
  log "${C_DIM}These are the same checks ./sia-connector-prerequisites.sh runs, which you${C_RESET}"
  log "${C_DIM}can run on its own, without the installer.${C_RESET}"
  log "Transcript: ${LOG_FILE}"
  exit 0
fi

# =============================================================================
# INSTALL
# =============================================================================
log ""
log "About to install into:"
log "  cluster    $(kubectl config current-context 2>/dev/null)"
log "  namespace  ${NAMESPACE}"
log "  release    ${RELEASE}"
log "  chart      ${CHART_NAME}-${CHART_VERSION}"
log "  image      ${IMAGE_REMOTE}"
log "  replicas   ${REPLICAS}"
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

# --- helm install -----------------------------------------------------------
step "Installing chart ${CHART_NAME}-${CHART_VERSION}"
_helm_args=(
  upgrade --install "${RELEASE}" "${CHART_INSTALL_REF}"
  --namespace "${NAMESPACE}"
  --set connectorPoolId="${CONNECTOR_POOL_ID}"
  --set replicaCount="${REPLICAS}"
  --set image.repository="${REGISTRY}/${IMAGE_NAME}"
  --set image.tag="${IMAGE_TAG}"
  --set image.pullPolicy=Always
)
# A local .tgz carries its own version; --version applies only to repo installs.
chart_is_file || _helm_args+=(--version "${CHART_VERSION}")
[[ "${SKIP_PULL_SECRET}" == "false" ]] && _helm_args+=(--set "imagePullSecrets[0].name=${PULL_SECRET}")
[[ -n "${STORAGE_CLASS}" ]] && _helm_args+=(--set "persistence.storageClass=${STORAGE_CLASS}")
[[ -n "${PROXY_URL}" ]]     && _helm_args+=(--set "proxy=${PROXY_URL}")
[[ -n "${CLUSTER_NAME}" ]]  && _helm_args+=(--set "clusterName=${CLUSTER_NAME}")

helm "${_helm_args[@]}"

# =============================================================================
# VERIFY
# =============================================================================
step "Waiting for the connector to become ready (up to ${ROLLOUT_TIMEOUT}s)"
_rollout_ok=true
kubectl rollout status "statefulset/${RELEASE}" -n "${NAMESPACE}" \
  --timeout="${ROLLOUT_TIMEOUT}s" || _rollout_ok=false

step "Checking connector registration (up to ${REGISTER_TIMEOUT}s)"
_pod="${RELEASE}-0"
_registered=false
_deadline=$(( $(date +%s) + REGISTER_TIMEOUT ))
while (( $(date +%s) < _deadline )); do
  _logs="$(kubectl logs "${_pod}" -n "${NAMESPACE}" -c connector 2>/dev/null || true)"
  if grep -qa 'The Connector is ready' <<< "${_logs}"; then _registered=true; break; fi
  if grep -qaE 'Token request failed|ERROR:' <<< "${_logs}"; then break; fi
  sleep 5
done

log ""
if [[ "${_registered}" == "true" ]]; then
  heading "Installed successfully"
  grep -aE 'registered successfully|Connector Version:|Connected to IoT endpoint|The Connector is ready' \
    <<< "${_logs}" | sed 's/^/  /' | tail -6
  log ""
  log "  release    ${RELEASE}  (revision $(helm list -n "${NAMESPACE}" -o json 2>/dev/null | tr ',' '\n' | sed -n 's/.*"revision":"\([0-9]*\)".*/\1/p' | head -1))"
  log "  namespace  ${NAMESPACE}"
  log "  chart      ${CHART_NAME}-${CHART_VERSION}"
  log "  image      $(kubectl get pod "${_pod}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null)"
  log ""
  log "  In the SIA Admin Portal, the connector should now appear Online in pool"
  log "  ${CONNECTOR_POOL_ID} as ${CLUSTER_NAME:-k8s}\\${_pod}."
  log ""
  log "  Transcript: ${LOG_FILE}"
  exit 0
fi

# --- targeted diagnosis -----------------------------------------------------
heading "The connector did not report ready"
log "  The chart installed, but the connector has not registered. Most likely cause:"
log ""
_events="$(kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | tail -15 || true)"

if grep -qa 'access_denied\|HTTP 400' <<< "${_logs}"; then
  log "  ${C_BOLD}Credentials were rejected.${C_RESET} The identity service returned access_denied."
  log "  The username or password is wrong — tenant IDs were validated in preflight."
  log "  Update just the credential, without reinstalling:"
  log "    kubectl delete secret ${SECRET_NAME} -n ${NAMESPACE}"
  log "    # re-run this script; it will recreate the secret and restart the pod"
elif grep -qaE 'HTTP 401|HTTP 403' <<< "${_logs}"; then
  log "  ${C_BOLD}Authenticated, but not authorised.${C_RESET} The service account signed in but"
  log "  cannot provision connectors. Check its role in the SIA Admin Portal."
elif grep -qa 'ROOT_DOMAIN not set' <<< "${_logs}"; then
  log "  ${C_BOLD}The image has no ROOT_DOMAIN baked in.${C_RESET} Rebuild without --skip-build."
elif grep -qa 'no match for platform' <<< "${_events}${_logs}"; then
  log "  ${C_BOLD}Architecture mismatch.${C_RESET} The image does not match the nodes."
  log "    rebuild with --platform linux/<node arch> and re-run"
elif grep -qa 'ImagePullBackOff\|ErrImagePull' <<< "${_events}"; then
  log "  ${C_BOLD}The node cannot pull the image.${C_RESET} The pull secret is missing, wrong,"
  log "  or its registry token has expired (ECR tokens last 12 hours)."
  log "    re-run this script to refresh ${PULL_SECRET}, then:"
  log "    kubectl rollout restart statefulset/${RELEASE} -n ${NAMESPACE}"
elif kubectl get pvc -n "${NAMESPACE}" 2>/dev/null | grep -qa Pending; then
  log "  ${C_BOLD}The volume never bound.${C_RESET} No usable StorageClass."
  log "    re-run with --storage-class <name>   (EKS Auto Mode: gp3-auto)"
elif [[ "${_rollout_ok}" == "false" ]]; then
  log "  ${C_BOLD}The pod never became ready.${C_RESET} Inspect it directly:"
  log "    kubectl describe pod ${_pod} -n ${NAMESPACE}"
else
  log "  ${C_BOLD}No token response and no error.${C_RESET} This usually means the nodes cannot"
  log "  reach your SIA environment. Probe from inside the cluster:"
  log "    kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -n ${NAMESPACE} \\"
  log "      -- curl -sv --max-time 15 https://${IDAPTIVE_TENANT_ID}.id.${ROOT_DOMAIN}"
  log "  If egress requires a proxy, re-run this script with --proxy <url>."
fi

log ""
log "  Full logs:   kubectl logs ${_pod} -n ${NAMESPACE} -c connector"
log "  Pod events:  kubectl describe pod ${_pod} -n ${NAMESPACE}"
log "  Transcript:  ${LOG_FILE}   (safe to attach to a support ticket)"
exit 1
