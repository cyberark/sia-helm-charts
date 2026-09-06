#!/usr/bin/env bash
# =============================================================================
# CyberArk SIA Kubernetes Connector — prerequisites and preparation (Azure)
#
# The Azure counterpart of sia-connector-prerequisites.sh: same checks, same
# preparation steps, same output, with Azure Container Registry and AKS in place
# of Amazon ECR and EKS.
#
# Gets your environment completely ready to release the connector, and stops
# deliberately short of the release itself:
#
#     ./sia-connector-prerequisites-azure.sh --config ./sia-connector.env
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
# This script is self-contained: it needs no other file from this distribution
# except the connector build context and the chart archive, both of which it
# finds in your working copy. See PREREQUISITES.md for what each check means.
# =============================================================================

set -euo pipefail
umask 077

SIA_TOOLS_VERSION="1.1.0"
SIA_CLOUD="Azure"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAMESPACE="sia-k8s-connector"
REPLICAS="1"
IMAGE_NAME="cms-k8s-connector"
IMAGE_TAG="latest"
PLATFORM="linux/amd64"
CHART_NAME="sia-connector"
CHART_REPO_NAME="sia-helm-charts"
# No default. The chart ships in this distribution alongside the scripts, so it
# is located in the working copy by resolve_chart_ref — the same way the
# connector build context is. Pass --chart-ref to override with either another
# archive or a Helm repository URL.
CHART_REF=""

PULL_SECRET="sia-registry-creds"
SECRET_NAME="sia-auth"
KUBECTL_VERSION="v1.30.0"
BASE_IMAGE="alpine:latest"
PASSWORD_FILE=""
SIA_PASSWORD="${SIA_PASSWORD:-}"

# Required — no defaults
ROOT_DOMAIN=""
IDAPTIVE_TENANT_ID=""
TENANT_SUBDOMAIN=""
CONNECTOR_POOL_ID=""
SIA_USERNAME=""
REGISTRY=""

# Optional — empty means "not set"
CHART_VERSION=""
STORAGE_CLASS=""
PROXY_URL=""
REGISTRY_USERNAME=""
REGISTRY_PASSWORD_FILE=""
CONFIG_FILE=""
LOG_FILE=""
DOCKERFILE_DIR=""

# Behaviour
CHECK_ONLY=false
SKIP_BUILD=false
SKIP_PULL_SECRET=false
SKIP_EGRESS_CHECK=false
ASSUME_YES=false

# This script creates the sia-auth secret, so the checks report on the
# credential that is about to go into it.
WANT_PASSWORD=true

# Derived during the checks
IMAGE_LOCAL=""
IMAGE_REMOTE=""
CHART_INSTALL_REF=""
CHART_REF_AUTO=false

# Internal state
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
TMPDIR_SELF=""
EGRESS_POD=""
EGRESS_POD_NS=""
CLUSTER_REACHABLE=false

