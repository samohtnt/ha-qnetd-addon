#!/bin/bash
# Joins this Proxmox VE cluster to the Proxmox QNetd add-on for Home Assistant.
# The add-on log prints the full command line, with the pairing code and host key.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: qdevice-setup.sh HA_IP --code CODE --host-key SHA256:... [--port 22022] [--yes] [--force-odd]

Run as root on one node of a quorate Proxmox VE cluster. The script:
  1. checks that every node is online, has corosync-qdevice, and reaches HA_IP:5403
  2. removes an existing QDevice and stale QDevice certificates, after asking
  3. enrols this node's root key with the add-on, using the one-time pairing code
  4. runs pvecm qdevice setup HA_IP and checks the vote on every node
  5. closes pairing on the add-on

  --yes        do not ask before removing or installing anything
  --force-odd  allow a cluster with an odd number of nodes (pvecm qdevice setup --force)
EOF
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}
info() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ok: %s\n' "$*"; }

ha_ip="" port=22022 code="" host_key="" assume_yes=false force_odd=false
while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="${2:?--port needs a value}"; shift 2 ;;
    --code) code="${2:?--code needs a value}"; shift 2 ;;
    --host-key) host_key="${2:?--host-key needs a value}"; shift 2 ;;
    --yes) assume_yes=true; shift ;;
    --force-odd) force_odd=true; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option $1" ;;
    *) [ -z "$ha_ip" ] || die "unexpected argument $1"; ha_ip="$1"; shift ;;
  esac
done
[ -n "$ha_ip" ] && [ -n "$code" ] && [ -n "$host_key" ] || { usage >&2; exit 2; }
[[ "$ha_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$ha_ip" == *:* ]] ||
  die "HA_IP must be an IP address, because pvecm qdevice setup accepts only an IP: $ha_ip"
[[ "$port" =~ ^[0-9]+$ ]] || die "--port must be a number: $port"

confirm() {
  $assume_yes && return 0
  local answer
  [ -r /dev/tty ] || die "$1 Run again with --yes to allow it."
  read -r -p "$1 [y/N] " answer </dev/tty
  [[ "$answer" =~ ^[Yy] ]] || die "stopped, nothing changed after this point"
}

[ "$(id -u)" -eq 0 ] || die "run as root"
for cmd in pvecm corosync-quorumtool corosync-cmapctl ssh ssh-keyscan ssh-keygen timeout; do
  command -v "$cmd" >/dev/null || die "$cmd not found. Run this on a Proxmox VE node."
done
[ -f /root/.ssh/id_rsa ] && [ -f /root/.ssh/id_rsa.pub ] ||
  die "/root/.ssh/id_rsa is missing. pvecm qdevice setup needs it. Proxmox creates it with the cluster."

cmap() { { corosync-cmapctl -g "$1" 2>/dev/null || true; } | sed -n 's/^[^=]*= //p'; }

# The cluster from corosync's own view, which is the same on every Proxmox version.
names=() addrs=() ids=()
while IFS= read -r line; do
  [[ "$line" =~ ^nodelist\.node\.([0-9]+)\.(name|ring0_addr|nodeid)\ \([a-z0-9]+\)\ =\ (.*)$ ]] || continue
  i="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in
    name) names[i]="${BASH_REMATCH[3]}" ;;
    ring0_addr) addrs[i]="${BASH_REMATCH[3]}" ;;
    nodeid) ids[i]="${BASH_REMATCH[3]}" ;;
  esac
done < <(corosync-cmapctl -b nodelist.node. 2>/dev/null)
[ "${#addrs[@]}" -gt 0 ] || die "corosync is not running or this node is not in a cluster"
this_id="$(cmap runtime.votequorum.this_node_id)"

on_node() {
  local i="$1"
  shift
  if [ "${ids[i]}" = "$this_id" ]; then
    "$@"
  else
    # ssh joins its arguments into one remote shell command, so quote each one.
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o HostKeyAlias="${names[i]}" "root@${addrs[i]}" -- "$(printf '%q ' "$@")"
  fi
}
each_node() {
  local i
  for i in "${!addrs[@]}"; do "$@" "$i"; done
}

qdevice_vote() {
  local out
  out="$(on_node "$1" corosync-quorumtool -s 2>/dev/null)" || return 1
  grep -q '^Flags:.*Qdevice' <<<"$out" && grep -q 'A,V,' <<<"$out"
}
all_votes() {
  local i
  for i in "${!addrs[@]}"; do qdevice_vote "$i" || return 1; done
}

info "Checking the cluster"
corosync-quorumtool -s | grep -qE '^Quorate: +Yes' || die "the cluster is not quorate"
joined="$(corosync-cmapctl -b runtime.members. 2>/dev/null | grep -c 'status (str) = joined' || true)"
[ "$joined" -eq "${#addrs[@]}" ] ||
  die "only $joined of ${#addrs[@]} nodes are online. pvecm qdevice setup needs every node online."
