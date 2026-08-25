#!/usr/bin/env bash
# helm sia-maintenance — manage SIA Kubernetes Connector maintenance mode.
#
# Reads credentials from the sia-auth Secret in the target namespace and calls
# the SIA API directly from the local machine. No Helm revision is created.
#
# Usage:
#   helm -n <namespace> sia-maintenance enable  [options]
#   helm -n <namespace> sia-maintenance disable [options]
#
# Options:
#   -n, --namespace <ns>      Kubernetes namespace (required)
#   --secret <name>           Name of the sia-auth Secret (default: sia-auth)
#   --root-domain <domain>    SIA root domain (default: cyberark.cloud;
#                             overrides ROOT_DOMAIN env var)
#   -v, --verbose             Print extra debug output
#   -h, --help                Show this help
#
# Environment:
#   ROOT_DOMAIN   Alternative way to set the root domain

set -eo pipefail

PROGNAME="helm sia-maintenance"
COMMAND=""
NAMESPACE="${HELM_NAMESPACE:-}"
SECRET_NAME="sia-auth"
ROOT_DOMAIN="${ROOT_DOMAIN:-cyberark.cloud}"
VERBOSE=false

# ─── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[$(date -Iseconds)] $*" >&2; }
vlog() { $VERBOSE && log "$*" || true; }
die()  { log "ERROR: $*"; exit 1; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found in PATH."
}

usage() {
  cat <<EOF
Usage: helm -n <namespace> sia-maintenance <enable|disable> [options]

Commands:
  enable   Put all connectors in the namespace into maintenance mode
  disable  Take all connectors out of maintenance mode

Options:
  -n, --namespace <ns>      Kubernetes namespace — pass to helm, not the plugin
                            (Helm sets HELM_NAMESPACE which the plugin reads)
  --secret <name>           Name of the sia-auth Secret (default: sia-auth)
  --root-domain <domain>    SIA root domain (default: cyberark.cloud)
  -v, --verbose             Print extra debug output
  -h, --help                Show this help

Environment variables:
  ROOT_DOMAIN               Alternative to --root-domain

Examples:
  helm -n sia-k8s-connector sia-maintenance enable
  helm -n sia-k8s-connector sia-maintenance disable
EOF
}

# ─── argument parsing ─────────────────────────────────────────────────────────

if [ $# -eq 0 ]; then
  usage
  exit 0
fi

COMMAND="$1"
shift

case "${COMMAND}" in
  enable|disable) ;;
  -h|--help) usage; exit 0 ;;
  *) die "Unknown command '${COMMAND}'. Run '${PROGNAME} --help' for usage." ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="$2"; shift 2 ;;
    --secret)
      SECRET_NAME="$2"; shift 2 ;;
    --root-domain)
      ROOT_DOMAIN="$2"; shift 2 ;;
    -v|--verbose)
      VERBOSE=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown option '$1'. Run '${PROGNAME} --help' for usage." ;;
  esac
done

[ -n "${NAMESPACE}" ] || die "--namespace / -n is required."

# ─── prerequisites ────────────────────────────────────────────────────────────

require_tool kubectl
require_tool curl
require_tool jq
require_tool base64

# ─── read credentials from the sia-auth Secret ────────────────────────────────

read_secret_field() {
  local field="$1"
  local encoded
  encoded=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
    -o jsonpath="{.data.${field}}" 2>/dev/null) || true
  [ -n "${encoded}" ] || return 1
  printf '%s' "${encoded}" | base64 -d
}

log "Reading credentials from Secret '${SECRET_NAME}' in namespace '${NAMESPACE}' ..."

SIA_USERNAME=$(read_secret_field username) \
  || die "Secret '${SECRET_NAME}' not found or missing 'username' key in namespace '${NAMESPACE}'."
SIA_PASSWORD=$(read_secret_field password) \
  || die "Secret '${SECRET_NAME}' missing 'password' key."
IDAPTIVE_TENANT_ID=$(read_secret_field idaptiveTenantId) \
  || die "Secret '${SECRET_NAME}' missing 'idaptiveTenantId' key."
TENANT_SUBDOMAIN=$(read_secret_field tenantSubdomain) \
  || die "Secret '${SECRET_NAME}' missing 'tenantSubdomain' key."
DEV_API_ENDPOINT=$(read_secret_field devApiEndpoint 2>/dev/null) || DEV_API_ENDPOINT=""

vlog "Tenant ID: ${IDAPTIVE_TENANT_ID}, subdomain: ${TENANT_SUBDOMAIN}"

# ─── build API URLs ───────────────────────────────────────────────────────────

# Dev override for the internal AAQ5985 / aaq5985 tenant
if [ "${IDAPTIVE_TENANT_ID}" = "AAQ5985" ] || [ "${IDAPTIVE_TENANT_ID}" = "aaq5985" ]; then
  TOKEN_URL="https://aaq5985.my.idaptive.qa/oauth2/platformtoken"
  vlog "Using idaptive.qa token URL (dev override for AAQ5985 tenant)."