usage() {
  cat <<'EOF'
CyberArk SIA Kubernetes Connector — prerequisites and preparation (Azure)

Validates your environment, then builds and publishes the connector image and
creates the namespace and secrets — everything the connector needs except the
Helm release itself, which is left to you.

  ./sia-connector-prerequisites-azure.sh --config ./sia-connector.env --check-only
  ./sia-connector-prerequisites-azure.sh --config ./sia-connector.env

Nothing is created in your cluster or registry until every check passes, and
you are asked to confirm first. Exits 0 on success, 1 on failure.

Required parameters
  --root-domain <domain>          Your SIA environment domain (e.g. cyberark.cloud)
  --idaptive-tenant-id <id>       Identity tenant ID from the SIA Admin Portal
  --tenant-subdomain <name>       Your tenant subdomain
  --connector-pool-id <uuid>      Connector Pool ID from the SIA Admin Portal
  --username <user>               Service-account username
  --registry <host[/path]>        Your container registry. For ACR:
                                  <name>.azurecr.io

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
  --registry-username <user>      For registries needing docker login. On Azure,
                                  a service principal's app ID gives a pull
                                  secret that outlives an ACR access token
  --registry-password-file <path> Password/token file for the above
  --chart-ref <url|file.tgz>      A chart archive or a Helm repo URL. Omit it and
                                  the newest archive in this distribution is used
  --chart-version <ver>           Default: newest available
  --storage-class <name>          Required if the cluster has no default
                                  (AKS: managed-csi, or managed-csi-premium)
  --proxy <url>                   Outbound HTTP/HTTPS proxy for the connector
  --platform <os/arch>            Default: linux/amd64; checked against your nodes
  --kubectl-version <ver>         kubectl embedded in the image; default: v1.30.0
  --base-image <ref>              Image base layer; default: alpine:latest
  --dockerfile-dir <path>         Directory holding the connector Dockerfile
  --config <path>                 Read any of the above as KEY=value
  --log-file <path>               Default: ./sia-connector-prerequisites-azure-<timestamp>.log

Behaviour
  --check-only                    Run the checks only; change nothing
  --skip-build                    Image is already built and pushed
  --skip-pull-secret              Registry is public, the secret already exists,
                                  or the AKS cluster is attached to the registry
  --skip-egress-check             Do not create the throwaway connectivity-probe pod
  --yes                           Non-interactive; never prompt
  -h, --help                      This message
EOF
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""
fi

log()      { printf '%s\n' "$*"; }
heading()  { printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }
ok()       { PASS_COUNT=$((PASS_COUNT+1)); printf '  %s[ OK ]%s %-42s %s\n' "${C_GREEN}" "${C_RESET}" "$1" "${2:-}"; }
warn()     { WARN_COUNT=$((WARN_COUNT+1)); printf '  %s[WARN]%s %-42s %s\n' "${C_YELLOW}" "${C_RESET}" "$1" "${2:-}"; }
fail()     { FAIL_COUNT=$((FAIL_COUNT+1)); printf '  %s[FAIL]%s %-42s %s\n' "${C_RED}"   "${C_RESET}" "$1" "${2:-}"; }
skip()     { printf '  %s[SKIP]%s %-42s %s\n' "${C_DIM}" "${C_RESET}" "$1" "${2:-}"; }
info()     { printf '         %s%s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
step()     { printf '\n%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
die()      { printf '\n%sERROR:%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }

# The egress probe is the one thing here that creates anything during the
# checks, so it is removed again on exit, including on Ctrl-C.
cleanup() {
  local rc=$?
  if [[ -n "${EGRESS_POD}" && -n "${EGRESS_POD_NS}" ]]; then
    kubectl delete pod "${EGRESS_POD}" -n "${EGRESS_POD_NS}" --ignore-not-found \
      --wait=false >/dev/null 2>&1 || true
  fi
  [[ -n "${TMPDIR_SELF}" && -d "${TMPDIR_SELF}" ]] && rm -rf "${TMPDIR_SELF}"
  return $rc
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Numeric compare of dotted versions: ver_ge 3.10.1 3.10 -> true
ver_ge() {
  local a="${1#v}" b="${2#v}"
  [[ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -1)" == "$b" ]]
}

confirm() {
  local prompt="$1"
  [[ "${ASSUME_YES}" == "true" ]] && return 0
  # `[[ -r /dev/tty ]]` is not enough: in a pipeline or CI job the device node
  # exists and tests readable while not actually being connected, and the read
  # then fails with a bare "Device not configured" from bash instead of the
  # message below. Opening it is the only honest test — and it has to happen
  # inside a group whose stderr is already redirected, because bash reports a
  # failed redirection before any guard of ours can run.
  if ! { true </dev/tty; } 2>/dev/null; then
    die "cannot prompt for confirmation and --yes was not given.
       Re-run with --yes, or from a terminal."
  fi
  local reply=""
  read -rp "${prompt} [y/N] " reply </dev/tty || reply=""
  [[ "${reply}" == "y" || "${reply}" == "Y" ]]
}

# ---------------------------------------------------------------------------
# Azure Container Registry helpers. One hostname family, in four clouds:
#
#   <name>.azurecr.io    public          <name>.azurecr.cn   China
#   <name>.azurecr.us    US Government   <name>.azurecr.de   (retired)
#
# Unlike ECR and Artifact Registry, ACR creates a repository on first push, so
# there is nothing to pre-create — only the registry itself has to exist.
# ---------------------------------------------------------------------------
is_acr()  { [[ "${REGISTRY}" =~ ^[a-zA-Z0-9]+\.azurecr\.(io|cn|us)(/|$) ]]; }
acr_name() { local _h="${REGISTRY%%/*}"; printf '%s' "${_h%%.*}"; }

# The token issued by `az acr login --expose-token` is presented under this
# well-known username. It is not a placeholder — ACR requires exactly this GUID.
ACR_TOKEN_USER="00000000-0000-0000-0000-000000000000"

chart_is_file() { [[ "${CHART_REF}" == *.tgz ]]; }

make_tmpdir() { TMPDIR_SELF="$(mktemp -d)"; return 0; }

resolve_image_refs() {
  IMAGE_LOCAL="${IMAGE_NAME}:${IMAGE_TAG}"
  [[ -n "${REGISTRY}" ]] && IMAGE_REMOTE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
  return 0
}

# The chart is delivered in this distribution, so find it the way the Dockerfile
# is found rather than fetching it over the network. A working copy can hold
# several versions; take the newest by version order, not by filename order,
# which would put 1.0.9 above 1.0.24.
resolve_chart_ref() {
  local _d="" _list="" _found=""
  [[ -n "${CHART_REF}" ]] && return 0
  for _d in "./sia-k8s-connector" "../sia-k8s-connector" "."; do
    _list="$(printf '%s\n' "${_d}"/${CHART_NAME}-*.tgz)"
    # A glob that matches nothing comes back as the literal pattern.
    [[ "${_list}" == *'*'* ]] && continue
    _found="$(printf '%s\n' "${_list}" | sort -V | tail -1)"
    if [[ -n "${_found}" && -f "${_found}" ]]; then
      CHART_REF="${_found}"
      CHART_REF_AUTO=true
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
# Read --config before the main parse loop, so explicit flags win regardless
# of the order they were given in.
preparse_config() {
  [[ $# -gt 0 ]] || return 0
  local _args=("$@")
  local i
  for ((i=0; i<${#_args[@]}; i++)); do
    if [[ "${_args[i]}" == "--config" ]]; then
      CONFIG_FILE="${_args[i+1]:-}"
      [[ -n "${CONFIG_FILE}" ]] || die "--config needs a path"
      [[ -f "${CONFIG_FILE}" ]] || die "config file not found: ${CONFIG_FILE}"
      # Config files get copied, shared and committed. Keep the promise that this
      # one never holds the credential, rather than silently honouring it.
      if grep -qE '^[[:space:]]*(export[[:space:]]+)?SIA_PASSWORD=' "${CONFIG_FILE}"; then
        die "${CONFIG_FILE} assigns SIA_PASSWORD.
       Config files are easy to share or commit by accident, so the password is not
       read from one. With --check-only no password is needed at all. Remove that
       line; a credential is supplied at install time by an interactive prompt, by
       --password-file <path> (a file only you can read), or by the SIA_PASSWORD
       environment variable for CI."
      fi
      # shellcheck disable=SC1090
      set -a; source "${CONFIG_FILE}"; set +a
    fi
  done
  return 0
}

preparse_config "$@"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-domain)            ROOT_DOMAIN="${2:?}"; shift 2 ;;
    --idaptive-tenant-id)     IDAPTIVE_TENANT_ID="${2:?}"; shift 2 ;;
    --tenant-subdomain)       TENANT_SUBDOMAIN="${2:?}"; shift 2 ;;
    --connector-pool-id)      CONNECTOR_POOL_ID="${2:?}"; shift 2 ;;
    --username)               SIA_USERNAME="${2:?}"; shift 2 ;;
    --registry)               REGISTRY="${2:?}"; shift 2 ;;
    --namespace)              NAMESPACE="${2:?}"; shift 2 ;;
    --replicas)               REPLICAS="${2:?}"; shift 2 ;;
    --image-name)             IMAGE_NAME="${2:?}"; shift 2 ;;
    --image-tag)              IMAGE_TAG="${2:?}"; shift 2 ;;
    --chart-ref)              CHART_REF="${2:?}"; shift 2 ;;
    --chart-version)          CHART_VERSION="${2:?}"; shift 2 ;;
    --registry-username)      REGISTRY_USERNAME="${2:?}"; shift 2 ;;
    --registry-password-file) REGISTRY_PASSWORD_FILE="${2:?}"; shift 2 ;;
    --storage-class)          STORAGE_CLASS="${2:?}"; shift 2 ;;
    --proxy)                  PROXY_URL="${2:?}"; shift 2 ;;
    --platform)               PLATFORM="${2:?}"; shift 2 ;;
    --dockerfile-dir)         DOCKERFILE_DIR="${2:?}"; shift 2 ;;
    --log-file)               LOG_FILE="${2:?}"; shift 2 ;;
    --pull-secret)            PULL_SECRET="${2:?}"; shift 2 ;;
    --kubectl-version)        KUBECTL_VERSION="${2:?}"; shift 2 ;;
    --base-image)             BASE_IMAGE="${2:?}"; shift 2 ;;
    --password-file)          PASSWORD_FILE="${2:?}"; shift 2 ;;
    --config)                 shift 2 ;;   # already consumed by preparse_config
    --skip-build)             SKIP_BUILD=true; shift ;;
    --skip-pull-secret)       SKIP_PULL_SECRET=true; shift ;;
    --skip-egress-check)      SKIP_EGRESS_CHECK=true; shift ;;
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

