#!/bin/bash
# Joins this Proxmox VE cluster to the Proxmox QNetd add-on for Home Assistant.
# The add-on log prints the full command line, with the pairing code and host key.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: qdevice-setup.sh HA_IP --code CODE --host-key SHA256:... [--port 22022]
                        [--yes] [--replace-working] [--force-odd]

Run as root on one node of a quorate Proxmox VE cluster. The script:
  1. checks that every node is online, has corosync-qdevice, and reaches HA_IP:5403
  2. asks before it installs corosync-qdevice, removes a broken QDevice, or deletes
     stale QDevice certificates, and makes none of these changes until step 3 works
  3. enrols this node's root key with the add-on, using the one-time pairing code
  4. runs pvecm qdevice setup HA_IP and checks the vote on every node
  5. closes pairing on the add-on

  --yes              do not ask before installing packages, removing a broken QDevice,
                     or deleting stale certificates
  --replace-working  allow replacing a QDevice at another address that still works
  --force-odd        allow a cluster with an odd number of nodes (pvecm qdevice setup --force)
EOF
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}
info() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ok: %s\n' "$*"; }
warn() { printf '    warning: %s\n' "$*" >&2; }

ha_ip="" port=22022 code="" host_key="" assume_yes=false replace_working=false force_odd=false
while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="${2:?--port needs a value}"; shift 2 ;;
    --code) code="${2:?--code needs a value}"; shift 2 ;;
    --host-key) host_key="${2:?--host-key needs a value}"; shift 2 ;;
    --yes) assume_yes=true; shift ;;
    --replace-working) replace_working=true; shift ;;
    --force-odd) force_odd=true; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option $1" ;;
    *) [ -z "$ha_ip" ] || die "unexpected argument $1"; ha_ip="$1"; shift ;;
  esac
done
[ -n "$ha_ip" ] && [ -n "$code" ] && [ -n "$host_key" ] || { usage >&2; exit 2; }

# pvecm qdevice setup accepts only an IP. The value also ends up in shell commands and in
# ssh_config, so accept nothing but address characters.
octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
[[ "$ha_ip" =~ ^$octet(\.$octet){3}$ || ("$ha_ip" =~ ^[0-9A-Fa-f:]+$ && "$ha_ip" == *:*:*) ]] ||
  die "HA_IP must be an IPv4 or IPv6 address, because pvecm qdevice setup accepts only an IP: $ha_ip"
[[ "$port" =~ ^[0-9]{1,5}$ ]] || die "--port must be a number: $port"
[[ "$code" =~ ^[A-Z0-9-]+$ ]] || die "--code looks wrong. Copy the command again from the add-on log."
[[ "$host_key" =~ ^SHA256:[A-Za-z0-9+/]+$ ]] || die "--host-key looks wrong. Copy the command again from the add-on log."

confirm() {
  $assume_yes && return 0
  local answer
  [ -r /dev/tty ] || die "$1 Run again with --yes to allow it."
  read -r -p "$1 [y/N] " answer </dev/tty
  [[ "$answer" =~ ^[Yy] ]] || die "stopped. Nothing was changed."
}

[ "$(id -u)" -eq 0 ] || die "run as root"
for cmd in pvecm corosync-quorumtool corosync-cmapctl ssh ssh-keyscan ssh-keygen timeout; do
  command -v "$cmd" >/dev/null || die "$cmd not found. Run this on a Proxmox VE node."
done
[ -f /root/.ssh/id_rsa ] && [ -f /root/.ssh/id_rsa.pub ] ||
  die "/root/.ssh/id_rsa is missing. pvecm qdevice setup needs it. Proxmox creates it with the cluster."
[ -f /etc/pve/.members ] || die "/etc/pve/.members not found. Is this node part of a Proxmox VE cluster?"