else
  TOKEN_URL="https://${IDAPTIVE_TENANT_ID}.id.${ROOT_DOMAIN}/oauth2/platformtoken"
fi

if [ -n "${DEV_API_ENDPOINT}" ]; then
  CONNECTORS_API_BASE="${DEV_API_ENDPOINT}/api/connectors"
  vlog "Using dev API endpoint: ${DEV_API_ENDPOINT}"
else
  CONNECTORS_API_BASE="https://${TENANT_SUBDOMAIN}.dpa.${ROOT_DOMAIN}/api/connectors"
fi

log "Token URL:      ${TOKEN_URL}"
log "Connectors API: ${CONNECTORS_API_BASE}"

# ─── obtain OAuth2 access token ───────────────────────────────────────────────

log "Requesting OAuth2 token ..."

TOKEN_RESPONSE=$(curl -sS -X POST \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${SIA_USERNAME}" \
  --data-urlencode "client_secret=${SIA_PASSWORD}" \
  -w "\n%{http_code}" \
  "${TOKEN_URL}" 2>&1) || true

TOKEN_HTTP_CODE=$(printf '%s\n' "${TOKEN_RESPONSE}" | tail -1)
TOKEN_RESPONSE=$(printf '%s\n' "${TOKEN_RESPONSE}" | sed '$d')

# DNS resolution failure: retry once with <tenant>.my.idaptive.app
if [ "${TOKEN_HTTP_CODE}" = "000" ] && printf '%s' "${TOKEN_URL}" | grep -q '\.id\.'; then
  FALLBACK_TOKEN_URL="https://$(printf '%s' "${IDAPTIVE_TENANT_ID}" | tr '[:upper:]' '[:lower:]').my.idaptive.app/oauth2/platformtoken"
  log "WARNING: ${TOKEN_URL} unreachable (DNS error) — retrying with ${FALLBACK_TOKEN_URL} ..."
  TOKEN_RESPONSE=$(curl -sS -X POST \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${SIA_USERNAME}" \
    --data-urlencode "client_secret=${SIA_PASSWORD}" \
    -w "\n%{http_code}" \
    "${FALLBACK_TOKEN_URL}" 2>&1) || true
  TOKEN_HTTP_CODE=$(printf '%s\n' "${TOKEN_RESPONSE}" | tail -1)
  TOKEN_RESPONSE=$(printf '%s\n' "${TOKEN_RESPONSE}" | sed '$d')
  if [ "${TOKEN_HTTP_CODE}" = "200" ]; then
    log "Fallback succeeded — using ${FALLBACK_TOKEN_URL}"
    TOKEN_URL="${FALLBACK_TOKEN_URL}"
  fi
fi

ACCESS_TOKEN=$(printf '%s' "${TOKEN_RESPONSE}" | jq -r '.access_token // empty' 2>/dev/null || true)

if [ -z "${ACCESS_TOKEN}" ]; then
  die "Failed to obtain access token. Response: ${TOKEN_RESPONSE}"
fi
log "Access token obtained."

# ─── discover connectors in the namespace ─────────────────────────────────────

# entrypoint.sh creates a ConfigMap named '<pod>-connector-id' for each
# registered connector replica. We list all ConfigMaps in the namespace and
# filter those whose name ends with '-connector-id'.

log "Discovering connector IDs in namespace '${NAMESPACE}' ..."

CM_JSON=$(kubectl get configmaps -n "${NAMESPACE}" -o json 2>/dev/null) || \
  die "Failed to list ConfigMaps in namespace '${NAMESPACE}'."

CONNECTOR_MAP=$(printf '%s' "${CM_JSON}" | jq -r '
  .items[]
  | select(.metadata.name | test("-connector-id$"))
  | (.metadata.name | rtrimstr("-connector-id")) + " " + (.data.connector_id // "")
' 2>/dev/null) || true

if [ -z "${CONNECTOR_MAP}" ]; then
  log "No registered connectors found in namespace '${NAMESPACE}'."
  log "Connectors register themselves on first start — make sure the pods are running."
  exit 0
fi

CONNECTOR_COUNT=$(printf '%s\n' "${CONNECTOR_MAP}" | grep -c '.' || true)
log "Found ${CONNECTOR_COUNT} registered connector(s)."

# ─── perform action on each connector ────────────────────────────────────────

FAILED=0

case "${COMMAND}" in

  # ── enable ────────────────────────────────────────────────────────────────

  enable)
    BODY='{"maintenance": true}'
    while IFS=" " read -r POD_NAME CONNECTOR_ID; do
      [ -n "${CONNECTOR_ID}" ] || { log "WARNING: no connector_id for '${POD_NAME}' — skipping."; FAILED=1; continue; }
      if ! kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -q .; then
        log "WARNING: pod '${POD_NAME}' not found — skipping stale connector ${CONNECTOR_ID}."
        continue
      fi
      vlog "Enabling maintenance for ${POD_NAME} (${CONNECTOR_ID}) ..."

      HTTP_STATUS=$(curl -sS -X PUT \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${BODY}" \
        -o /tmp/sia_maint_resp.json \
        -w "%{http_code}" \
        "${CONNECTORS_API_BASE}/${CONNECTOR_ID}/maintenance" \
        2>/tmp/sia_maint_curl_err.txt) || true
      CURL_ERR=$(cat /tmp/sia_maint_curl_err.txt 2>/dev/null || true)
      RESP=$(cat /tmp/sia_maint_resp.json 2>/dev/null || true)

      if [ -n "${CURL_ERR}" ]; then
        log "WARNING: curl error for ${POD_NAME} / ${CONNECTOR_ID}: ${CURL_ERR}"
        log "         Check that '${CONNECTORS_API_BASE}' is reachable from this machine."
        log "         If it is a cluster-internal endpoint, the plugin cannot be used from outside the cluster."
        FAILED=1
        continue
      fi

      if [ "${HTTP_STATUS}" != "200" ]; then
        log "WARNING: failed to enable maintenance for ${POD_NAME} / ${CONNECTOR_ID} (HTTP ${HTTP_STATUS}). Response: ${RESP}"
        FAILED=1
        continue
      fi

      CONFIRMED=$(printf '%s' "${RESP}" | jq -r 'if .maintenance != null then (.maintenance | tostring) else "" end' 2>/dev/null || true)
      if [ "${CONFIRMED}" = "true" ]; then
        log "  [OK] ${POD_NAME} (${CONNECTOR_ID}): maintenance ON"
      else
        log "WARNING: ${POD_NAME} / ${CONNECTOR_ID} returned maintenance=${CONFIRMED}, expected true. Response: ${RESP}"
        FAILED=1
      fi
    done <<< "${CONNECTOR_MAP}"
    ;;

  # ── disable ───────────────────────────────────────────────────────────────

  disable)
    BODY='{"maintenance": false}'
    while IFS=" " read -r POD_NAME CONNECTOR_ID; do
      [ -n "${CONNECTOR_ID}" ] || { log "WARNING: no connector_id for '${POD_NAME}' — skipping."; FAILED=1; continue; }
      if ! kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -q .; then
        log "WARNING: pod '${POD_NAME}' not found — skipping stale connector ${CONNECTOR_ID}."
        continue
      fi
      vlog "Disabling maintenance for ${POD_NAME} (${CONNECTOR_ID}) ..."

      HTTP_STATUS=$(curl -sS -X PUT \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${BODY}" \
        -o /tmp/sia_maint_resp.json \
        -w "%{http_code}" \
        "${CONNECTORS_API_BASE}/${CONNECTOR_ID}/maintenance" \
        2>/tmp/sia_maint_curl_err.txt) || true
      CURL_ERR=$(cat /tmp/sia_maint_curl_err.txt 2>/dev/null || true)
      RESP=$(cat /tmp/sia_maint_resp.json 2>/dev/null || true)

      if [ -n "${CURL_ERR}" ]; then
        log "WARNING: curl error for ${POD_NAME} / ${CONNECTOR_ID}: ${CURL_ERR}"
        log "         Check that '${CONNECTORS_API_BASE}' is reachable from this machine."
        log "         If it is a cluster-internal endpoint, the plugin cannot be used from outside the cluster."
        FAILED=1
        continue
      fi

      if [ "${HTTP_STATUS}" != "200" ]; then
        log "WARNING: failed to disable maintenance for ${POD_NAME} / ${CONNECTOR_ID} (HTTP ${HTTP_STATUS}). Response: ${RESP}"
        FAILED=1
        continue
      fi

      CONFIRMED=$(printf '%s' "${RESP}" | jq -r 'if .maintenance != null then (.maintenance | tostring) else "" end' 2>/dev/null || true)
      if [ "${CONFIRMED}" = "false" ]; then
        log "  [OK] ${POD_NAME} (${CONNECTOR_ID}): maintenance OFF"
      else
        log "WARNING: ${POD_NAME} / ${CONNECTOR_ID} returned maintenance=${CONFIRMED}, expected false. Response: ${RESP}"
        FAILED=1
      fi
    done <<< "${CONNECTOR_MAP}"
    ;;

esac

# ─── final status ─────────────────────────────────────────────────────────────

if [ "${FAILED}" != "0" ]; then
  log "One or more connectors failed to toggle maintenance mode."
  exit 1
fi

case "${COMMAND}" in
  enable)  log "Done. All connectors are now in maintenance mode. Sessions will drain before new upgrades." ;;
  disable) log "Done. All connectors are back online." ;;
esac
