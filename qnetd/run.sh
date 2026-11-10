#!/bin/bash
set -euo pipefail

options=/data/options.json
db=/etc/corosync/qnetd/nssdb

# corosync-qnetd-certutil gives new files the owner of this directory, so set it first.
install -d -o root -g coroqnetd -m 0750 /data/qnetd
if [ ! -f "$db/cert9.db" ]; then
  echo "No qnetd certificate database found, creating a new CA"
  corosync-qnetd-certutil -i -G
fi
if ! certutil -L -d "$db" -n "QNetd Cert" >/dev/null; then
  echo "The certificate database in /data/qnetd has no server certificate." >&2
  echo "Delete /data/qnetd and set up the QDevice again." >&2
  exit 1
fi
chown -R root:coroqnetd /data/qnetd
chmod -R g+rX,g-w,o-rwx /data/qnetd
install -d -o coroqnetd -g coroqnetd -m 0770 /run/corosync-qnetd

# corosync-qnetd-certutil -s leaves one cluster-<name>.crt per cluster it has signed for.
clusters="$(find "$db" -maxdepth 1 -name 'cluster-*.crt' | wc -l)"
# A pairing failure must not stop qnetd, which may already serve a cluster.
if [ "$clusters" -eq 0 ]; then
  /usr/local/bin/qnetd-pairing open 60 || echo "ERROR: pairing failed to open. See the lines above." >&2
elif [ "$(jq -r '.open_pairing // false' "$options")" = true ]; then
  echo "open_pairing is on. Turn it off once the new cluster is set up."
  /usr/local/bin/qnetd-pairing open 60 || echo "ERROR: pairing failed to open. See the lines above." >&2
else
  echo "Serving $clusters cluster(s). Pairing is closed. Turn on open_pairing to add another cluster."
fi

exec setpriv --reuid=coroqnetd --regid=coroqnetd --init-groups corosync-qnetd -f
