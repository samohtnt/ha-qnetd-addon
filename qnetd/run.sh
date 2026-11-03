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
  echo "Delete /data/qnetd and run pvecm qdevice setup again." >&2
  exit 1
fi
chown -R root:coroqnetd /data/qnetd
chmod -R g+rX,g-w,o-rwx /data/qnetd
install -d -o coroqnetd -g coroqnetd -m 0770 /run/corosync-qnetd

if [ "$(jq -r '.setup_ssh // false' "$options")" = true ]; then
  key="$(jq -r '.authorized_key // empty' "$options")"
  if [ -z "$key" ]; then
    echo "setup_ssh is on but authorized_key is empty" >&2
    exit 1
  fi
  install -d -m 0700 /root/.ssh /data/ssh
  install -d -m 0755 /run/sshd
  printf '%s\n' "$key" >/root/.ssh/authorized_keys
  chmod 0600 /root/.ssh/authorized_keys
  # A host key under /data keeps the fingerprint the PVE nodes saw stable across restarts.
  if [ ! -f /data/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -q -t ed25519 -N '' -f /data/ssh/ssh_host_ed25519_key
  fi
  sshd_opts=(
    -o HostKey=/data/ssh/ssh_host_ed25519_key
    -o PermitRootLogin=prohibit-password
    -o PasswordAuthentication=no
    -o KbdInteractiveAuthentication=no
  )
  /usr/sbin/sshd -t "${sshd_opts[@]}"
  /usr/sbin/sshd -D -e "${sshd_opts[@]}" &
  echo "Setup SSH is ON. Turn setup_ssh off once pvecm qdevice setup has finished."
else
  rm -f /root/.ssh/authorized_keys
fi

exec setpriv --reuid=coroqnetd --regid=coroqnetd --init-groups corosync-qnetd -f