# The members as pvecm sees them: pmxcfs writes one line per node into /etc/pve/.members.
self="" names=() ips=() online=()
while IFS= read -r line; do
  if [[ "$line" =~ ^\"nodename\":\ \"([^\"]+)\" ]]; then
    self="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^\ *\"([^\"]+)\":\ \{\ \"id\":\ [0-9]+,\ \"online\":\ ([01])(,\ \"ip\":\ \"([^\"]+)\")? ]]; then
    names+=("${BASH_REMATCH[1]}")
    online+=("${BASH_REMATCH[2]}")
    ips+=("${BASH_REMATCH[4]}")
  fi
done </etc/pve/.members
[ -n "$self" ] && [ "${#names[@]}" -gt 0 ] || die "could not read the cluster members from /etc/pve/.members"

# Runs a command on node i the way pvecm does (PVE::SSHInfo): HostKeyAlias and the
# per-node known_hosts file under /etc/pve.
on_node() {
  local i="$1" name
  shift
  name="${names[i]}"
  if [ "$name" = "$self" ]; then
    "$@"
    return
  fi
  local opts=(-e none -o BatchMode=yes -o ConnectTimeout=10 -o "HostKeyAlias=$name")
  if [ -f "/etc/pve/nodes/$name/ssh_known_hosts" ]; then
    opts+=(-o "UserKnownHostsFile=/etc/pve/nodes/$name/ssh_known_hosts" -o GlobalKnownHostsFile=none)
  fi
  # ssh joins its arguments into one remote shell command, so quote each one.
  ssh "${opts[@]}" "root@${ips[i]}" -- "$(printf '%q ' "$@")"
}

qdevice_vote() {
  local out
  out="$(on_node "$1" corosync-quorumtool -s 2>/dev/null)" || return 1
  grep -q '^Flags:.*Qdevice' <<<"$out" && grep -q 'A,V,' <<<"$out"
}
all_votes() {
  local i
  for i in "${!names[@]}"; do qdevice_vote "$i" || return 1; done
}
node_list() {
  local i
  for i in "$@"; do printf '%s ' "${names[i]}"; done
}

info "Checking the cluster"
quorum="$(corosync-quorumtool -s 2>&1 || true)"
grep -qE '^Quorate: +Yes' <<<"$quorum" || die "the cluster is not quorate"
offline=()
for i in "${!names[@]}"; do [ "${online[i]}" = 1 ] || offline+=("$i"); done
[ "${#offline[@]}" -eq 0 ] || die "offline: $(node_list "${offline[@]}"). pvecm qdevice setup needs every node online."
ok "quorate, ${#names[@]} nodes online: ${names[*]}"
pvecm_force=()
if [ $(( ${#names[@]} % 2 )) -eq 1 ]; then
  $force_odd || die "the cluster has ${#names[@]} nodes. Proxmox supports a QDevice only for an even number of nodes. Use --force-odd to set it up anyway."
  pvecm_force=(--force)
fi

current="$({ corosync-cmapctl -g quorum.device.net.host 2>/dev/null || true; } | sed -n 's/^[^=]*= //p')"
current_works=false
[ -z "$current" ] || ! all_votes || current_works=true
if [ "$current" = "$ha_ip" ] && $current_works; then
  info "Already done"
  ok "every node counts the QDevice vote from $ha_ip"
  echo "    Nothing changed. Pairing on the add-on closes by itself when its window ends."
  exit 0
fi
if [ -n "$current" ] && $current_works && ! $replace_working; then
  die "the cluster already has a working QDevice at $current. To replace it with $ha_ip, run again with --replace-working."
fi

missing=() unreachable=() no_ssh=() stale=()
for i in "${!names[@]}"; do
  if ! on_node "$i" true 2>/dev/null; then
    no_ssh+=("$i")
    continue
  fi
  on_node "$i" sh -c 'command -v corosync-qdevice' >/dev/null 2>&1 || missing+=("$i")
  on_node "$i" timeout 5 bash -c "</dev/tcp/$ha_ip/5403" 2>/dev/null || unreachable+=("$i")
  if on_node "$i" test -d /etc/corosync/qdevice/net/nssdb 2>/dev/null; then stale+=("$i"); fi
done
[ "${#no_ssh[@]}" -eq 0 ] ||
  die "cannot reach $(node_list "${no_ssh[@]}")over SSH the way pvecm does. Check that 'pvecm updatecerts' has run and that root SSH between the nodes works."
[ "${#unreachable[@]}" -eq 0 ] ||
  die "$(node_list "${unreachable[@]}")cannot reach $ha_ip:5403. Check firewalls, and that the add-on is running."
ok "every node reaches $ha_ip:5403"

# Ask about every change now, but make none until pairing has worked, so that a wrong
# address or an old code leaves the cluster as it was.
if [ "${#missing[@]}" -gt 0 ]; then
  for i in "${missing[@]}"; do
    on_node "$i" sh -c 'apt-cache show corosync-qdevice >/dev/null 2>&1' ||
      die "corosync-qdevice is not available from the package sources on ${names[i]}. Run apt update there and check its repositories."
  done
  confirm "Install corosync-qdevice on: $(node_list "${missing[@]}")?"
else
  ok "corosync-qdevice is installed on every node"
fi
if [ -n "$current" ]; then
  if $current_works; then
    confirm "Replace the working QDevice at $current with $ha_ip?"
  else
    confirm "The cluster has a QDevice at $current that does not give every node a vote. Remove it?"
  fi
fi
[ "${#stale[@]}" -eq 0 ] ||
  confirm "Delete leftover QDevice certificates in /etc/corosync/qdevice/net/nssdb on: $(node_list "${stale[@]}")?"

info "Pairing with the add-on at $ha_ip:$port"
work="$(mktemp -d)"
known=/root/.ssh/qnetd-pairing.known_hosts
config="$(readlink -f /root/.ssh/config)"
config_existed=false
[ -f "$config" ] && config_existed=true
config_changed=false
begin="# BEGIN qnetd-pairing (temporary, qdevice-setup.sh removes it)"
end="# END qnetd-pairing"

# Writes the file in the same directory and renames it, so the config is never half written.
replace_config() {
  local tmp
  tmp="$(mktemp "$(dirname "$config")/.config.qnetd-pairing.XXXXXX")"
  cat >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$config"
}
strip_block() {
  awk -v b="$begin" -v e="$end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$config" | replace_config
}
cleanup() {
  if $config_changed; then
    strip_block
    if ! $config_existed && [ ! -s "$config" ]; then rm -f "$config"; fi
  fi
  rm -f "$known"
  rm -rf "$work"
}
trap cleanup EXIT

scan="$(ssh-keyscan -T 10 -p "$port" -t ed25519 "$ha_ip" 2>/dev/null)" ||
  die "nothing answers on $ha_ip:$port. Start the add-on, or turn on open_pairing and restart it. If you just ran this several times, wait a minute: the add-on slows down repeated failed logins."
seen="$(ssh-keygen -lf - <<<"$scan" | awk '{print $2}')"
[ "$seen" = "$host_key" ] ||
  die "the SSH host key at $ha_ip:$port is $seen, but the add-on log says $host_key. Check HA_IP. Nothing was sent."
ok "host key matches $host_key"
printf '%s\n' "$scan" >"$known"
chmod 0600 "$known"

# pvecm qdevice setup runs ssh, scp, and ssh-copy-id as root@HA_IP on port 22 with
# /root/.ssh/id_rsa. This block at the top of root's ssh config points them at the
# pairing port and pins the host key, for the duration of this script. It ends with
# "Host *" so that global options further down still apply to every other host.
install -d -m 0700 /root/.ssh
{
  printf '%s\n' "$begin" "Host $ha_ip" "  Port $port" "  User root" \
    "  UserKnownHostsFile $known" "  GlobalKnownHostsFile none" "  StrictHostKeyChecking yes" \
    "  IdentityFile /root/.ssh/id_rsa" "  IdentitiesOnly yes" \
    "  ControlMaster no" "  ControlPath none" "  ProxyJump none" "  ProxyCommand none" \
    "Host *" "$end"
  if $config_existed; then
    awk -v b="$begin" -v e="$end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$config"
  fi
} >"$work/config"
config_changed=true
replace_config <"$work/config"

printf '#!/bin/sh\ncat %s\n' "$work/code" >"$work/askpass"
printf '%s\n' "$code" >"$work/code"
chmod 0700 "$work/askpass"
chmod 0600 "$work/code"
SSH_ASKPASS="$work/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none \
  ssh -T -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
  -l pair "$ha_ip" </root/.ssh/id_rsa.pub >/dev/null ||
  die "the add-on refused the pairing code. Copy the command again from the add-on log. Each start of the add-on makes a new code."
ssh -o BatchMode=yes "$ha_ip" true || die "the add-on accepted the code but not the key"
ok "enrolled this node's root key"

info "Preparing the cluster"
for i in "${missing[@]}"; do
  on_node "$i" sh -c 'apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq corosync-qdevice >/dev/null' ||
    die "installing corosync-qdevice on ${names[i]} failed. Install it there by hand, then run the same command again."
  ok "installed corosync-qdevice on ${names[i]}"
done
if [ -n "$current" ]; then
  pvecm qdevice remove
  ok "removed the QDevice at $current"
fi
for i in "${!names[@]}"; do
  if on_node "$i" test -d /etc/corosync/qdevice/net/nssdb 2>/dev/null; then
    on_node "$i" rm -rf /etc/corosync/qdevice/net/nssdb
    ok "deleted leftover QDevice certificates on ${names[i]}"
  fi
done

info "Running pvecm qdevice setup $ha_ip ${pvecm_force[*]}"
pvecm qdevice setup "$ha_ip" "${pvecm_force[@]}" ||
  die "pvecm qdevice setup failed. Fix the error above and run the same command again while pairing is open."

info "Checking the vote on every node"
for _ in $(seq 60); do
  all_votes && break
  sleep 1
done
all_votes || die "pvecm qdevice setup finished, but not every node counts the QDevice vote. See pvecm status."
for i in "${!names[@]}"; do ok "${names[i]} counts the QDevice vote"; done

if ssh -o BatchMode=yes "$ha_ip" "qnetd-pairing close 'set up from $self'"; then
  ok "closed pairing on the add-on"
else
  warn "could not close pairing. It closes by itself when its window ends."
fi

info "Done"
echo "    The cluster has a tie-breaker vote from $ha_ip:5403."
echo "    pvecm status shows it as the Qdevice member."
