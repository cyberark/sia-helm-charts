#!/usr/bin/env bash
# =============================================================================
# CyberArk SIA Kubernetes Connector — shared library
#
# This file is a library, not a command. It is sourced by
# sia-connector-prerequisites.sh, and by any other script in this distribution
# that has to validate an environment before acting on it.
#
# Keeping the checks here means there is exactly one copy of each of them, so
# no two callers can drift apart about what "ready" means.
# =============================================================================

# Sourced, not executed. Without this guard the file looks like an installer
# that silently does nothing, which is a confusing thing to hand a customer.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf 'sia-connector-common.sh is a library, not a command.\n' >&2
  printf 'Run ./scripts/sia-connector-prerequisites.sh instead.\n' >&2
  exit 64
fi

SIA_TOOLS_VERSION="1.1.0"

# ---------------------------------------------------------------------------
# Defaults — only parameters the checks actually use.
# ---------------------------------------------------------------------------
NAMESPACE="sia-k8s-connector"
IMAGE_NAME="cms-k8s-connector"
IMAGE_TAG="latest"
PLATFORM="linux/amd64"

# Required — no defaults
ROOT_DOMAIN="cyberark.cloud"
IDAPTIVE_TENANT_ID=""
TENANT_SUBDOMAIN=""
REGISTRY=""

# Optional — empty means "not set"
REGISTRY_USERNAME=""
REGISTRY_PASSWORD_FILE=""
CONFIG_FILE=""
LOG_FILE=""
DOCKERFILE_DIR=""

# Behaviour
CHECK_ONLY=false
SKIP_BUILD=false
SKIP_PULL_SECRET=false
ASSUME_YES=false

# Derived during the checks
IMAGE_LOCAL=""
IMAGE_REMOTE=""

# Internal state
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
TMPDIR_SELF=""
ARG_SHIFT=0

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

cleanup() {
  local rc=$?
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

is_ecr()      { [[ "${REGISTRY}" =~ \.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com ]]; }
ecr_region()  { printf '%s' "${REGISTRY}" | sed -E 's/^[0-9]+\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com.*/\1/'; }

make_tmpdir() { TMPDIR_SELF="$(mktemp -d)"; return 0; }

confirm() {
  local prompt="$1"
  [[ "${ASSUME_YES}" == "true" ]] && return 0
  # Open /dev/tty as the only reliable test that a terminal is actually
  # connected — `[[ -r /dev/tty ]]` passes even in CI pipelines.
  if ! { true </dev/tty; } 2>/dev/null; then
    die "cannot prompt for confirmation and --yes was not given.
       Re-run with --yes, or from a terminal."
  fi
  local reply=""
  read -rp "${prompt} [y/N] " reply </dev/tty || reply=""
  [[ "${reply}" == "y" || "${reply}" == "Y" ]]
}

resolve_image_refs() {
  IMAGE_LOCAL="${IMAGE_NAME}:${IMAGE_TAG}"
  [[ -n "${REGISTRY}" ]] && IMAGE_REMOTE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
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
      # shellcheck disable=SC1090
      set -a; source "${CONFIG_FILE}"; set +a
    fi
  done
  return 0
}

# Parse one flag that both scripts understand. Sets ARG_SHIFT to the number of
# arguments consumed and returns 0. Returns 1 having consumed nothing if the
# flag is not one of the shared set, so the caller can then match its own.
common_parse_arg() {
  ARG_SHIFT=2
  case "$1" in
    --root-domain)            ROOT_DOMAIN="${2:?}" ;;
    --idaptive-tenant-id)     IDAPTIVE_TENANT_ID="${2:?}" ;;
    --tenant-subdomain)       TENANT_SUBDOMAIN="${2:?}" ;;
    --registry)               REGISTRY="${2:?}" ;;
    --namespace)              NAMESPACE="${2:?}" ;;
    --image-name)             IMAGE_NAME="${2:?}" ;;
    --image-tag)              IMAGE_TAG="${2:?}" ;;
    --registry-username)      REGISTRY_USERNAME="${2:?}" ;;
    --registry-password-file) REGISTRY_PASSWORD_FILE="${2:?}" ;;
    --platform)               PLATFORM="${2:?}" ;;
    --dockerfile-dir)         DOCKERFILE_DIR="${2:?}" ;;
    --log-file)               LOG_FILE="${2:?}" ;;
    --config)                 : ;;   # already consumed by preparse_config
    --skip-build)             SKIP_BUILD=true;        ARG_SHIFT=1 ;;
    --skip-pull-secret)       SKIP_PULL_SECRET=true;  ARG_SHIFT=1 ;;
    *)                        ARG_SHIFT=0; return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Transcript. Passwords are never written to stdout, so the log is safe to send,