ok "quorate, ${#addrs[@]} nodes online: ${names[*]}"
pvecm_force=()
if [ $(( ${#addrs[@]} % 2 )) -eq 1 ]; then
  $force_odd || die "the cluster has ${#addrs[@]} nodes. Proxmox supports a QDevice only for an even number of nodes. Use --force-odd to set it up anyway."
  pvecm_force=(--force)
fi

current="$(cmap quorum.device.net.host)"
if [ "$current" = "$ha_ip" ] && all_votes; then
  info "Already done"
  ok "every node counts the QDevice vote from $ha_ip"
  echo "    Nothing changed. Pairing on the add-on closes by itself when its window ends."
  exit 0
fi

missing=() unreachable=() stale=()
check_node() {
  local i="$1"
  on_node "$i" sh -c 'command -v corosync-qdevice' >/dev/null 2>&1 || missing+=("$i")
  on_node "$i" timeout 5 bash -c "</dev/tcp/$ha_ip/5403" 2>/dev/null || unreachable+=("$i")
}
check_stale() {
  if on_node "$1" test -d /etc/corosync/qdevice/net/nssdb 2>/dev/null; then stale+=("$1"); fi
}
each_node check_node

if [ "${#unreachable[@]}" -gt 0 ]; then
  for i in "${unreachable[@]}"; do echo "    ${names[i]} cannot reach $ha_ip:5403" >&2; done
  die "every node must reach the add-on on TCP 5403. Check firewalls and that the add-on is running."
fi
ok "every node reaches $ha_ip:5403"

# Ask about every change now, but make none until pairing has worked, so that a wrong
# address or an old code leaves the cluster as it was.
each_node check_stale
if [ "${#missing[@]}" -gt 0 ]; then
  confirm "Install corosync-qdevice on: $(for i in "${missing[@]}"; do printf '%s ' "${names[i]}"; done)?"
else
  ok "corosync-qdevice is installed on every node"
fi
[ -z "$current" ] || confirm "The cluster has a QDevice at $current that is not working. Remove it?"
if [ "${#stale[@]}" -gt 0 ]; then
  confirm "Delete leftover QDevice certificates in /etc/corosync/qdevice/net/nssdb on: $(for i in "${stale[@]}"; do printf '%s ' "${names[i]}"; done)?"
fi

info "Pairing with the add-on at $ha_ip:$port"
work="$(mktemp -d)"
known=/root/.ssh/qnetd-pairing.known_hosts
config=/root/.ssh/config
begin="# BEGIN qnetd-pairing (temporary, qdevice-setup.sh removes it)"
end="# END qnetd-pairing"
strip_block() {
  [ -f "$config" ] || return 0
  awk -v b="$begin" -v e="$end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$config" >"$work/config"
  cat "$work/config" >"$config"
}
cleanup() {
  strip_block
  rm -f "$known"
  rm -rf "$work"
}
trap cleanup EXIT

scan="$(ssh-keyscan -T 10 -p "$port" -t ed25519 "$ha_ip" 2>/dev/null)" ||
  die "nothing answers on $ha_ip:$port. Start the add-on, or turn on open_pairing and restart it."
seen="$(ssh-keygen -lf - <<<"$scan" | awk '{print $2}')"
[ "$seen" = "$host_key" ] ||
  die "the SSH host key at $ha_ip:$port is $seen, but the add-on log says $host_key. Check HA_IP. Nothing was sent."
ok "host key matches $host_key"
printf '%s\n' "$scan" >"$known"
chmod 0600 "$known"

# pvecm qdevice setup runs ssh, scp, and ssh-copy-id as root@HA_IP on port 22 with
# /root/.ssh/id_rsa. This block at the top of root's ssh config points them at the
# pairing port and pins the host key, for the duration of this script.
install -d -m 0700 /root/.ssh
[ -f "$config" ] || install -m 0600 /dev/null "$config"
strip_block
{
  printf '%s\n' "$begin" "Host $ha_ip" "  Port $port" "  User root" \
    "  UserKnownHostsFile $known" "  StrictHostKeyChecking yes" \
    "  IdentityFile /root/.ssh/id_rsa" "  IdentitiesOnly yes" "$end"
  cat "$config"
} >"$work/config.new"
cat "$work/config.new" >"$config"

printf '#!/bin/sh\ncat %s\n' "$work/code" >"$work/askpass"
printf '%s\n' "$code" >"$work/code"
chmod 0700 "$work/askpass"
chmod 0600 "$work/code"
SSH_ASKPASS="$work/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none \
  ssh -T -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
  -l pair "$ha_ip" </root/.ssh/id_rsa.pub >/dev/null ||
  die "the add-on refused the pairing code. Copy the command again from the add-on log. A restart makes a new code."
ssh -o BatchMode=yes "$ha_ip" true || die "the add-on accepted the code but not the key"
ok "enrolled this node's root key"

info "Preparing the cluster"
for i in "${missing[@]}"; do
  on_node "$i" sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq corosync-qdevice' >/dev/null
  ok "installed corosync-qdevice on ${names[i]}"
done
if [ -n "$current" ]; then
  pvecm qdevice remove
  ok "removed the QDevice at $current"
fi
stale=()
each_node check_stale
for i in "${stale[@]}"; do
  on_node "$i" rm -rf /etc/corosync/qdevice/net/nssdb
  ok "deleted leftover QDevice certificates on ${names[i]}"
done

info "Running pvecm qdevice setup $ha_ip ${pvecm_force[*]}"
pvecm qdevice setup "$ha_ip" "${pvecm_force[@]}" ||
  die "pvecm qdevice setup failed. Fix the error above and run the same command again. Pairing stays open until its window ends."

info "Checking the vote on every node"
for _ in $(seq 60); do
  all_votes && break
  sleep 1
done
all_votes || die "pvecm qdevice setup finished, but not every node counts the QDevice vote. See pvecm status."
for i in "${!addrs[@]}"; do ok "${names[i]} counts the QDevice vote"; done

ssh -o BatchMode=yes "$ha_ip" "qnetd-pairing close 'set up from $(hostname)'" ||
  echo "    warning: could not close pairing. It closes by itself when its window ends." >&2
ok "closed pairing on the add-on"

info "Done"
echo "    The cluster has a tie-breaker vote from $ha_ip:5403."
echo "    pvecm status shows it as the Qdevice member."
