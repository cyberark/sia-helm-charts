#!/usr/bin/env bash
# =============================================================================
# CyberArk SIA Kubernetes Connector — prerequisite checks
#
# Validates that this machine, your cluster, your registry and your tenant
# parameters are ready to install the connector. It installs nothing.
#
#     ./sia-connector-prerequisites.sh --config ./sia-connector.env
#
# Run it as often as you like, before you have credentials or a registry ready.
# The only object it creates anywhere is a throwaway connectivity-probe pod,
# which it deletes again — pass --skip-egress-check to avoid even that.
#
# Its transcript is a useful thing to attach to a support ticket: it captures
# your whole environment without exposing secrets.
#
# See PREREQUISITES.md for what each check means and how to act on it.
# =============================================================================

set -euo pipefail
umask 077

# ---------------------------------------------------------------------------
# The checks themselves live in sia-connector-common.sh, shared with the
# installer so the two can never disagree about what "ready" means.
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

  ./sia-connector-prerequisites.sh --config ./sia-connector.env

Exits 0 when every prerequisite is met, 1 if any check fails. Warnings are
advisory and do not cause a non-zero exit.

Tenant parameters (from the SIA Admin Portal)
  --root-domain <domain>          Your SIA environment domain (e.g. cyberark.cloud)
  --idaptive-tenant-id <id>       Identity tenant ID
  --tenant-subdomain <name>       Your tenant subdomain
  --connector-pool-id <uuid>      Connector Pool ID
  --username <user>               Service-account username

No password is needed. These checks never authenticate; they confirm the
parameters are present and well-formed, and that the endpoints they imply are
reachable from inside your cluster.

Your infrastructure
  --registry <host[/path]>        Your container registry
  --registry-username <user>      For registries needing docker login
  --registry-password-file <path> Password/token file for the above
  --namespace <ns>                Default: sia-k8s-connector
  --replicas <n>                  Default: 1
  --image-name <name>             Default: cms-k8s-connector
  --image-tag <tag>               Default: latest
  --chart-ref <url|file.tgz>      A chart archive or a Helm repo URL. Omit it and
                                  the newest archive in this distribution is used
  --chart-version <ver>           Default: newest available
  --storage-class <name>          Required if the cluster has no default
  --proxy <url>                   Outbound HTTP/HTTPS proxy for the connector
  --platform <os/arch>            Default: linux/amd64; checked against your nodes
  --dockerfile-dir <path>         Directory holding the connector Dockerfile
  --config <path>                 Read any of the above as KEY=value
  --log-file <path>               Default: ./sia-connector-prerequisites-<timestamp>.log

Narrowing what is checked
  --skip-build                    Image is already built and pushed: skips the
                                  docker, Dockerfile and registry checks
  --skip-pull-secret              Registry is public, or the secret already exists
  --skip-egress-check             Do not create the throwaway probe pod
  -h, --help                      This message

One sia-connector.env serves this script and any later deployment step. Keys
only an install needs (PULL_SECRET, CLUSTER_NAME, BASE_IMAGE, KUBECTL_VERSION,
RELEASE) are simply ignored here.

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

    # Install-only flags. Rejecting them with a reason beats "unknown argument"
    # for someone who reused a deployment command line.
    --release|--pull-secret|--cluster-name|--kubectl-version|--base-image)
      die "$1 affects an install only, not the prerequisite checks.
       Drop it, or pass it to whichever script performs your install." ;;
    --password-file|--password|--password=*)
      die "no password is needed to check prerequisites — these checks never authenticate.
       Supply the credential at install time instead." ;;

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
