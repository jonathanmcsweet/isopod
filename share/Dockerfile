# isopod sandbox base image.
#
# A standard Dockerfile, built unchanged by both `docker build` and
# `podman build`. The isopod CLI builds it with two build args:
#   ISOPOD_BASE       the Debian/Ubuntu base to layer on (default below; --image)
#   ISOPOD_USER       the unprivileged in-box user (must match CONTAINER_USER in
#                     the isopod script)
#   ISOPOD_SSHD_PORT  the guest port sshd listens on (must match BOX_SSHD_PORT in
#                     the isopod script). A non-privileged port so a virtio-net
#                     microVM (krun + passt) can forward to it — passt does not
#                     forward to a privileged guest port like 22.
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
ARG ISOPOD_SSHD_PORT=2222
# Opt-in dev/test toolchain (nested engines + lint/test tools). Off by default so
# the sandbox base stays minimal; `isopod create --dev` sets it to 1. See below.
ARG ISOPOD_DEV_TOOLS=0
# Opt-in nested container engine (`isopod create --nested-containers`). Off by
# default so the sandbox base stays minimal; see the RUN block below.
ARG ISOPOD_NESTED=0
ENV DEBIAN_FRONTEND=noninteractive

# Essentials: sshd (remote access) plus git and common CLI tooling.
# Package versions are intentionally NOT pinned: this is a disposable dev-sandbox
# base, not a release artifact, so it tracks the base image's current security
# updates rather than freezing (and needing constant bumping). Reproducibility is
# not a goal here; pin ISOPOD_BASE to a digest if you need a fixed base.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server sudo git curl wget ca-certificates \
      python3 nano less procps tar gzip unzip xz-utils locales \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd

# Unprivileged in-box user (skip if the base image already has it).
RUN id -u "$ISOPOD_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ISOPOD_USER"

# Dev/test toolchain — installed ONLY when ISOPOD_DEV_TOOLS=1 (isopod create
# --dev). It is NOT in the default image: the docker group, a nested docker/
# podman, and the lint/test packages are attack surface a normal sandbox does not
# need. It exists so a box can run isopod's own test suite (test/run.sh): lint
# (shellcheck, shfmt), python checks (pyflakes), interactive tests (pexpect), nft
# for the egress template parse check, and both engines for the RUN_LIVE live
# suite — rootless podman (uidmap/slirp4netns/fuse-overlayfs) and docker.io (CLI +
# dockerd; starting dockerd needs a microVM or otherwise privileged box, the CLI
# alone works anywhere). Nested podman also needs /dev/fuse and /dev/net/tun
# readable in the box at runtime, and its storage on a non-FUSE filesystem.
# The subordinate IDs cover a base image that already had the user; the docker
# group lets the user reach a dockerd started via sudo without further setup.
RUN if [ "$ISOPOD_DEV_TOOLS" = "1" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends \
           shellcheck shfmt python3-pexpect python3-pyflakes nftables \
           podman uidmap slirp4netns fuse-overlayfs docker.io \
      && rm -rf /var/lib/apt/lists/* \
      && { grep -q "^$ISOPOD_USER:" /etc/subuid \
           || usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$ISOPOD_USER"; } \
      && usermod -aG docker "$ISOPOD_USER"; \
    fi

# Rootless nested podman — installed ONLY when ISOPOD_NESTED=1 (isopod create
# --nested-containers). A nested engine is real added attack surface inside the
# box, so it is not in the default image. Skipped when the --dev toolchain above
# already installed these. The box ALSO needs its container storage on a real
# block device: containers/storage cannot apply image layers on the virtiofs
# filesystem a microVM box boots from (virtiofs cannot carry the multiple
# uids/gids container storage needs), and layer extraction fails there with
# "setting up pivot dir: permission denied" no matter which graph driver is
# selected. `--nested-containers` implies a `--disk` mounted at the graph root,
# which is what makes it work. The subordinate IDs cover a base image whose user
# already existed without them; /dev/fuse and /dev/net/tun are handed to the user
# at boot by the entrypoint.
RUN if [ "$ISOPOD_NESTED" = "1" ] && [ "$ISOPOD_DEV_TOOLS" != "1" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends \
           podman uidmap slirp4netns fuse-overlayfs \
      && rm -rf /var/lib/apt/lists/*; \
    fi \
 && if [ "$ISOPOD_NESTED" = "1" ]; then \
      grep -q "^$ISOPOD_USER:" /etc/subuid \
        || usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$ISOPOD_USER"; \
    fi

# Lock down sshd: key-only auth, single user, no root login. Double-quote the
# AllowUsers line so the build arg expands in the container shell.
RUN printf '%s\n' \
      "Port $ISOPOD_SSHD_PORT" \
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
# Default kernel-hardening profile (guest sysctls). The entrypoint applies these
# only on microVM boxes (their own guest kernel); see share/hardening-sysctl.conf.
COPY hardening-sysctl.conf /etc/isopod/hardening-sysctl.conf
RUN printf '%s\n' "$ISOPOD_USER" > /etc/isopod-user \
 && chmod +x /usr/local/bin/isopod-entrypoint
EXPOSE ${ISOPOD_SSHD_PORT}
CMD ["/usr/local/bin/isopod-entrypoint"]