# but redact defensively in case a subcommand echoes something unexpected.
# ---------------------------------------------------------------------------
setup_transcript() {
  local _prefix="$1"
  local _stamp=""
  local _log_dir=""

  _stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -z "${LOG_FILE}" ]]; then
    if [[ "${_prefix}" == /* ]]; then
      LOG_FILE="${_prefix}-${_stamp}.log"
    else
      LOG_FILE="./${_prefix}-${_stamp}.log"
    fi
  fi

  _log_dir="$(dirname "${LOG_FILE}")"
  mkdir -p "${_log_dir}" || die "cannot create log directory: ${_log_dir}"

  exec > >(tee >(sed -E 's/(password|token|secret)=[^ ]*/\1=<redacted>/gi' > "${LOG_FILE}")) 2>&1
  return 0
}

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
  check_required "registry"           "${REGISTRY}"

  if [[ -n "${ROOT_DOMAIN}" && ! "${ROOT_DOMAIN}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]; then
    fail "root domain format" "'${ROOT_DOMAIN}' does not look like a domain"
  elif [[ -n "${ROOT_DOMAIN}" ]]; then
    ok "root domain format" "identity: ${IDAPTIVE_TENANT_ID}.id.${ROOT_DOMAIN}"
    info "api:      ${TENANT_SUBDOMAIN}.dpa.${ROOT_DOMAIN}/api"
  fi

  resolve_image_refs
  [[ -n "${IMAGE_REMOTE}" ]] && ok "image reference" "${IMAGE_REMOTE}"
  return 0
}

check_tooling() {
  heading "Preflight — tooling"
  local _kv="" _hv="" _t="" _c=""

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

  if is_ecr; then
    if have aws; then ok "aws cli" "present (registry is Amazon ECR)"
    else fail "aws cli" "not found, but the registry is Amazon ECR"; fi
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
  local _want_arch="" _arches=""

  if ! kubectl version -o json >/dev/null 2>&1 && ! kubectl cluster-info >/dev/null 2>&1; then
    fail "cluster reachable" "kubectl cannot reach the API server"
    info "check KUBECONFIG — note that \"KUBECONFIG=~/path\" in double quotes does NOT"
    info "expand the tilde; use \"\$HOME/path\" instead"
    return 0
  fi

  _ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  _srv="$(kubectl version -o json 2>/dev/null \
           | sed -n 's/.*"gitVersion": *"v\([0-9.]*\)".*/\1/p' | tail -1)"
  ok "cluster reachable" "server v${_srv:-?}"
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

  # Namespace.
  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    ok "namespace" "${NAMESPACE} already exists"
  else
    warn "namespace" "${NAMESPACE} does not exist — will be created"
  fi

  # Advisory only.
  if kubectl get apiservices 2>/dev/null | grep -q 'metrics\.k8s\.io'; then
    ok "metrics-server" "present — autoscaling metrics available"
  else
    warn "metrics-server" "absent — the chart's HPA will report <unknown>"
    info "harmless: the StatefulSet still runs at --replicas. Disable with:"
    info "  --set autoscaling.enabled=false  (see README)"
  fi

  return 0
}

check_registry() {
  heading "Preflight — registry"

  if [[ "${SKIP_BUILD}" == "true" && "${SKIP_PULL_SECRET}" == "true" ]]; then
    skip "registry auth" "--skip-build and --skip-pull-secret given"
  elif [[ -z "${REGISTRY}" ]]; then
    skip "registry auth" "no registry set — see the failure above"
  elif is_ecr; then
    if ! have aws; then
      fail "registry auth" "aws cli required for ECR"
    elif ! aws sts get-caller-identity >/dev/null 2>&1; then
      fail "aws credentials" "not authenticated — try 'aws sso login'"
    else
      ok "aws credentials" "authenticated"
      if aws ecr describe-repositories --repository-names "${IMAGE_NAME}" --region "$(ecr_region)" >/dev/null 2>&1; then
        ok "ecr repository" "${IMAGE_NAME} exists in $(ecr_region)"
      else
        warn "ecr repository" "${IMAGE_NAME} absent — it will be created on push"
      fi
      info "ECR authorisation tokens expire after 12 hours; the pull secret must be"
      info "recreated if the cluster stops being able to pull later on"
    fi
  elif [[ -n "${REGISTRY_USERNAME}" ]]; then
    if [[ -n "${REGISTRY_PASSWORD_FILE}" && -f "${REGISTRY_PASSWORD_FILE}" ]]; then
      ok "registry auth" "docker login as ${REGISTRY_USERNAME}"
    else
      fail "registry auth" "--registry-username given without a readable --registry-password-file"
    fi
  else
    warn "registry auth" "no credentials given — assuming this machine is already logged in"
    info "if the push fails, run: docker login ${REGISTRY%%/*}"
  fi
  return 0
}

check_connectivity() {
  heading "Preflight — SIA endpoint connectivity"
  local _url="" _code="" _any_blocked=false _v=""

  if [[ -z "${ROOT_DOMAIN}" || -z "${IDAPTIVE_TENANT_ID}" || -z "${TENANT_SUBDOMAIN}" ]]; then
    skip "connectivity" "tenant parameters incomplete"
    return 0
  fi
  for _v in "${ROOT_DOMAIN}" "${IDAPTIVE_TENANT_ID}" "${TENANT_SUBDOMAIN}"; do
    if [[ "${_v}" == *'{{'* || "${_v}" == *'<'*'>'* ]]; then
      skip "connectivity" "tenant parameters still contain placeholders"
      return 0
    fi
  done
  if ! have curl; then
    skip "connectivity" "curl not found — see tooling check above"
    return 0
  fi

  for _url in \
    "https://${IDAPTIVE_TENANT_ID}.id.${ROOT_DOMAIN}" \
    "https://${TENANT_SUBDOMAIN}.dpa.${ROOT_DOMAIN}/api"; do
    _code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${_url}" 2>/dev/null; true)"
    if [[ "${_code}" == "000" ]]; then
      fail "reachable" "${_url}"
      info "no HTTP response — DNS, routing or a firewall may be blocking the connection"
      _any_blocked=true
    else
      ok "reachable" "${_url} → HTTP ${_code}"
    fi
  done

  if [[ "${_any_blocked}" == "false" ]]; then
    info "an authenticated endpoint answering 401/403/5xx still proves egress works;"
    info "the connector supplies credentials when it registers"
  fi
  return 0
}

check_base_image() {
  if [[ "${SKIP_BUILD}" == "true" ]]; then
    ok "base image" "Skipping build."
  else
    if [[ -z "${BASE_IMAGE}" ]]; then
      fail "base image" "BASE_IMAGE is not set. Set it in sia-connector.env or pass --base-image."
    else
      ok "base image" "${BASE_IMAGE}"
    fi
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

# Both scripts call this and nothing else, so the set of checks and the order
# they run in cannot differ between them.
run_prerequisite_checks() {
  check_parameters
  check_tooling
  check_connectivity
  check_cluster
  check_registry
  check_base_image
  print_summary
  return 0
}
