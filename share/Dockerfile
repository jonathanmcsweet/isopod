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

# Reset to root so these layers (and the sshd entrypoint) work no matter what
# USER a --dockerfile base ended on. In an isopod box the privilege model is
# fixed by isopod regardless: sshd is PID 1 as root and you log in as the
# unprivileged ISOPOD_USER. Tighten that user with --no-sudo — not the base
# image's USER, which isopod supersedes.
USER root

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

# Entrypoint: shipped as share/isopod-entrypoint and COPYed in (not generated
# inline) so it stays an independently lintable script. It runs the bootstrap
# (host keys, authorized key, sudo policy) before sshd; see that file. The
# in-box user is baked into /etc/isopod-user for the entrypoint to read.
COPY isopod-entrypoint /usr/local/bin/isopod-entrypoint
RUN printf '%s\n' "$ISOPOD_USER" > /etc/isopod-user \
 && chmod +x /usr/local/bin/isopod-entrypoint
EXPOSE 22
CMD ["/usr/local/bin/isopod-entrypoint"]
