#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Required env vars (injected by Helm / K8s secret)
# ---------------------------------------------------------------------------
SIA_USERNAME="${SIA_USERNAME:?SIA_USERNAME is required}"
SIA_PASSWORD="${SIA_PASSWORD:?SIA_PASSWORD is required}"
CONNECTOR_POOL_ID="${CONNECTOR_POOL_ID:?CONNECTOR_POOL_ID is required}"
CHART_VERSION="${CHART_VERSION:?CHART_VERSION is required}"
CONTAINER_NAME="${CONTAINER_NAME:?CONTAINER_NAME is required}"

IDAPTIVE_TENANT_ID="${IDAPTIVE_TENANT_ID:?IDAPTIVE_TENANT_ID is required}"
TENANT_SUBDOMAIN="${TENANT_SUBDOMAIN:-}"
ROOT_DOMAIN="${ROOT_DOMAIN:-}"         # baked into image at build time
DEV_API_ENDPOINT="${DEV_API_ENDPOINT:-}"  # internal dev override — not customer-facing

# Build TENANT_URL: https://<IDAPTIVE_TENANT_ID>.id.<ROOT_DOMAIN>
if [[ -z "${ROOT_DOMAIN}" ]]; then
  echo "[$(date -Is)] ERROR: ROOT_DOMAIN not set — was the image built with build.sh?" >&2
  exit 1
fi
TENANT_URL="https://${IDAPTIVE_TENANT_ID}.id.${ROOT_DOMAIN}"

# Derive API base URL:
#   Priority 1: https://<TENANT_SUBDOMAIN>.dpa.<ROOT_DOMAIN>/api — production path
#   Priority 2: DEV_API_ENDPOINT/api — internal override, not exposed to customers
#   Fail if neither is set.
if [[ -n "${DEV_API_ENDPOINT}" ]]; then
  _API_BASE="${DEV_API_ENDPOINT}/api"
  echo "[$(date -Is)] WARNING: Using DEV_API_ENDPOINT for API base URL: ${_API_BASE}" >&2
elif [[ -n "${TENANT_SUBDOMAIN}" && -n "${ROOT_DOMAIN}" ]]; then
  _API_BASE="https://${TENANT_SUBDOMAIN}.dpa.${ROOT_DOMAIN}/api"
  echo "[$(date -Is)] Using tenant subdomain for API base URL: ${_API_BASE}" >&2
else
  echo "[$(date -Is)] ERROR: Either TENANT_SUBDOMAIN (+ ROOT_DOMAIN baked in image) or DEV_API_ENDPOINT must be set." >&2
  exit 1
fi

DOWNLOAD_API_URL="${DOWNLOAD_API_URL:-${_API_BASE}/connectors/download-ephemeral}"
UPGRADE_API_BASE_URL="${UPGRADE_API_BASE_URL:-${_API_BASE}/connectors}"
PROXY_URL="${PROXY_URL:-}"
POD_NAMESPACE="${POD_NAMESPACE:-}"

# Build proxy args array for external curl calls; empty when no proxy is configured.
CURL_PROXY_ARGS=()
[[ -n "${PROXY_URL}" ]] && CURL_PROXY_ARGS=(--proxy "${PROXY_URL}")

