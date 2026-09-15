#!/usr/bin/env bash
# =============================================================================
# CyberArk SIA Kubernetes Connector — prerequisites and preparation
# Azure Kubernetes Service / Azure Container Registry
#
# Gets your environment completely ready to release the connector, and stops
# deliberately short of the release itself:
#
#     ./scripts/sia-connector-prerequisites-azure.sh --config ./sia-connector.env
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
# Azure edition: AKS clusters pushing to Azure Container Registry.
# Authentication and the image pull secret both go through `az`.
#
# This script is deliberately self-contained — it does not source
# sia-connector-common.sh. The AWS pair and each cloud edition are kept fully
# separate so that reading one file tells you everything that will happen on
# your cloud, with no shared indirection to follow.
#
# See docs/prerequisites.md for what each check means and how to act on it.
# =============================================================================

set -euo pipefail
umask 077

_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# DEFAULTS, HELPERS AND CHECKS
# =============================================================================
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
SERVE_LOCAL_REPO=true
LOCAL_REPO_PORT="18080"

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

# ---------------------------------------------------------------------------
# Registry recognition — Azure.
#
# Unlike ECR and Artifact Registry, ACR creates a repository on first push, so
# there is nothing to pre-create — only the registry itself has to exist.
# ---------------------------------------------------------------------------
is_acr()   { [[ "${REGISTRY}" =~ ^[a-zA-Z0-9]+\.azurecr\.(io|cn|us)(/|$) ]]; }
acr_name() { local _h="${REGISTRY%%/*}"; printf '%s' "${_h%%.*}"; }

# The token issued by `az acr login --expose-token` is presented under this
# well-known username. It is not a placeholder — ACR requires exactly this GUID.
ACR_TOKEN_USER="00000000-0000-0000-0000-000000000000"

make_tmpdir() { TMPDIR_SELF="$(mktemp -d)"; return 0; }

port_is_listening() {
  local _port="${1:?}"
  lsof -nP -iTCP:"${_port}" -sTCP:LISTEN >/dev/null 2>&1
}

port_listener_info() {
  local _port="${1:?}"
  lsof -nP -iTCP:"${_port}" -sTCP:LISTEN -Fpc 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2) }
    /^c/ {
      cmd = substr($0, 2)
      if (pid != "") {
        printf "%s\t%s\n", pid, cmd
        exit
      }
    }
  '
}
prepare_and_serve_local_repo() {
  local _chart_dir="${1:-sia-k8s-connector}"
  local _port="${2:-${LOCAL_REPO_PORT}}"
  local _index_src="${_chart_dir}/index.yaml"
  local _pid=""
  local _info="" _busy_pid="" _busy_proc=""

  step "Preparing local chart repo on localhost:${_port}"

  if [[ ! -d "${_chart_dir}" ]]; then
    warn "local chart repo" "chart directory not found: ${_chart_dir}"
    return 0
  fi

  if port_is_listening "${_port}"; then
    _info="$(port_listener_info "${_port}" || true)"
    if [[ -n "${_info}" ]]; then
      _busy_pid="${_info%%$'\t'*}"
      _busy_proc="${_info#*$'\t'}"
      warn "local repo port" "${_port} is busy PID ${_busy_pid} Process name ${_busy_proc}"
    else
      warn "local repo port" "${_port} is busy"
    fi
    return 0
  fi

  helm repo index "${_chart_dir}/" --url "http://localhost:${_port}/${_chart_dir}/"
  mv "${_index_src}" "./index.yaml"

  python3 -m http.server "${_port}" >/tmp/sia-local-helm-server.log 2>&1 &
  _pid=$!
  ok "local chart repo" "http://localhost:${_port}/${_chart_dir}/ (PID ${_pid})"
  log "  Local Repo Server: Running on port ${_port} (PID ${_pid})"
  printf '         %sTo stop local HTTP server:%s kill -9 %s\n' "${C_YELLOW}" "${C_RESET}" "${_pid}"
  return 0
}

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

# Parse one of the flags shared by every edition of this script. Sets ARG_SHIFT
# to the number of arguments consumed and returns 0; returns 1 having consumed
# nothing otherwise, so the parse loop below can then match its own.
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
    --serve-local-repo)       SERVE_LOCAL_REPO=true; ARG_SHIFT=1 ;;
    --local-repo-port)        LOCAL_REPO_PORT="${2:?}" ;;
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

  if [[ "${SERVE_LOCAL_REPO}" == "true" ]]; then
    if have python3; then
      ok "python3" "present (used by local chart repo server)"
    else
      fail "python3" "not found — required when local chart repo serving is enabled"
    fi
  else
    skip "python3" "local chart repo serving disabled"
  fi

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
          warn "acr repository" "${IMAGE_NAME} — created on first push"
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