# ---------------------------------------------------------------------------
# Transcript. Passwords are never written to stdout, so the log is safe to send,
# but redact defensively in case a subcommand echoes something unexpected.
# ---------------------------------------------------------------------------
setup_transcript() {
  local _prefix="$1"
  if [[ -z "${LOG_FILE}" ]]; then
    LOG_FILE="./${_prefix}-$(date -u +%Y%m%dT%H%M%SZ).log"
  fi
  exec > >(tee >(sed -E 's/(password|token|secret)=[^ ]*/\1=<redacted>/gi' > "${LOG_FILE}")) 2>&1
  return 0
}

setup_transcript "sia-connector-prerequisites-azure"
make_tmpdir

log "${C_BOLD}CyberArk SIA Kubernetes Connector — prerequisites (${SIA_CLOUD}) v${SIA_TOOLS_VERSION}${C_RESET}"
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
#
# Every check function ends with an explicit `return 0`. Several of them close
# with `[[ -n "$X" ]] && ok …`, which evaluates to false when X is empty. At
# top level bash exempts that from `set -e`; as a function's return value it
# would abort the script.
# =============================================================================

check_required() {
  local name="$1" value="$2"
  if [[ -z "${value}" ]]; then
    fail "${name}" "missing — required"
  elif [[ "${value}" == *'{{'* || "${value}" == *'<'*'>'* ]]; then
    fail "${name}" "still a placeholder: ${value}"
  else
    ok "${name}" "${value}"
  fi
  return 0
}

