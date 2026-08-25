#!/usr/bin/env bash
# =============================================================================
# CyberArk SIA Kubernetes Connector — guided installer
#
# Builds the connector image for your environment, publishes it to your own
# container registry, and installs the Helm chart into your cluster.
#
# Run the preflight checks on their own first:
#
#     ./sia-connector-install.sh --config ./sia-connector.env --check-only
#
# Then install:
#
#     ./sia-connector-install.sh --config ./sia-connector.env
#
# Nothing is created in your cluster or registry until every preflight check
# passes. --check-only makes no changes at all, so it is safe to run any time
# and the transcript is useful to attach to a support ticket.
#
# See README.md for the full parameter reference.
# =============================================================================

set -euo pipefail
umask 077

VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAMESPACE="sia-k8s-connector"
RELEASE="sia-connector"
REPLICAS="1"
IMAGE_NAME="cms-k8s-connector"
IMAGE_TAG="latest"
PULL_SECRET="sia-registry-creds"
PLATFORM="linux/amd64"
KUBECTL_VERSION="v1.30.0"
BASE_IMAGE="alpine:latest"
CHART_NAME="sia-connector"
CHART_REPO_NAME="sia-helm-charts"
CHART_REF="https://raw.githubusercontent.com/cyberark/sia-helm-charts/main/sia-k8s-connector/"
SECRET_NAME="sia-auth"
ROLLOUT_TIMEOUT="300"
REGISTER_TIMEOUT="180"

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
CLUSTER_NAME=""
REGISTRY_USERNAME=""
REGISTRY_PASSWORD_FILE=""
PASSWORD_FILE=""
CONFIG_FILE=""
LOG_FILE=""
DOCKERFILE_DIR=""

# Behaviour
CHECK_ONLY=false
SKIP_BUILD=false
SKIP_PULL_SECRET=false
SKIP_EGRESS_CHECK=false
ASSUME_YES=false

# Internal state
SIA_PASSWORD="${SIA_PASSWORD:-}"
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
TMPDIR_SELF=""
EGRESS_POD=""

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

EGRESS_POD_NS=""
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

usage() {
  cat <<'EOF'
CyberArk SIA Kubernetes Connector — guided installer

Builds the connector image for your environment, publishes it to your own
container registry, and installs the Helm chart into your cluster.

  ./sia-connector-install.sh --config ./sia-connector.env --check-only   # validate
  ./sia-connector-install.sh --config ./sia-connector.env                # install

Nothing is created in your cluster or registry until every preflight check
passes. --check-only makes no changes at all, so it is safe to run any time,
and its transcript is useful to attach to a support ticket.

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
  --check-only                    Run preflight only; change nothing
  --skip-build                    Image is already built and pushed
  --skip-pull-secret              Registry is public, or the secret already exists
  --skip-egress-check             Do not create the throwaway connectivity-probe pod
  --yes                           Non-interactive; never prompt
  -h, --help                      This message
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
# Read --config first so explicit flags win regardless of ordering.
_args=("$@")
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
       read from one. Remove that line and use any of:
         - the interactive prompt (just run the installer)
         - --password-file <path>   (a file only you can read)
         - the SIA_PASSWORD environment variable, for CI"
    fi
    # shellcheck disable=SC1090
    set -a; source "${CONFIG_FILE}"; set +a
  fi
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-domain)            ROOT_DOMAIN="${2:?}"; shift 2 ;;
    --idaptive-tenant-id)     IDAPTIVE_TENANT_ID="${2:?}"; shift 2 ;;
    --tenant-subdomain)       TENANT_SUBDOMAIN="${2:?}"; shift 2 ;;
    --connector-pool-id)      CONNECTOR_POOL_ID="${2:?}"; shift 2 ;;
    --username)               SIA_USERNAME="${2:?}"; shift 2 ;;
    --registry)               REGISTRY="${2:?}"; shift 2 ;;
    --namespace)              NAMESPACE="${2:?}"; shift 2 ;;
    --release)                RELEASE="${2:?}"; shift 2 ;;
    --replicas)               REPLICAS="${2:?}"; shift 2 ;;
    --image-name)             IMAGE_NAME="${2:?}"; shift 2 ;;
    --image-tag)              IMAGE_TAG="${2:?}"; shift 2 ;;
    --chart-ref)              CHART_REF="${2:?}"; shift 2 ;;
    --chart-version)          CHART_VERSION="${2:?}"; shift 2 ;;
    --pull-secret)            PULL_SECRET="${2:?}"; shift 2 ;;
    --registry-username)      REGISTRY_USERNAME="${2:?}"; shift 2 ;;
    --registry-password-file) REGISTRY_PASSWORD_FILE="${2:?}"; shift 2 ;;
    --storage-class)          STORAGE_CLASS="${2:?}"; shift 2 ;;
    --proxy)                  PROXY_URL="${2:?}"; shift 2 ;;
    --cluster-name)           CLUSTER_NAME="${2:?}"; shift 2 ;;
    --platform)               PLATFORM="${2:?}"; shift 2 ;;
    --kubectl-version)        KUBECTL_VERSION="${2:?}"; shift 2 ;;
    --base-image)             BASE_IMAGE="${2:?}"; shift 2 ;;
    --dockerfile-dir)         DOCKERFILE_DIR="${2:?}"; shift 2 ;;
    --password-file)          PASSWORD_FILE="${2:?}"; shift 2 ;;
    --log-file)               LOG_FILE="${2:?}"; shift 2 ;;
    --config)                 shift 2 ;;   # already consumed above
    --check-only)             CHECK_ONLY=true; shift ;;
    --skip-build)             SKIP_BUILD=true; shift ;;
    --skip-pull-secret)       SKIP_PULL_SECRET=true; shift ;;
    --skip-egress-check)      SKIP_EGRESS_CHECK=true; shift ;;
    --yes|-y)                 ASSUME_YES=true; shift ;;
    -h|--help)                usage; exit 0 ;;
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
if [[ -z "${LOG_FILE}" ]]; then
  LOG_FILE="./sia-connector-install-$(date -u +%Y%m%dT%H%M%SZ).log"
