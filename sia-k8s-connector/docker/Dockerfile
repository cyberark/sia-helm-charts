ARG BASE_IMAGE
FROM ${BASE_IMAGE}

RUN apk add --no-cache bash curl ca-certificates jq shadow

# kubectl
ARG KUBECTL_VERSION=v1.30.0
RUN curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    chmod +x /usr/local/bin/kubectl

ARG USER_NAME=cyberark-dpa-connector
ARG USER_UID=1000
ARG INSTALL_DIR=/opt/cyberark/connector
ARG ROOT_DOMAIN

ENV ROOT_DOMAIN=${ROOT_DOMAIN}

# Create service user — mirrors the Linux installer logic:
#   - If user already exists, validate it has /sbin/nologin shell
#   - If not, create with no home dir and no login shell
RUN set -e; \
    if id "${USER_NAME}" >/dev/null 2>&1; then \
      echo "User ${USER_NAME} already exists."; \
      if grep "^${USER_NAME}" /etc/passwd | grep -q "/sbin/nologin$"; then \
        echo "User ${USER_NAME} is valid (nologin shell)."; \
      else \
        echo "ERROR: User ${USER_NAME} exists but does not have /sbin/nologin shell. Aborting." >&2; \
        exit 1; \
      fi; \
    else \
      if getent passwd "${USER_UID}" >/dev/null 2>&1; then \
        echo "ERROR: UID ${USER_UID} is already taken by $(getent passwd ${USER_UID} | cut -d: -f1). Aborting." >&2; \
        exit 1; \
      fi; \
      echo "Creating user ${USER_NAME} ..."; \
      useradd "${USER_NAME}" -u "${USER_UID}" -d /nonexistent -s /sbin/nologin && \
        echo "User ${USER_NAME} created." || { \
        echo "ERROR: Failed to create user ${USER_NAME}." >&2; \
        exit 1; \
      }; \
    fi; \
    mkdir -p "${INSTALL_DIR}" && \
    chown -R "${USER_NAME}" "${INSTALL_DIR}" && \
    chmod -R u+rwX,go=      "${INSTALL_DIR}"

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Shell aliases — available via kubectl exec without granting login access.
# Bash reads $HOME/.bashrc for interactive non-login shells.
# We point HOME to a read-only config dir (not a real user home) so the
# aliases load on exec while /sbin/nologin stays intact.
COPY connector-aliases.sh /etc/cyberark-dpa-connector/.bashrc
RUN chmod 444 /etc/cyberark-dpa-connector/.bashrc

ENV HOME=/etc/cyberark-dpa-connector

USER ${USER_UID}

ENTRYPOINT ["/entrypoint.sh"]
