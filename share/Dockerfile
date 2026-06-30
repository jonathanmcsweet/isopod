# isopod sandbox base image.
#
# A standard Dockerfile, built unchanged by both `docker build` and
# `podman build`. The isopod CLI builds it with two build args:
#   ISOPOD_BASE  the Debian/Ubuntu base to layer on (default below; --image)
#   ISOPOD_USER  the unprivileged in-box user (must match CONTAINER_USER in the
#                isopod script)
# It installs an SSH server and common tooling, creates the in-box user, locks
# sshd down to key-only single-user access, and runs sshd as PID 1.
ARG ISOPOD_BASE=docker.io/library/debian:bookworm-slim
FROM ${ISOPOD_BASE}
ARG ISOPOD_USER=dev
ENV DEBIAN_FRONTEND=noninteractive

# Essentials: sshd (remote access) plus git and common CLI tooling.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server sudo git curl wget ca-certificates \
      python3 nano less procps tar gzip unzip xz-utils locales \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd

# Unprivileged in-box user (skip if the base image already has it).
RUN id -u "$ISOPOD_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ISOPOD_USER"

# Lock down sshd: key-only auth, single user, no root login. Double-quote the
# AllowUsers line so the build arg expands in the container shell.
RUN printf '%s\n' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' \
      "AllowUsers $ISOPOD_USER" \
      'X11Forwarding no' \
      'AllowAgentForwarding no' \
      'ClientAliveInterval 60' \
      > /etc/ssh/sshd_config.d/90-isopod.conf \
 && grep -q 'Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config \
      || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config

# Entrypoint: regenerate host keys on first boot so every box is unique, then
# run sshd in the foreground as PID 1.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'if [ ! -f /etc/ssh/.isopod-host-keys ]; then' \
      '  rm -f /etc/ssh/ssh_host_*' \
      '  ssh-keygen -A >/dev/null' \
      '  touch /etc/ssh/.isopod-host-keys' \
      'fi' \
      'mkdir -p /run/sshd' \
      'exec /usr/sbin/sshd -D -e' \
      > /usr/local/bin/isopod-entrypoint \
 && chmod +x /usr/local/bin/isopod-entrypoint
EXPOSE 22
CMD ["/usr/local/bin/isopod-entrypoint"]