fi
exec > >(tee >(sed -E 's/(password|token|secret)=[^ ]*/\1=<redacted>/gi' > "${LOG_FILE}")) 2>&1

TMPDIR_SELF="$(mktemp -d)"

log "${C_BOLD}CyberArk SIA Kubernetes Connector — installer v${VERSION}${C_RESET}"
log "${C_DIM}$(date -u +'%Y-%m-%dT%H:%M:%SZ')  ·  transcript: ${LOG_FILE}${C_RESET}"

# ---------------------------------------------------------------------------
# Resolve the password (before preflight, so preflight can validate it)
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
  [[ -r /dev/tty ]] || die "cannot prompt for confirmation and --yes was not given."
  local reply
  read -rp "${prompt} [y/N] " reply </dev/tty
  [[ "${reply}" == "y" || "${reply}" == "Y" ]]
}

is_ecr()      { [[ "${REGISTRY}" =~ \.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com ]]; }
ecr_account() { printf '%s' "${REGISTRY}" | sed -E 's/^([0-9]+)\.dkr\.ecr\..*/\1/'; }
ecr_region()  { printf '%s' "${REGISTRY}" | sed -E 's/^[0-9]+\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com.*/\1/'; }
chart_is_file() { [[ "${CHART_REF}" == *.tgz ]]; }

IMAGE_LOCAL="${IMAGE_NAME}:${IMAGE_TAG}"
IMAGE_REMOTE=""   # set once REGISTRY is known valid

# =============================================================================
# PREFLIGHT
# =============================================================================
heading "Preflight — parameters"

check_required() {
  local name="$1" value="$2"
  if [[ -z "${value}" ]]; then
    fail "${name}" "missing — required"
  elif [[ "${value}" == *'{{'* || "${value}" == *'<'*'>'* ]]; then
    fail "${name}" "still a placeholder: ${value}"
  else
    ok "${name}" "${value}"
  fi
}

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

if [[ "${CHECK_ONLY}" == "true" && -z "${SIA_PASSWORD}" ]]; then
  skip "password" "not required for --check-only"
elif [[ -z "${SIA_PASSWORD}" ]]; then
  fail "password" "empty"
else
  ok "password" "supplied (${#SIA_PASSWORD} characters, not shown)"
fi

[[ -n "${REGISTRY}" ]] && IMAGE_REMOTE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
[[ -n "${IMAGE_REMOTE}" ]] && ok "image reference" "${IMAGE_REMOTE}"
[[ -n "${PROXY_URL}" ]] && ok "outbound proxy" "${PROXY_URL}"

# ---------------------------------------------------------------------------
heading "Preflight — tooling"

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

# ---------------------------------------------------------------------------
heading "Preflight — cluster"

if ! kubectl version -o json >/dev/null 2>&1 && ! kubectl cluster-info >/dev/null 2>&1; then
  fail "cluster reachable" "kubectl cannot reach the API server"
  info "check KUBECONFIG — note that \"KUBECONFIG=~/path\" in double quotes does NOT"
  info "expand the tilde; use \"\$HOME/path\" instead"
else
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
  _perm_fail=false
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
    info "the connector's PVC would never bind. Common on EKS Auto Mode, where you want:"
    info "  --storage-class gp3-auto"
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
fi

# ---------------------------------------------------------------------------
heading "Preflight — chart source"

CHART_INSTALL_REF=""
if chart_is_file; then
  if [[ -f "${CHART_REF}" ]] && helm show chart "${CHART_REF}" >/dev/null 2>&1; then
    _cv="$(helm show chart "${CHART_REF}" 2>/dev/null | sed -n 's/^version: *//p' | head -1)"
    ok "chart archive" "${CHART_REF} (version ${_cv})"
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
    info "The reliable path is to install from a chart archive supplied by CyberArk:"
    info "  --chart-ref ./${CHART_NAME}-<version>.tgz"
    info "Verify an archive before using it:  helm show chart <file>.tgz"
  fi
fi

