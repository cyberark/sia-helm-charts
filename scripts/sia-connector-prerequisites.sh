#!/usr/bin/env bash
# =============================================================================
# CyberArk SIA Kubernetes Connector — prerequisite checks
#
# Validates that this machine, your cluster, your registry and your tenant
# parameters are ready to install the connector. It installs nothing.
#
#     ./scripts/sia-connector-prerequisites.sh --config ./sia-connector.env
#
# Run it as often as you like, before you have credentials or a registry ready.
# Its transcript is a useful thing to attach to a support ticket: it captures
# your whole environment without exposing secrets.
#
# See docs/prerequisites.md for what each check means and how to act on it.
# =============================================================================

set -euo pipefail
umask 077

# ---------------------------------------------------------------------------
# The checks themselves live in sia-connector-common.sh.
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

usage() {
  cat <<'EOF'
CyberArk SIA Kubernetes Connector — prerequisite checks

Validates this machine, your cluster, your registry and your tenant parameters
against everything the connector install needs. Installs nothing.

  ./scripts/sia-connector-prerequisites.sh --config ./sia-connector.env

Exits 0 when every prerequisite is met, 1 if any check fails. Warnings are
advisory and do not cause a non-zero exit.

Tenant parameters (from the SIA Admin Portal)
  --root-domain <domain>          Your SIA environment domain (e.g. cyberark.cloud)
  --idaptive-tenant-id <id>       Identity tenant ID
  --tenant-subdomain <name>       Your tenant subdomain

Your infrastructure
  --registry <host[/path]>        Your container registry
  --registry-username <user>      For registries needing docker login
  --registry-password-file <path> Password/token file for the above
  --namespace <ns>                Default: sia-k8s-connector
  --image-name <name>             Default: cms-k8s-connector
  --image-tag <tag>               Default: latest
  --platform <os/arch>            Default: linux/amd64; checked against your nodes
  --dockerfile-dir <path>         Directory holding the connector Dockerfile
  --config <path>                 Read any of the above as KEY=value
  --log-file <path>               Default: ./sia-connector-prerequisites-<timestamp>.log

Narrowing what is checked
  --skip-build                    Image is already built and pushed: skips the
                                  docker, Dockerfile and registry checks
  --skip-pull-secret              Registry is public, or the secret already exists
  -h, --help                      This message

--check-only and --yes are accepted and ignored: this script never changes
anything and never prompts, so both are already true of it.
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
    # Accepted and ignored: both are already true of this script.
    --check-only)             CHECK_ONLY=true; shift ;;
    --yes|-y)                 ASSUME_YES=true; shift ;;
    -h|--help)                usage; exit 0 ;;

    *) die "unknown argument: $1  (try --help)" ;;
  esac
done

setup_transcript "sia-connector-prerequisites"

log "${C_BOLD}CyberArk SIA Kubernetes Connector — prerequisite checks v${SIA_TOOLS_VERSION}${C_RESET}"
log "${C_DIM}$(date -u +'%Y-%m-%dT%H:%M:%SZ')  ·  transcript: ${LOG_FILE}${C_RESET}"
log "${C_DIM}Read-only: nothing is installed, and nothing is left behind.${C_RESET}"

run_prerequisite_checks

if (( FAIL_COUNT > 0 )); then
  log ""
  log "${C_RED}Prerequisites not met.${C_RESET} Nothing was created."
  log "Fix the items marked [FAIL] above and run this again."
  log "Transcript: ${LOG_FILE}   (safe to attach to a support ticket)"
  exit 1
fi

log ""
log "${C_GREEN}All prerequisites met.${C_RESET} No changes were made."
(( WARN_COUNT > 0 )) && log "Review the ${WARN_COUNT} warning(s) above."
log ""
log "Transcript: ${LOG_FILE}"
exit 0