check_parameters() {
  heading "Preflight — parameters"

  check_required "root domain"        "${ROOT_DOMAIN}"
  check_required "identity tenant ID" "${IDAPTIVE_TENANT_ID}"
  check_required "tenant subdomain"   "${TENANT_SUBDOMAIN}"
  check_required "connector pool ID"  "${CONNECTOR_POOL_ID}"
  check_required "service account"    "${SIA_USERNAME}"
  check_required "registry"           "${REGISTRY}"

  if [[ -n "${ROOT_DOMAIN}" && ! "${ROOT_DOMAIN}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]; then
    fail "root domain format" "'${ROOT_DOMAIN}' does not look like a domain"
  elif [[ -n "${ROOT_DOMAIN}" ]]; then
    ok "root domain format" "identity: ${IDAPTIVE_TENANT_ID}.id.${ROOT_DOMAIN}"
    info "api:      ${TENANT_SUBDOMAIN}.dpa.${ROOT_DOMAIN}/api"
  fi

  if [[ ! "${REPLICAS}" =~ ^[0-9]+$ ]] || (( REPLICAS < 1 )); then
    fail "replicas" "must be a positive integer, got '${REPLICAS}'"
  else
    ok "replicas" "${REPLICAS}"
  fi

  if [[ "${WANT_PASSWORD}" == "true" ]]; then
    local _pw="${SIA_PASSWORD:-}"
    if [[ "${CHECK_ONLY}" == "true" && -z "${_pw}" ]]; then
      skip "password" "not required for --check-only"
    elif [[ -z "${_pw}" ]]; then
      fail "password" "empty"
    else
      ok "password" "supplied (${#_pw} characters, not shown)"
    fi
  fi

  resolve_image_refs
  [[ -n "${IMAGE_REMOTE}" ]] && ok "image reference" "${IMAGE_REMOTE}"
  [[ -n "${PROXY_URL}" ]] && ok "outbound proxy" "${PROXY_URL}"
  return 0
}

check_tooling() {
  heading "Preflight — tooling"
  local _kv="" _hv="" _t="" _c="" _plugin=""

  if ! have kubectl; then
    fail "kubectl" "not found"
  else
    _kv="$(kubectl version --client -o json 2>/dev/null \
            | sed -n 's/.*"gitVersion": *"v\([0-9.]*\)".*/\1/p' | head -1)"
    [[ -z "${_kv}" ]] && _kv="$(kubectl version --client 2>/dev/null | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p' | head -1)"
    if [[ -n "${_kv}" ]] && ver_ge "${_kv}" "1.24"; then ok "kubectl" "v${_kv}"
    elif [[ -n "${_kv}" ]]; then fail "kubectl" "v${_kv} — 1.24 or newer required"
    else warn "kubectl" "present, version undetermined"; fi
  fi

  if ! have helm; then
    fail "helm" "not found"
  else
    _hv="$(helm version --template '{{.Version}}' 2>/dev/null | sed 's/^v//')"
    [[ -z "${_hv}" ]] && _hv="$(helm version --short 2>/dev/null | sed 's/^v//; s/+.*//')"
    if [[ -n "${_hv}" ]] && ver_ge "${_hv}" "3.10"; then
      ok "helm" "v${_hv}"
      [[ "${_hv%%.*}" -ge 4 ]] && info "helm 4 detected — supported"
    elif [[ -n "${_hv}" ]]; then fail "helm" "v${_hv} — 3.10 or newer required"
    else warn "helm" "present, version undetermined"; fi
  fi

  if [[ "${SKIP_BUILD}" == "true" ]]; then
    skip "docker" "--skip-build given"
  elif ! have docker; then
    fail "docker" "not found — needed to build the image"
  elif ! docker info >/dev/null 2>&1; then
    fail "docker daemon" "installed but not responding — is Docker running?"
  else
    ok "docker" "daemon responding ($(docker info --format '{{.ServerVersion}}' 2>/dev/null))"
  fi

  for _t in curl base64; do
    have "${_t}" && ok "${_t}" "present" || fail "${_t}" "not found"
  done

  if is_acr; then
    if have az; then ok "az cli" "present (registry is Azure Container Registry)"
    else fail "az cli" "not found, but the registry is Azure Container Registry"; fi
  fi

  # An Entra-integrated AKS kubeconfig authenticates through kubelogin. Without
  # the binary on PATH kubectl fails with "no Auth Provider found for name azure"
  # or a missing exec plugin, which reads like a cluster fault rather than a
  # missing local component. Only complained about if this kubeconfig asks for it.
  _plugin="$(kubectl config view -o jsonpath='{.users[*].user.exec.command}' 2>/dev/null || true)"
  if [[ "${_plugin}" == *kubelogin* ]]; then
    if have kubelogin; then
      ok "kubelogin" "present"
    else
      fail "kubelogin" "required by this kubeconfig but not found"
      info "install it, then re-run:"
      info "  az aks install-cli        (installs kubectl and kubelogin)"
      info "  (or: brew install Azure/kubelogin/kubelogin)"
    fi
  fi

  # Dockerfile location
  if [[ "${SKIP_BUILD}" == "true" ]]; then
    skip "connector Dockerfile" "--skip-build given"
  else
    if [[ -z "${DOCKERFILE_DIR}" ]]; then
      for _c in "./sia-k8s-connector/docker" "../sia-k8s-connector/docker" "./docker"; do
        [[ -f "${_c}/Dockerfile" ]] && { DOCKERFILE_DIR="${_c}"; break; }
      done
    fi
    if [[ -n "${DOCKERFILE_DIR}" && -f "${DOCKERFILE_DIR}/Dockerfile" ]]; then
      ok "connector Dockerfile" "${DOCKERFILE_DIR}/Dockerfile"
    else
      fail "connector Dockerfile" "not found in the current directory or --dockerfile-dir"
      info "The image is built locally because your environment's domain is compiled into"
      info "it, so this script needs the connector build context (a Dockerfile plus"
      info "entrypoint.sh and connector-aliases.sh) from CyberArk."
      info "Obtain it from the sia-helm-charts distribution, then either:"
      info "  * run this script from the root of that distribution, or"
      info "  * pass --dockerfile-dir <path-to-sia-k8s-connector/docker>"
    fi
  fi
  return 0
}

check_cluster() {
  heading "Preflight — cluster"
  local _ctx="" _srv="" _perm_fail=false _verb="" _res="" _scope="" _allowed=""
  local _want_arch="" _arches="" _default_sc="" _binding="" _existing=""

  if ! kubectl version -o json >/dev/null 2>&1 && ! kubectl cluster-info >/dev/null 2>&1; then
    fail "cluster reachable" "kubectl cannot reach the API server"
    info "check KUBECONFIG — note that \"KUBECONFIG=~/path\" in double quotes does NOT"
    info "expand the tilde; use \"\$HOME/path\" instead"
    info "for AKS, refresh the context with:"
    info "  az aks get-credentials --resource-group <group> --name <cluster>"
    return 0
  fi

  _ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  _srv="$(kubectl version -o json 2>/dev/null \
           | sed -n 's/.*"gitVersion": *"v\([0-9.]*\)".*/\1/p' | tail -1)"
  ok "cluster reachable" "server v${_srv:-?}"
  CLUSTER_REACHABLE=true
  printf '         %sTARGET CLUSTER: %s%s%s\n' "${C_DIM}" "${C_BOLD}" "${_ctx}" "${C_RESET}"
  if [[ -n "${_srv}" ]] && ! ver_ge "${_srv}" "1.24"; then
    fail "kubernetes version" "v${_srv} — 1.24 or newer required"
  fi

  # Permissions. The chart creates a cluster-scoped ClusterRole, so namespace
  # rights alone are not enough and the shortfall only shows up mid-install.
  while read -r _verb _res _scope; do
    if [[ "${_scope}" == "ns" ]]; then
      _allowed="$(kubectl auth can-i "${_verb}" "${_res}" -n "${NAMESPACE}" 2>/dev/null || echo no)"
    else
      _allowed="$(kubectl auth can-i "${_verb}" "${_res}" 2>/dev/null || echo no)"
    fi
    [[ "${_allowed}" == "yes" ]] || { fail "rbac: ${_verb} ${_res}" "denied"; _perm_fail=true; }
  done <<'PERMS'
create namespaces cluster
create clusterroles cluster
create secrets ns
create statefulsets ns
PERMS
  [[ "${_perm_fail}" == "false" ]] && ok "rbac" "can create namespace, clusterrole, secret, statefulset"

  # Node architecture vs --platform. Catches the mismatch that would otherwise
  # surface much later as Init:ErrImagePull / "no match for platform".
  _want_arch="${PLATFORM##*/}"
  _arches="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' 2>/dev/null | sort -u | tr '\n' ' ')"
  _arches="${_arches% }"
  if [[ -z "${_arches}" ]]; then
    warn "node architecture" "could not read node info"
  elif [[ " ${_arches} " == *" ${_want_arch} "* ]]; then
    ok "node architecture" "${_arches} matches --platform ${PLATFORM}"
    [[ "${_arches}" == *" "* ]] && info "mixed-architecture cluster: pin scheduling or the pod may land on an incompatible node"
  else
    fail "node architecture" "nodes are '${_arches}', image would be built for '${_want_arch}'"
    info "rebuild with: --platform linux/${_arches%% *}"
  fi

  # Storage. Without a default class and without an explicit one, the PVC is
  # created with no storageClassName and never binds.
  _default_sc="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)"
  if [[ -n "${STORAGE_CLASS}" ]]; then
    if kubectl get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then
      ok "storage class" "${STORAGE_CLASS} (explicit)"
      _binding="$(kubectl get storageclass "${STORAGE_CLASS}" -o jsonpath='{.volumeBindingMode}' 2>/dev/null)"
      [[ "${_binding}" == "WaitForFirstConsumer" ]] && info "WaitForFirstConsumer: a briefly Pending PVC is normal, not a failure"
    else
      warn "storage class" "'${STORAGE_CLASS}' not present — the chart will try to create it"
    fi
  elif [[ -n "${_default_sc}" ]]; then
    ok "storage class" "cluster default: ${_default_sc}"
    _binding="$(kubectl get storageclass "${_default_sc}" -o jsonpath='{.volumeBindingMode}' 2>/dev/null)"
    [[ "${_binding}" == "WaitForFirstConsumer" ]] && info "WaitForFirstConsumer: a briefly Pending PVC is normal, not a failure"
  else
    fail "storage class" "no default StorageClass and --storage-class not given"
    info "the connector's PVC would never bind. On AKS the class you want is:"
    info "  --storage-class managed-csi       (managed-csi-premium for SSD)"
    info "AKS normally ships a default class, so a cluster with none has had it"
    info "removed or unmarked."
  fi

  # Advisory only.
  if kubectl get apiservices 2>/dev/null | grep -q 'metrics\.k8s\.io'; then
    ok "metrics-server" "present — autoscaling metrics available"
  else
    warn "metrics-server" "absent — the chart's HPA will report <unknown>"
    info "harmless: the StatefulSet still runs at --replicas. Disable with:"
    info "  --set autoscaling.enabled=false  (see README)"
  fi

  # Existing release in the target namespace.
  _existing="$(helm list -n "${NAMESPACE}" -o json 2>/dev/null \
                | tr ',' '\n' | sed -n 's/.*"chart":"'"${CHART_NAME}"'-\([0-9][0-9.]*\)".*/\1/p' | head -1)"
  if [[ -z "${_existing}" ]]; then
    ok "existing release" "none in ${NAMESPACE} — this is a fresh install"
  else
    if [[ -n "${CHART_VERSION}" && "${_existing}" == "${CHART_VERSION}" ]]; then
      warn "existing release" "${CHART_NAME}-${_existing} already installed — this reinstalls it"
    elif [[ -n "${CHART_VERSION}" ]] && ver_ge "${CHART_VERSION}" "${_existing}"; then
      ok "existing release" "${CHART_NAME}-${_existing} → ${CHART_VERSION} (upgrade)"
    elif [[ -n "${CHART_VERSION}" ]]; then
      warn "existing release" "${CHART_NAME}-${_existing} → ${CHART_VERSION} is a DOWNGRADE"
    else
      warn "existing release" "${CHART_NAME}-${_existing} installed; target version not pinned"
    fi
  fi
  return 0
}

check_chart_source() {
  heading "Preflight — chart source"
  local _cv="" _versions=""

  resolve_chart_ref

  if [[ -z "${CHART_REF}" ]]; then
    fail "chart source" "no chart archive found, and --chart-ref was not given"
    info "the chart ships in this distribution as sia-k8s-connector/${CHART_NAME}-<version>.tgz."
    info "Either run this script from the root of your working copy, so it is found"
    info "automatically, or name it explicitly:"
    info "  --chart-ref ./sia-k8s-connector/${CHART_NAME}-<version>.tgz"
    info "A Helm repository URL also works, if you publish the chart internally."
    return 0
  fi

  if chart_is_file; then
    if [[ -f "${CHART_REF}" ]] && helm show chart "${CHART_REF}" >/dev/null 2>&1; then
      _cv="$(helm show chart "${CHART_REF}" 2>/dev/null | sed -n 's/^version: *//p' | head -1)"
      ok "chart archive" "${CHART_REF} (version ${_cv})"
      [[ "${CHART_REF_AUTO}" == "true" ]] && info "found in this distribution; --chart-ref selects a different one"
      CHART_INSTALL_REF="${CHART_REF}"
      [[ -z "${CHART_VERSION}" ]] && CHART_VERSION="${_cv}"
    else
      fail "chart archive" "not found or not a valid chart: ${CHART_REF}"
    fi
  else
    if helm repo add "${CHART_REPO_NAME}" "${CHART_REF}" --force-update >/dev/null 2>&1 \
       && helm repo update "${CHART_REPO_NAME}" >/dev/null 2>&1; then
      _versions="$(helm search repo "${CHART_REPO_NAME}/${CHART_NAME}" --versions 2>/dev/null \
                    | awk 'NR>1 {print $2}' | tr '\n' ' ')"
      if [[ -z "${_versions}" ]]; then
        fail "chart repository" "reachable but contains no ${CHART_NAME} chart"
      else
        ok "chart repository" "${CHART_REF}"
        info "available versions: ${_versions}"
        if [[ -z "${CHART_VERSION}" ]]; then
          CHART_VERSION="${_versions%% *}"
          info "no --chart-version given; using newest: ${CHART_VERSION}"
        elif [[ " ${_versions} " != *" ${CHART_VERSION} "* ]]; then
          fail "chart version" "${CHART_VERSION} not available in this repository"
        fi
        CHART_INSTALL_REF="${CHART_REPO_NAME}/${CHART_NAME}"
      fi
    else
      fail "chart repository" "cannot read an index from ${CHART_REF}"
      info "a Helm repository must serve index.yaml at the URL you provide. Likely causes:"
      info "  * this machine cannot reach the URL — a proxy or egress firewall is the"
      info "    usual cause in a corporate network. Check with: curl -sI <url>index.yaml"
      info "  * the URL points one level above the directory holding index.yaml"
      info "  * the repository requires credentials this machine does not have"
      info "The reliable path is the chart archive that ships in this distribution:"
      info "  --chart-ref ./sia-k8s-connector/${CHART_NAME}-<version>.tgz"
      info "Leaving --chart-ref off entirely finds it automatically when you run this"
      info "from the root of your working copy."
      info "Verify an archive before using it:  helm show chart <file>.tgz"
    fi
  fi
  return 0
}

check_registry() {
  heading "Preflight — registry"
  local _acr="" _sub="" _login="" _sku="" _public=""

  if [[ "${SKIP_BUILD}" == "true" && "${SKIP_PULL_SECRET}" == "true" ]]; then
    skip "registry auth" "--skip-build and --skip-pull-secret given"
  elif [[ -z "${REGISTRY}" ]]; then
    # check_required has already failed this parameter. Advising "docker login"
    # with no host would put a command nobody can run into a transcript people
    # are told to attach to support tickets.
    skip "registry auth" "no registry set — see the failure above"
  elif [[ -n "${REGISTRY_USERNAME}" ]]; then
    # Checked before the az path: an explicitly supplied credential is a
    # deliberate choice, and on Azure it is the longer-lived one — an ACR access
    # token lasts about three hours, a service principal's secret does not.
    if [[ -n "${REGISTRY_PASSWORD_FILE}" && -f "${REGISTRY_PASSWORD_FILE}" ]]; then
      ok "registry auth" "docker login as ${REGISTRY_USERNAME}"
      info "a service principal with AcrPush keeps working, so the pull secret does too"
    else
      fail "registry auth" "--registry-username given without a readable --registry-password-file"
    fi
  elif is_acr; then
    _acr="$(acr_name)"
    if ! have az; then
      fail "registry auth" "az cli required for Azure Container Registry"
    else
      _sub="$(az account show --query id -o tsv 2>/dev/null || true)"
      if [[ -z "${_sub}" ]]; then
        fail "azure credentials" "not authenticated — try 'az login'"
      else
        _login="$(az acr show --name "${_acr}" --query loginServer -o tsv 2>/dev/null || true)"
        if [[ -z "${_login}" ]]; then
          fail "acr registry" "'${_acr}' not visible in subscription ${_sub}"
          info "check the active subscription — it is easy to inherit one that targets a"
          info "different tenant:"
          info "  az account list --output table"
          info "  az account set --subscription <id>"
        else
          ok "azure subscription" "${_sub} can see ${_login}"
          if [[ "${_login}" != "${REGISTRY%%/*}" ]]; then
            warn "acr login server" "registry reports ${_login}, --registry says ${REGISTRY%%/*}"
          fi
          _sku="$(az acr show --name "${_acr}" --query sku.name -o tsv 2>/dev/null || true)"
          [[ -n "${_sku}" ]] && ok "acr sku" "${_sku}"
          _public="$(az acr show --name "${_acr}" --query publicNetworkAccess -o tsv 2>/dev/null || true)"
          if [[ "${_public}" == "Disabled" ]]; then
            warn "acr public access" "disabled — this machine needs a private endpoint to push"
          fi
          # ACR creates a repository on first push, so unlike ECR and Artifact
          # Registry there is nothing to pre-create here.
          ok "acr repository" "${IMAGE_NAME} — created on first push"
          info "ACR access tokens expire after about 3 hours, so a pull secret built from"
          info "one stops working long before the connector does. Two durable alternatives:"
          info "  * attach the registry to the cluster once, then --skip-pull-secret:"
          info "      az aks update -n <cluster> -g <group> --attach-acr ${_acr}"
          info "  * a service principal with AcrPull, via --registry-username <appId>"
          info "    and --registry-password-file <secret-file>"
        fi
      fi
    fi
  else
    warn "registry auth" "no credentials given — assuming this machine is already logged in"
    info "if the push fails, run: docker login ${REGISTRY%%/*}"
  fi
  return 0
}

# Egress probe. Node egress cannot be tested from this machine, and a blocked
# network is a common cause of an install that looks fine until registration.
check_egress() {
  heading "Preflight — connectivity from inside the cluster"
  local _probe_ns="" _proxy_arg="" _script="" _out="" _blocked=false _seen="" _url="" _code=""
  local _v=""

  if [[ "${SKIP_EGRESS_CHECK}" == "true" ]]; then
    skip "egress probe" "--skip-egress-check given"
    return 0
  fi
  # This probe needs a reachable cluster and well-formed tenant parameters, and
  # nothing else. Gating it on the total failure count instead would throw away
  # the one check that cannot be run from this machine whenever something
  # unrelated — a chart reference, a registry credential — happened to be wrong,
  # which is exactly when an answer about egress is most worth having.
  if [[ "${CLUSTER_REACHABLE}" != "true" ]]; then
    skip "egress probe" "cluster unreachable; not creating a probe pod"
    return 0
  fi
  if [[ -z "${ROOT_DOMAIN}" || -z "${IDAPTIVE_TENANT_ID}" || -z "${TENANT_SUBDOMAIN}" ]]; then
    skip "egress probe" "tenant parameters incomplete"
    return 0
  fi
  # A placeholder would resolve to nothing and report as blocked egress, sending
  # someone to their network team over an unedited config file.
  for _v in "${ROOT_DOMAIN}" "${IDAPTIVE_TENANT_ID}" "${TENANT_SUBDOMAIN}"; do
    if [[ "${_v}" == *'{{'* || "${_v}" == *'<'*'>'* ]]; then
      skip "egress probe" "tenant parameters still contain placeholders"
      return 0
    fi
  done

  # The checks must not create anything that outlives them, so the probe runs
  # in a namespace that already exists: the target if present, else "default".
  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    _probe_ns="${NAMESPACE}"
  elif kubectl get namespace default >/dev/null 2>&1 \
       && [[ "$(kubectl auth can-i create pods -n default 2>/dev/null || echo no)" == "yes" ]]; then
    _probe_ns="default"
    info "target namespace does not exist yet; probing from 'default' instead"
  fi

  if [[ -z "${_probe_ns}" ]]; then
    skip "egress probe" "no existing namespace available to run a probe pod in"
    return 0
  fi

  EGRESS_POD="sia-egress-check-$$"
  EGRESS_POD_NS="${_probe_ns}"
  [[ -n "${PROXY_URL}" ]] && _proxy_arg="--proxy ${PROXY_URL}"
  # Three things this probe script has to survive, all learned the hard way:
  #
  #   * `kubectl run -i` attaches only after the container has started, so
  #     anything written in the first moment is lost. It ate the opening
  #     `printf` of the first URL, leaving a bare status code that then read as
  #     a URL. Hence the initial sleep, and one atomic write per result.
  #   * `curl -w '%{http_code}'` already prints 000 when the transfer fails, so
  #     an `|| echo 000` fallback prints it a second time. That orphan line
  #     parsed as a URL with no code and was reported [ OK ] reachable — a dead
  #     endpoint announced as a live one.
  #   * kubectl sometimes replays a finished pod's output, so results can repeat.
  #
  # Every result line is therefore tagged, and the reader ignores anything else.
  _script="sleep 2; \
           for u in https://${IDAPTIVE_TENANT_ID}.id.${ROOT_DOMAIN} https://${TENANT_SUBDOMAIN}.dpa.${ROOT_DOMAIN}/api; do \
             c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 ${_proxy_arg} \"\$u\"); \
             printf 'RESULT %s %s\n' \"\$u\" \"\${c:-000}\"; \
           done"
  if _out="$(kubectl run "${EGRESS_POD}" -n "${_probe_ns}" --image=curlimages/curl:latest \
              --restart=Never --rm -i --quiet --command -- sh -c "${_script}" 2>/dev/null)"; then
    EGRESS_POD=""
    while read -r _tag _url _code; do
      # Anything without the tag is noise: a partial first line, a replayed
      # fragment, or pod chatter. Never guess at it.
      [[ "${_tag}" == "RESULT" && -n "${_url}" ]] || continue
      # Whole-line replays mean an endpoint can appear more than once; the first
      # result per URL is the one that counts, and this keeps the pass count honest.
      case " ${_seen} " in *" ${_url} "*) continue ;; esac
      _seen="${_seen} ${_url}"
      # Any HTTP status proves the connection succeeded. These endpoints require
      # authentication, so 401/403 — and even 5xx — mean egress is fine. Only a
      # curl failure (000) indicates DNS, routing or a firewall blocking the way.
      if [[ "${_code}" == "000" ]]; then
        warn "no response" "${_url}"
        _blocked=true
      else
        ok "reachable" "${_url} → HTTP ${_code}"
      fi
    done <<< "${_out}"
    if [[ -z "${_seen}" ]]; then
      # The pod ran but nothing tagged came back. Saying nothing would leave the
      # "egress works" line below to speak for a measurement never taken.
      warn "egress probe" "the probe pod returned no readable result"
      info "not conclusive — this proves neither reachable nor blocked. Re-run, or"
      info "pass --skip-egress-check if probe pods are restricted here."
    elif [[ "${_blocked}" == "true" ]]; then
      info "no HTTP response at all means DNS, routing or a firewall is in the way —"
      info "the connector will not be able to register. Share this with your network"
      info "team, and add --proxy <url> if outbound traffic requires a proxy."
      info "On AKS the usual causes are an outboundType of userDefinedRouting sending"
      info "egress through an Azure Firewall that has not been told about these hosts,"
      info "or a restrictive NSG on the node subnet. Check with:"
      info "  az aks show -g <group> -n <cluster> --query networkProfile.outboundType"
    else
      info "an authenticated endpoint answering 401/403/5xx still proves egress works;"
      info "the connector supplies credentials when it registers"
    fi
  else
    EGRESS_POD=""
    warn "egress probe" "could not run a probe pod in '${_probe_ns}'"
    info "not conclusive — the install may still succeed. Skip with --skip-egress-check."
  fi
  return 0
}

print_summary() {
  heading "Preflight summary"
  printf '  %s%d passed%s   %s%d warning(s)%s   %s%d failure(s)%s\n' \
    "${C_GREEN}" "${PASS_COUNT}" "${C_RESET}" \
    "${C_YELLOW}" "${WARN_COUNT}" "${C_RESET}" \
    "${C_RED}" "${FAIL_COUNT}" "${C_RESET}"
  return 0
}

check_parameters
check_tooling
check_cluster
check_chart_source
check_registry
check_egress
print_summary

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
  # An explicit credential wins over `az acr login`: on Azure it is the
  # deliberate, longer-lived choice (a service principal with AcrPush), and the
  # token path is only the convenient default.
  if [[ -n "${REGISTRY_USERNAME}" ]]; then
    docker login --username "${REGISTRY_USERNAME}" --password-stdin "${REGISTRY%%/*}" \
      < "${REGISTRY_PASSWORD_FILE}"
  elif is_acr; then
    az acr login --name "$(acr_name)"
  else
    info "using this machine's existing docker credentials"
  fi

  step "Pushing ${IMAGE_REMOTE}"
  info "ACR creates the repository on this first push; nothing had to be created"
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
  if [[ -n "${REGISTRY_USERNAME}" ]]; then
    _reg_user="${REGISTRY_USERNAME}"
    _reg_pass="$(<"${REGISTRY_PASSWORD_FILE}")"
  elif is_acr; then
    # --expose-token mints a token for the identity that is already signed in,
    # so this works without the admin user, which is disabled by default on a
    # new registry and is not something to switch on for this.
    _reg_user="${ACR_TOKEN_USER}"
    _reg_pass="$(az acr login --name "$(acr_name)" --expose-token \
                   --query accessToken -o tsv 2>/dev/null)"
    [[ -n "${_reg_pass}" ]] || die "could not obtain an ACR access token for $(acr_name).
       Check 'az account show' and that your identity has AcrPull on the registry."
    warn "pull secret lifetime" "this ACR access token expires in about 3 hours"
    info "the connector pulls its image once at start-up, so the install itself is"
    info "fine — but any later restart or rescheduling will fail with"
    info "ImagePullBackOff until the secret is recreated. For something durable:"
    info "  * attach the registry to the cluster and re-run with --skip-pull-secret:"
    info "      az aks update -n <cluster> -g <group> --attach-acr $(acr_name)"
    info "  * or use a service principal with AcrPull, via --registry-username <appId>"
    info "    and --registry-password-file <secret-file>"
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
