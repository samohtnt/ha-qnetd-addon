FROM debian:trixie-slim

ARG BUILD_VERSION
ENV BUILD_VERSION=${BUILD_VERSION}

# Versions stay unpinned on purpose: a rebuild should pick up Debian security updates.
# The package postinst creates a CA in the image. Drop it so every install makes its own CA
# under /data, which Home Assistant persists and backs up.
# hadolint ignore=DL3008
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      corosync-qnetd openssh-server jq curl \
 && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* \
 && rm -rf /etc/corosync/qnetd \
 && ln -s /data/qnetd /etc/corosync/qnetd \
 && useradd --system --no-create-home --home-dir / --shell /bin/sh pair

COPY run.sh /run.sh
COPY qnetd-pairing /usr/local/bin/qnetd-pairing
RUN chmod 0755 /usr/local/bin/qnetd-pairing
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --start-interval=2s CMD ["corosync-qnetd-tool", "-s"]
CMD ["/bin/bash", "/run.sh"]