# ---------------------------------------------------------------------------
heading "Preflight — registry"

if [[ "${SKIP_BUILD}" == "true" && "${SKIP_PULL_SECRET}" == "true" ]]; then
  skip "registry auth" "--skip-build and --skip-pull-secret given"
elif is_ecr; then
  _acct="$(ecr_account)"; _rgn="$(ecr_region)"
  if ! have aws; then
    fail "registry auth" "aws cli required for ECR"
  else
    _who="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '')"
    if [[ -z "${_who}" ]]; then
      fail "aws credentials" "not authenticated — try 'aws sso login'"
    elif [[ "${_who}" != "${_acct}" ]]; then
      fail "aws account" "authenticated as ${_who}, but the registry belongs to ${_acct}"
      info "check AWS_PROFILE — it is easy to inherit one that targets a different account"
    else
      ok "aws account" "${_who} matches the registry"
      if aws ecr describe-repositories --repository-names "${IMAGE_NAME}" --region "${_rgn}" >/dev/null 2>&1; then
        ok "ecr repository" "${IMAGE_NAME} exists in ${_rgn}"
      else
        warn "ecr repository" "${IMAGE_NAME} absent in ${_rgn} — it will be created"
      fi
      info "ECR authorisation tokens expire after 12 hours; the pull secret must be"
      info "recreated if the cluster stops being able to pull later on"
    fi
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

# ---------------------------------------------------------------------------
# Egress probe. Node egress cannot be tested from this machine, and a blocked
# network is a common cause of an install that looks fine until registration.
# ---------------------------------------------------------------------------
heading "Preflight — connectivity from inside the cluster"

if [[ "${SKIP_EGRESS_CHECK}" == "true" ]]; then
  skip "egress probe" "--skip-egress-check given"
elif (( FAIL_COUNT > 0 )); then
  skip "egress probe" "earlier checks failed; not creating a probe pod"
elif [[ -z "${ROOT_DOMAIN}" || -z "${IDAPTIVE_TENANT_ID}" || -z "${TENANT_SUBDOMAIN}" ]]; then
  skip "egress probe" "tenant parameters incomplete"
else
  # Preflight must not create anything, so the probe runs in a namespace that
  # already exists: the target if present, otherwise "default".
  _probe_ns=""
  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    _probe_ns="${NAMESPACE}"
  elif kubectl get namespace default >/dev/null 2>&1 \
       && [[ "$(kubectl auth can-i create pods -n default 2>/dev/null || echo no)" == "yes" ]]; then
    _probe_ns="default"
    info "target namespace does not exist yet; probing from 'default' instead"
  fi

  if [[ -z "${_probe_ns}" ]]; then
    skip "egress probe" "no existing namespace available to run a probe pod in"
  else
    EGRESS_POD="sia-egress-check-$$"
    EGRESS_POD_NS="${_probe_ns}"
    _proxy_arg=""
    [[ -n "${PROXY_URL}" ]] && _proxy_arg="--proxy ${PROXY_URL}"
    _script="for u in https://${IDAPTIVE_TENANT_ID}.id.${ROOT_DOMAIN} https://${TENANT_SUBDOMAIN}.dpa.${ROOT_DOMAIN}/api; do \
               printf '%s ' \"\$u\"; \
               curl -s -o /dev/null -w '%{http_code}\n' --max-time 15 ${_proxy_arg} \"\$u\" || echo 000; \
             done"
    if _out="$(kubectl run "${EGRESS_POD}" -n "${_probe_ns}" --image=curlimages/curl:latest \
                --restart=Never --rm -i --quiet --command -- sh -c "${_script}" 2>/dev/null)"; then
      EGRESS_POD=""
      _blocked=false
      _seen=""
      while read -r _url _code; do
        [[ -z "${_url}" ]] && continue
        # "kubectl run -i" sometimes replays a finished pod's output, so an
        # endpoint can appear more than once. Duplicates are always whole lines,
        # so reporting the first result per URL is sufficient — and avoids an
        # inflated preflight count.
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
      if [[ "${_blocked}" == "true" ]]; then
        info "no HTTP response at all means DNS, routing or a firewall is in the way —"
        info "the connector will not be able to register. Share this with your network"
        info "team, and add --proxy <url> if outbound traffic requires a proxy."
      else
        info "an authenticated endpoint answering 401/403/5xx still proves egress works;"
        info "the connector supplies credentials when it registers"
      fi
    else
      EGRESS_POD=""
      warn "egress probe" "could not run a probe pod in '${_probe_ns}'"
      info "not conclusive — the install may still succeed. Skip with --skip-egress-check."
    fi
  fi
fi

# ---------------------------------------------------------------------------
heading "Preflight summary"
printf '  %s%d passed%s   %s%d warning(s)%s   %s%d failure(s)%s\n' \
  "${C_GREEN}" "${PASS_COUNT}" "${C_RESET}" \
  "${C_YELLOW}" "${WARN_COUNT}" "${C_RESET}" \
  "${C_RED}" "${FAIL_COUNT}" "${C_RESET}"

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