# ---------------------------------------------------------------------------
# Publish connector ID to a K8s ConfigMap so the pre-delete hook can read it
# without needing a PVC mount or pod exec.
# ConfigMap name: <container-name>-connector-id  (e.g. sia-connector-0-connector-id)
# ---------------------------------------------------------------------------
publish_connector_id() {
  local connector_id="$1"
  if [[ -z "${POD_NAMESPACE}" ]]; then
    log "WARNING: POD_NAMESPACE not set — skipping ConfigMap publish."
    return 0
  fi

  local cm_name="${CONTAINER_NAME}-connector-id"
  local apiserver="https://kubernetes.default.svc"
  local token_file="/var/run/secrets/kubernetes.io/serviceaccount/token"
  local cacert="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

  if [[ ! -f "${token_file}" ]]; then
    log "WARNING: no service account token found — skipping ConfigMap publish."
    return 0
  fi

  local token
  token=$(cat "${token_file}")

  local payload
  payload=$(jq -n \
    --arg name "${cm_name}" \
    --arg namespace "${POD_NAMESPACE}" \
    --arg container "${CONTAINER_NAME}" \
    --arg id "${connector_id}" \
    '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$name,namespace:$namespace,labels:{"app.kubernetes.io/managed-by":"sia-connector","sia-connector/container":$container}},data:{connector_id:$id}}')

  # Try patch first (update), fall back to create
  local http_code
  http_code=$(curl -sS -X PATCH \
    --cacert "${cacert}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/strategic-merge-patch+json" \
    -w "%{http_code}" -o /dev/null \
    -d "${payload}" \
    "${apiserver}/api/v1/namespaces/${POD_NAMESPACE}/configmaps/${cm_name}")

  if [[ "${http_code}" == "404" ]]; then
    http_code=$(curl -sS -X POST \
      --cacert "${cacert}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -w "%{http_code}" -o /dev/null \
      -d "${payload}" \
      "${apiserver}/api/v1/namespaces/${POD_NAMESPACE}/configmaps")
  fi

  if [[ "${http_code}" == "200" || "${http_code}" == "201" ]]; then
    log "Connector ID published to ConfigMap '${cm_name}' in namespace '${POD_NAMESPACE}'."
  else
    log "WARNING: failed to publish connector ID to ConfigMap (HTTP ${http_code}) — continuing anyway."
  fi
}

# ---------------------------------------------------------------------------
# Directory layout (all under PVC mount /opt/cyberark/connector)
#
#   /opt/cyberark/connector/<CONTAINER_NAME>/
#     current_version.txt
#     previous_version.txt
#     v<CHART_VERSION>/          ← binary, sig, and all state files
#       linux-connector
#       linux-connector.sig
#       connector.config.json
#       permanent.key
#       permanent.cert.pem
#     bin -> v<CHART_VERSION>/   ← symlink to current version
# ---------------------------------------------------------------------------
BASE_DIR="/opt/cyberark/connector"
CONTAINER_DIR="${BASE_DIR}/${CONTAINER_NAME}"
VERSION_TAG="v${CHART_VERSION}"
VERSION_DIR="${CONTAINER_DIR}/${VERSION_TAG}"
BIN_LINK="${CONTAINER_DIR}/bin"
CURRENT_VER_FILE="${CONTAINER_DIR}/current_version.txt"
PREV_VER_FILE="${CONTAINER_DIR}/previous_version.txt"

USER_NAME="cyberark-dpa-connector"

# State files present after bootstrap
STATE_FILES=(
  "connector.config.json"
  "permanent.key"
  "permanent.cert.pem"
  "linux-connector.sig"
)

log() { echo "[$(date -Is)] $*" >&2; }

# Apply installer-standard permissions to a directory
secure_dir() {
  chmod -R u+rwX,go= "$1"
}

# Tighten permissions on sensitive state files after registration or upgrade.
# The connector process (owner) still needs rw to update them at runtime.
# No other user/group should have any access.
secure_state_files() {
  local dir="$1"
  # Private key — owner rw only, no one else
  [[ -f "${dir}/permanent.key" ]]          && chmod 600 "${dir}/permanent.key"
  # Config and cert — owner rw, no group/other read
  [[ -f "${dir}/connector.config.json" ]]  && chmod 600 "${dir}/connector.config.json"
  [[ -f "${dir}/permanent.cert.pem" ]]     && chmod 600 "${dir}/permanent.cert.pem"
  [[ -f "${dir}/connector.registration.json" ]] && chmod 600 "${dir}/connector.registration.json"
  # Sig file — owner read only (written once, never updated)
  [[ -f "${dir}/linux-connector.sig" ]]    && chmod 400 "${dir}/linux-connector.sig"
}

# ---------------------------------------------------------------------------
# State check — relies on PVC persistence
# ---------------------------------------------------------------------------
state_exists_on_disk() {
  local missing=0
  for f in "${STATE_FILES[@]}"; do
    [[ -f "${VERSION_DIR}/${f}" ]] || { missing=1; break; }
  done
  return ${missing}
}

# ---------------------------------------------------------------------------
# Step 1: OAuth2 access token
# ---------------------------------------------------------------------------
get_access_token() {
  log "Requesting OAuth2 token from ${TENANT_URL}/oauth2/platformtoken ..."

  local response http_code
  response=$(curl -sS -X POST \
    "${CURL_PROXY_ARGS[@]}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${SIA_USERNAME}" \
    --data-urlencode "client_secret=${SIA_PASSWORD}" \
    -w "\n%{http_code}" \
    "${TENANT_URL}/oauth2/platformtoken")

  http_code=$(echo "${response}" | tail -1)
  response=$(echo "${response}" | head -n -1)

  # HTTP 000 = curl-level failure (e.g. DNS resolution error).
  # If the tenant URL uses the .id. subdomain pattern, retry once with .my. instead.
  if [[ "${http_code}" == "000" && "${TENANT_URL}" == *".id."* ]]; then
    local fallback_url="https://${IDAPTIVE_TENANT_ID,,}.my.idaptive.app"
    log "WARNING: ${TENANT_URL} unreachable (HTTP 000) — retrying with ${fallback_url} ..."
    response=$(curl -sS -X POST \
      "${CURL_PROXY_ARGS[@]}" \
      --data-urlencode "grant_type=client_credentials" \
      --data-urlencode "client_id=${SIA_USERNAME}" \
      --data-urlencode "client_secret=${SIA_PASSWORD}" \
      -w "\n%{http_code}" \
      "${fallback_url}/oauth2/platformtoken")
    http_code=$(echo "${response}" | tail -1)
    response=$(echo "${response}" | head -n -1)
    if [[ "${http_code}" == "200" ]]; then
      log "Fallback succeeded — updating TENANT_URL to ${fallback_url}"
      TENANT_URL="${fallback_url}"
    fi
  fi

  if [[ "${http_code}" != "200" ]]; then
    log "ERROR: Token request failed with HTTP ${http_code}. Response: ${response}"
    exit 1
  fi

  local token
  token=$(echo "${response}" | jq -r '.access_token')
  if [[ -z "${token}" || "${token}" == "null" ]]; then
    log "ERROR: access_token missing in response: ${response}"
    exit 1
  fi

  echo "${token}"
}

# ---------------------------------------------------------------------------
# Step 2: Call download-ephemeral API
# ---------------------------------------------------------------------------
get_download_urls() {
  local access_token="$1"
  log "Calling download-ephemeral API ..."

  # Build base64-encoded parameters header
  local payload
  payload=$(jq -n --arg pool_id "${CONNECTOR_POOL_ID}" '{"connector_pool_id": $pool_id}')
  if [[ -n "${PROXY_URL}" ]]; then
    payload=$(echo "${payload}" | jq --arg proxy "${PROXY_URL}" '. + {"proxy_url": $proxy}')
  fi
  local params_header
  params_header=$(echo -n "${payload}" | base64 | tr -d '\n')

  local response http_code
  response=$(curl -sS -X POST \
    "${CURL_PROXY_ARGS[@]}" \
    -H "Authorization: Bearer ${access_token}" \
    -H "parameters: ${params_header}" \
    -w "\n%{http_code}" \
    "${DOWNLOAD_API_URL}")

  http_code=$(echo "${response}" | tail -1)
  response=$(echo "${response}" | head -n -1)

  if [[ "${http_code}" != "200" ]]; then
    log "ERROR: Download API failed with HTTP ${http_code}. Response: ${response}"
    exit 1
  fi

  local config_url binary_url
  config_url=$(echo "${response}" | jq -r '.configUrl')
  binary_url=$(echo "${response}" | jq -r '.binaryUrl')

  if [[ -z "${config_url}" || "${config_url}" == "null" ]]; then
    log "ERROR: configUrl missing in response: ${response}"; exit 1
  fi
  if [[ -z "${binary_url}" || "${binary_url}" == "null" ]]; then
    log "ERROR: binaryUrl missing in response: ${response}"; exit 1
  fi

  echo "${config_url}|${binary_url}"
}

# ---------------------------------------------------------------------------
# Step 3: Download binary + config tarball
# ---------------------------------------------------------------------------
download_artifacts() {
  local binary_url="$1" config_url="$2"
  mkdir -p "${VERSION_DIR}"

  log "Downloading linux-connector binary ..."
  curl -fsSL "${CURL_PROXY_ARGS[@]}" -o "${VERSION_DIR}/linux-connector" "${binary_url}"
  chmod +x "${VERSION_DIR}/linux-connector"

  local tarball="${VERSION_DIR}/connector-config.tar.gz"
  log "Downloading connector config tarball ..."
  curl -fsSL "${CURL_PROXY_ARGS[@]}" -o "${tarball}" "${config_url}"
  log "Extracting config tarball ..."

  # Auto-detect strip depth so files always land directly in VERSION_DIR
  local depth
  depth=$(tar -tzf "${tarball}" \
    | grep -v '/$' \
    | awk -F/ '{print NF-1}' \
    | sort -n | head -1)
  depth=$(( depth > 0 ? depth : 0 ))

  tar -xzf "${tarball}" -C "${VERSION_DIR}" --strip-components="${depth}"
  rm -f "${tarball}"

  secure_dir "${VERSION_DIR}"

  log "Artifacts ready in ${VERSION_DIR}:"
  ls -la "${VERSION_DIR}" >&2
}

# ---------------------------------------------------------------------------
# Step 4: Version tracking + bin symlink
# ---------------------------------------------------------------------------
setup_version_tracking() {
  mkdir -p "${CONTAINER_DIR}"
  secure_dir "${CONTAINER_DIR}"

  local prev=""
  [[ -f "${CURRENT_VER_FILE}" ]] && prev=$(cat "${CURRENT_VER_FILE}")
  echo "${prev}"        > "${PREV_VER_FILE}"
  echo "${VERSION_TAG}" > "${CURRENT_VER_FILE}"

  rm -f "${BIN_LINK}"
  ln -s "${VERSION_DIR}" "${BIN_LINK}"
  log "bin -> ${VERSION_DIR}  (current=${VERSION_TAG}  previous=${prev:-none})"
}

# ---------------------------------------------------------------------------
# Step 5: Register connector
#   - Run binary with -register; capture stdout+stderr
#   - Exit code != 0  → fatal
#   - Expect ----<token>---- in output on success (mirrors Windows installer)
# ---------------------------------------------------------------------------
register_connector() {
  log "Running linux-connector -register ..."
  local output exit_code=0
  output=$("${BIN_LINK}/linux-connector" -register 2>&1) || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    log "ERROR: connector registration failed (exit ${exit_code}):"
    log "${output}"
    exit 1
  fi

  if [[ "${output}" =~ ----(.+)---- ]]; then
    log "Connector registered successfully. "
  else
    log "Connector registered successfully."
    [[ -n "${output}" ]] && log "Registration output: ${output}"
  fi
}

# ---------------------------------------------------------------------------
# Detect upgrade mode:
#   Upgrade = existing bin symlink points to a version directory with valid
#             state files, AND it's a different version than we're about to run.
# ---------------------------------------------------------------------------
is_upgrade() {
  # No bin symlink at all → fresh install
  [[ -L "${BIN_LINK}" ]] || return 1

  local current_target
  current_target=$(readlink "${BIN_LINK}")

  # Symlink already points to the new version → restart on same version, not an upgrade
  [[ "${current_target}" == "${VERSION_DIR}" ]] && return 1

  # Check that state files exist in the EXISTING version directory
  for f in "${STATE_FILES[@]}"; do
    [[ -f "${current_target}/${f}" ]] || return 1
  done

  return 0
}

# ---------------------------------------------------------------------------
# Pure-bash semver comparison — no GNU coreutils / sort -V required.
# Returns 0 (true) if $1 is strictly less than $2, stripping any leading 'v'.
# Compares up to three dot-separated numeric components (MAJOR.MINOR.PATCH).
# ---------------------------------------------------------------------------
version_lt() {
  local a="${1#v}" b="${2#v}"
  local -a va vb
  IFS=. read -ra va <<< "${a}"
  IFS=. read -ra vb <<< "${b}"
  local i
  for i in 0 1 2; do
    local na="${va[$i]:-0}" nb="${vb[$i]:-0}"
    (( na < nb )) && return 0
    (( na > nb )) && return 1
  done
  return 1  # equal — not strictly less than
}

# ---------------------------------------------------------------------------
# Detect rollback mode:
#   Rollback = existing bin symlink points to a valid version directory AND
#              VERSION_TAG (the requested version) is older than the currently
#              symlinked version according to semver ordering.
# ---------------------------------------------------------------------------
is_rollback() {
  # No bin symlink at all → fresh install, not a rollback
  [[ -L "${BIN_LINK}" ]] || return 1

  local current_target
  current_target=$(readlink "${BIN_LINK}")

  # Symlink already points to the requested version → same version, not a rollback
  [[ "${current_target}" == "${VERSION_DIR}" ]] && return 1

  local current_tag
  current_tag=$(basename "${current_target}")

  # Check that state files exist in the current version directory
  for f in "${STATE_FILES[@]}"; do
    if [[ ! -f "${current_target}/${f}" ]]; then
      log "WARNING: is_rollback: state file '${f}' missing from '${current_target}' — skipping rollback detection"
      return 1
    fi
  done

  # If VERSION_TAG is strictly older than current_tag we are going backwards → rollback
  version_lt "${VERSION_TAG}" "${current_tag}"
}

# ---------------------------------------------------------------------------
# Upgrade: call upgrade-ephemeral API and return binary_url|checksum|additional_files_url
# Returns 1 on any failure (caller decides whether to fall back to fresh install).
# ---------------------------------------------------------------------------
get_upgrade_urls() {
  local connector_id="$1"
  local access_token="$2"
  local upgrade_url="${UPGRADE_API_BASE_URL}/${connector_id}/upgrade-ephemeral"
  log "Calling upgrade-ephemeral API: POST ${upgrade_url}"

  local response http_code
  response=$(curl -sS -X POST \
    "${CURL_PROXY_ARGS[@]}" \
    -H "Authorization: Bearer ${access_token}" \
    -w "\n%{http_code}" \
    "${upgrade_url}")

  http_code=$(echo "${response}" | tail -1)
  response=$(echo "${response}" | head -n -1)

  if [[ "${http_code}" != "200" ]]; then
    log "WARNING: upgrade-ephemeral API returned HTTP ${http_code}. Response: ${response}"
    return 1
  fi

  local binary_url binary_checksum additional_files_url
  binary_url=$(echo "${response}" | jq -r '.binary_url // empty')
  binary_checksum=$(echo "${response}" | jq -r '.binary_checksum // empty')
  additional_files_url=$(echo "${response}" | jq -r '.additional_files_url // empty')

  if [[ -z "${binary_url}" ]]; then
    log "WARNING: binary_url missing in upgrade response: ${response}"; return 1
  fi
  if [[ -z "${binary_checksum}" ]]; then
    log "WARNING: binary_checksum missing in upgrade response: ${response}"; return 1
  fi
  if [[ -z "${additional_files_url}" ]]; then
    log "WARNING: additional_files_url missing in upgrade response: ${response}"; return 1
  fi

  echo "${binary_url}|${binary_checksum}|${additional_files_url}"
}

# ---------------------------------------------------------------------------
# Validate SHA-512 checksum of a file (hex-encoded, matching Go's sha512.Sum512)
# ---------------------------------------------------------------------------
validate_checksum() {
  local file="$1" expected="$2"
  log "Validating SHA-512 checksum of $(basename "${file}") ..."

  local actual
  actual=$(sha512sum "${file}" | awk '{print $1}')

  if [[ "${actual}" != "${expected}" ]]; then
    log "ERROR: checksum mismatch!"
    log "  expected: ${expected}"
    log "  actual:   ${actual}"
    return 1
  fi

  log "Checksum OK."
}

# ---------------------------------------------------------------------------
# Perform upgrade into VERSION_DIR, copying state files from existing version
# ---------------------------------------------------------------------------
perform_upgrade() {
  local existing_bin_dir="$1"
  local binary_url="$2"
  local binary_checksum="$3"
  local additional_files_url="$4"

  log "Preparing new version directory: ${VERSION_DIR}"
  mkdir -p "${VERSION_DIR}"

  # --- Download new binary ---
  log "Downloading new linux-connector binary ..."
  if ! curl -fsSL "${CURL_PROXY_ARGS[@]}" -o "${VERSION_DIR}/linux-connector" "${binary_url}"; then
    log "ERROR: failed to download binary from ${binary_url}"
    return 1
  fi
  chmod +x "${VERSION_DIR}/linux-connector"

  # --- Validate checksum ---
  if ! validate_checksum "${VERSION_DIR}/linux-connector" "${binary_checksum}"; then
    return 1
  fi

  # --- Download additional files tarball ---
  local tarball="${VERSION_DIR}/connector-upgrade.tar.gz"
  log "Downloading additional files tarball ..."
  if ! curl -fsSL "${CURL_PROXY_ARGS[@]}" -o "${tarball}" "${additional_files_url}"; then
    log "ERROR: failed to download additional files from ${additional_files_url}"
    return 1
  fi

  log "Extracting additional files tarball ..."
  local depth
  depth=$(tar -tzf "${tarball}" \
    | grep -v '/$' \
    | awk -F/ '{print NF-1}' \
    | sort -n | head -1)
  depth=$(( depth > 0 ? depth : 0 ))
  tar -xzf "${tarball}" -C "${VERSION_DIR}" --strip-components="${depth}"
  rm -f "${tarball}"

  # --- Copy permanent state files from existing version ---
  local state_copy_files=("connector.config.json" "permanent.key" "permanent.cert.pem")
  for f in "${state_copy_files[@]}"; do
    local src="${existing_bin_dir}/${f}"
    if [[ -f "${src}" ]]; then
      log "Copying ${f} from existing version ..."
      cp "${src}" "${VERSION_DIR}/${f}"
    else
      log "WARNING: ${f} not found in existing version at ${src}"
    fi
  done

  secure_dir "${VERSION_DIR}"

  log "Upgrade artifacts ready in ${VERSION_DIR}:"
  ls -la "${VERSION_DIR}" >&2
}

# ---------------------------------------------------------------------------
# Rollback: restore symlink and version tracking files to the previous version
# ---------------------------------------------------------------------------
rollback() {
  local previous_dir="$1"
  log "ROLLBACK: restoring bin symlink to ${previous_dir}"
  rm -f "${BIN_LINK}"
  ln -s "${previous_dir}" "${BIN_LINK}"

  # Restore version tracking files so they reflect the running version
  local previous_tag
  previous_tag=$(basename "${previous_dir}")
  echo "${previous_tag}" > "${CURRENT_VER_FILE}"
  # previous_version.txt held whatever was current before this failed upgrade attempt;
  # that value is still in PREV_VER_FILE from setup_version_tracking, so leave it as-is.
  log "current_version.txt restored to ${previous_tag}"

  log "Rollback complete. Starting existing connector version ..."
  exec "${BIN_LINK}/linux-connector"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "=== SIA Connector startup | container=${CONTAINER_NAME} | version=${VERSION_TAG} | user=${USER_NAME} ==="

  # Capture the existing bin symlink target before setup_version_tracking changes it
  local existing_bin_dir=""
  if [[ -L "${BIN_LINK}" ]]; then
    existing_bin_dir=$(readlink "${BIN_LINK}")
  fi

  # Read previous version BEFORE setup_version_tracking overwrites tracking files
  local prev_tag=""
  [[ -f "${PREV_VER_FILE}" ]] && prev_tag=$(cat "${PREV_VER_FILE}")

  # ---------------------------------------------------------------------------
  # ROLLBACK PATH — must be checked before setup_version_tracking so that
  # tracking files are not corrupted when we deny an unsupported rollback.
  # ---------------------------------------------------------------------------
  if is_rollback; then
    local existing_tag
    existing_tag=$(basename "${existing_bin_dir}")
    log "Helm rollback detected: existing version=${existing_tag} → requested version=${VERSION_TAG}"

    if [[ "${VERSION_TAG}" == "${prev_tag}" ]]; then
      local prev_dir="${CONTAINER_DIR}/${prev_tag}"
      if [[ -d "${prev_dir}" ]]; then
        log "Rolling back to immediate previous version ${VERSION_TAG} ..."
        setup_version_tracking
        rollback "${prev_dir}"
        # rollback() calls exec — execution never reaches here
      else
        log "ERROR: Helm rollback to ${VERSION_TAG} requested, but version directory '${prev_dir}' was not found on the PVC."
        log "Remaining on current version ${existing_tag}. Resolve the missing directory before retrying the rollback."
        exec "${existing_bin_dir}/linux-connector"
      fi
    else
      log "ERROR: Helm rollback to ${VERSION_TAG} is not supported."
      log "Only rollback to the immediate previous version is allowed (previous version: ${prev_tag:-none})."
      log "To roll back, target Helm release revision that corresponds to version ${prev_tag:-none}."
      log "Remaining on current version ${existing_tag} unchanged."
      exec "${existing_bin_dir}/linux-connector"
    fi
  fi

  # Detect upgrade mode before we touch the symlink
  local upgrade_mode=false
  if is_upgrade; then
    upgrade_mode=true
    log "Upgrade mode detected: existing version=${existing_bin_dir} → new version=${VERSION_DIR}"
  fi

  setup_version_tracking

  # access_token may be obtained in the upgrade block and reused in the normal path below
  local access_token=""

  # ---------------------------------------------------------------------------
  # UPGRADE PATH
  # ---------------------------------------------------------------------------
  if [[ "${upgrade_mode}" == "true" ]]; then
    log "Starting upgrade process ..."

    # Read connector_id from existing version's connector.config.json
    local config_file="${existing_bin_dir}/connector.config.json"
    local connector_id=""
    if [[ -f "${config_file}" ]]; then
      connector_id=$(jq -r '.Id // empty' "${config_file}" 2>/dev/null || true)
    fi

    if [[ -z "${connector_id}" ]]; then
      log "WARNING: could not read connector ID from ${config_file} — will fall back to fresh install."
    else
      log "Connector ID: ${connector_id}"
    fi

    # Get OAuth2 token (reused by the fresh-install fallback path below if needed)
    access_token=$(get_access_token)

    # Try the upgrade-ephemeral API path first
    if [[ -n "${connector_id}" ]]; then
      local upgrade_urls=""
      if upgrade_urls=$(get_upgrade_urls "${connector_id}" "${access_token}"); then
        local binary_url="${upgrade_urls%%|*}"
        local rest="${upgrade_urls#*|}"
        local binary_checksum="${rest%%|*}"
        local additional_files_url="${rest##*|}"

        if perform_upgrade "${existing_bin_dir}" "${binary_url}" "${binary_checksum}" "${additional_files_url}"; then
          log "Upgrade via upgrade-ephemeral API successful."
          secure_state_files "${VERSION_DIR}"
          # connector_id doesn't change on upgrade — reuse the one read from the existing config
          [[ -n "${connector_id}" ]] && publish_connector_id "${connector_id}"
          exec "${BIN_LINK}/linux-connector"
        else
          log "WARNING: upgrade artifact download/extraction failed — falling back to fresh install."
          rm -rf "${VERSION_DIR}"
        fi
      else
        log "WARNING: upgrade-ephemeral API unavailable — falling back to fresh install."
      fi
    fi

    # ---------------------------------------------------------------------------
    # Upgrade API failed or connector ID unknown: perform a fresh install.
    # This re-downloads and re-registers the connector under the new version,
    # keeping the cluster healthy rather than running an outdated binary.
    # ---------------------------------------------------------------------------
    log "Falling back to fresh install for version ${VERSION_TAG} ..."
  fi

  # ---------------------------------------------------------------------------
  # NORMAL PATH (fresh install or restart on same version)
  # ---------------------------------------------------------------------------
  if state_exists_on_disk; then
    log "State found on PVC — skipping download and registration."

    # Re-publish connector ID in case the ConfigMap was lost (pod restart, NS recreation, etc.)
    local existing_id
    existing_id=$(jq -r '.Id // empty' "${VERSION_DIR}/connector.config.json" 2>/dev/null || true)
    [[ -n "${existing_id}" ]] && publish_connector_id "${existing_id}"

    log "Starting connector ..."
    exec "${BIN_LINK}/linux-connector"
  fi

  log "No existing state on PVC — bootstrapping ..."

  # Reuse token from upgrade block if already obtained, otherwise fetch now
  [[ -z "${access_token}" ]] && access_token=$(get_access_token)

  local urls
  urls=$(get_download_urls "${access_token}")
  local config_url="${urls%%|*}"
  local binary_url="${urls##*|}"

  download_artifacts "${binary_url}" "${config_url}"
  register_connector

  if ! state_exists_on_disk; then
    log "ERROR: expected state files missing after registration in ${VERSION_DIR}"
    exit 1
  fi

  # Publish connector ID to ConfigMap for pre-delete hook
  local registered_id
  registered_id=$(jq -r '.Id // empty' "${VERSION_DIR}/connector.config.json" 2>/dev/null || true)
  [[ -n "${registered_id}" ]] && publish_connector_id "${registered_id}"

  secure_state_files "${VERSION_DIR}"
  log "Starting connector ..."
  exec "${BIN_LINK}/linux-connector"
}

main "$@"