check_local_repo() {
  heading "Preflight — local repo"
  local _info="" _pid="" _proc=""

  if [[ "${SERVE_LOCAL_REPO}" != "true" ]]; then
    skip "local repo preflight" "serving disabled"
    return 0
  fi

  if [[ ! "${LOCAL_REPO_PORT}" =~ ^[0-9]+$ ]] || (( LOCAL_REPO_PORT < 1 || LOCAL_REPO_PORT > 65535 )); then
    fail "local repo port" "${LOCAL_REPO_PORT} is invalid (use 1-65535)"
    return 0
  fi

  if port_is_listening "${LOCAL_REPO_PORT}"; then
    _info="$(port_listener_info "${LOCAL_REPO_PORT}" || true)"
    if [[ -n "${_info}" ]]; then
      _pid="${_info%%$'\t'*}"
      _proc="${_info#*$'\t'}"
      warn "local repo port" "${LOCAL_REPO_PORT} in use (PID ${_pid}, process ${_proc})"
    else
      warn "local repo port" "${LOCAL_REPO_PORT} in use"
    fi
  else
    ok "local repo port" "${LOCAL_REPO_PORT} is free"
  fi
  return 0
}

check_connectivity() {
  heading "Preflight — SIA endpoint connectivity"
  local _url="" _code="" _any_blocked=false _v=""
  local _id_url="" _id_fallback_url="" _used_id_url=""

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

  _id_url="https://${IDAPTIVE_TENANT_ID}.id.${ROOT_DOMAIN}"
  _used_id_url="${_id_url}"
  _code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${_id_url}" 2>/dev/null; true)"
  if [[ "${_code}" == "000" ]]; then
    _id_fallback_url="https://$(echo "${IDAPTIVE_TENANT_ID}" | tr '[:upper:]' '[:lower:]').my.idaptive.app"
    info "${_id_url} unreachable (HTTP 000) — retrying with ${_id_fallback_url}"
    _code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${_id_fallback_url}" 2>/dev/null; true)"
    _used_id_url="${_id_fallback_url}"
  fi

  if [[ "${_code}" == "000" ]]; then
    fail "reachable" "${_used_id_url}"
    info "no HTTP response — DNS, routing or a firewall may be blocking the connection"
    _any_blocked=true
  else
    ok "reachable" "${_used_id_url} → HTTP ${_code}"
  fi

  _url="https://${TENANT_SUBDOMAIN}.dpa.${ROOT_DOMAIN}/api"
  _code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${_url}" 2>/dev/null; true)"
  if [[ "${_code}" == "000" ]]; then
    fail "reachable" "${_url}"
    info "no HTTP response — DNS, routing or a firewall may be blocking the connection"
    _any_blocked=true
  else
    ok "reachable" "${_url} → HTTP ${_code}"
  fi

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

# The single entry point for the checks, so the order they run in is stated in
# exactly one place.
run_prerequisite_checks() {
  check_parameters
  check_tooling
  check_local_repo
  check_connectivity
  check_cluster
  check_registry
  check_base_image
  print_summary
  return 0
}

# ---------------------------------------------------------------------------
# Defaults for the preparation steps. Everything the checks use is defaulted
# in the DEFAULTS section above.
# ---------------------------------------------------------------------------
PULL_SECRET="sia-registry-creds"
KUBECTL_VERSION="v1.30.0"
BASE_IMAGE=""

usage() {
  cat <<'EOF'
CyberArk SIA Kubernetes Connector — prerequisites and preparation (Azure Kubernetes Service / Azure Container Registry)

Validates your environment, then builds and publishes the connector image and
creates the namespace and secrets — everything the connector needs except the
Helm release itself, which is left to you.

  ./scripts/sia-connector-prerequisites-azure.sh --config ./sia-connector.env --check-only  # validate only
  ./scripts/sia-connector-prerequisites-azure.sh --config ./sia-connector.env               # validate + prepare

Nothing is created until every check passes, and you are asked to confirm first.
Exits 0 on success, 1 on failure.

Tenant parameters (from the SIA Admin Portal)
  --root-domain <domain>          Your SIA environment domain (e.g. cyberark.cloud)
  --idaptive-tenant-id <id>       Identity tenant ID
  --tenant-subdomain <name>       Your tenant subdomain

Infrastructure
  --registry <host[/path]>        Your Azure Container Registry login server:
                                    <name>.azurecr.io   (also .cn and .us)
  --registry-username <user>      Optional, and takes precedence over the ACR
                                  token because it does not expire:
                                    <appId> of a service principal with AcrPush
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

setup_transcript "${_SELF_DIR}/sia-connector-prerequisites-azure"
make_tmpdir

log "${C_BOLD}CyberArk SIA Kubernetes Connector — prerequisites v${SIA_TOOLS_VERSION}  ·  Azure Kubernetes Service / Azure Container Registry${C_RESET}"
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
log "Pending deployment parameters:"
log "  Cluster:          $(kubectl config current-context 2>/dev/null)"
log "  Namespace:        ${NAMESPACE}"
log "  Registry:         ${REGISTRY%%/*}"
log "  Image:            ${IMAGE_REMOTE}"
log "  Registry secret:  ${PULL_SECRET}"
[[ "${SERVE_LOCAL_REPO}" == "true" ]] && log "  Local chart repo: http://localhost:${LOCAL_REPO_PORT}/sia-k8s-connector/"
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
    [[ -n "${_reg_pass}" ]] || die "${REGISTRY_PASSWORD_FILE} is empty."
  elif is_acr; then
    # --expose-token mints a token for the identity that is already signed in,
    # so this works without the admin user, which is disabled by default on a
    # new registry and is not something to switch on for this.
    _reg_user="${ACR_TOKEN_USER}"
    _reg_pass="$(az acr login --name "$(acr_name)" --expose-token \
                   --query accessToken -o tsv 2>/dev/null || true)"
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
