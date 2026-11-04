#!/bin/bash
#
# qdevice-setup.sh: give a Proxmox VE cluster a tie-breaker vote from the
# "Proxmox QNetd" Home Assistant add-on.
# Source: https://github.com/samohtnt/ha-qnetd-addon
#
# You run this as root on ONE node of the cluster. The add-on's log prints the full
# command line, including the one-time pairing code and the add-on's SSH host key.
# Read it first: `less /tmp/qdevice-setup.sh`, or run it with --dry-run (changes nothing).
#
# WHAT IT DOES, IN ORDER
#   1. Checks, read-only: the cluster is quorate, every node is online, every node can
#      reach the add-on on TCP 5403, and root SSH between the nodes works the way pvecm
#      uses it. Finds any existing QDevice, missing packages and leftover certificates.
#   2. Prints the full list of changes and asks once before making any of them.
#      --dry-run stops here. --yes skips the question.
#   3. Pairs with the add-on: checks that the add-on's SSH host key matches the one in
#      its log, then sends this node's root PUBLIC key (/root/.ssh/id_rsa.pub) with the
#      pairing code. If the host key does not match, nothing is sent.
#   4. Prepares the cluster, only if step 1 found something to fix: installs
#      corosync-qdevice, removes a QDevice that does not work, deletes leftover
#      QDevice certificates.
#   5. Runs Proxmox's own `pvecm qdevice setup <HA_IP>`, which does the real work.
#   6. Waits until every node counts the QDevice vote.
#   7. Tells the add-on to close pairing.
#
# WHAT IT CHANGES
#   On every node, through pvecm and apt:
#     - installs the corosync-qdevice package, if missing (after you agree)
#     - /etc/corosync/qdevice/: certificates for talking to the add-on (pvecm)
#     - /etc/pve/corosync.conf: a quorum.device section (pvecm; the file is cluster-wide)
#     - the corosync-qdevice service: enabled and started (pvecm)
#   On this node only, and only while the script runs:
#     - /root/.ssh/config: a block between "# BEGIN qnetd-pairing" and "# END qnetd-pairing"
#       at the top. pvecm always connects to port 22; this block sends its connections to
#       the add-on's pairing port and pins the add-on's host key. The script removes the
#       block when it exits, on success or failure, and leaves the file byte-identical.
#     - /root/.ssh/qnetd-pairing.known_hosts: the pinned host key. Removed on exit.
#
# WHAT IT NEVER DOES
#   - It never sends a private key anywhere, and never writes the pairing code to disk
#     outside a private temporary directory that it deletes on exit.
#   - It never changes a node's firewall, network, storage, guests or other packages.
#   - It never replaces a QDevice that still works, unless you pass --replace-working.
#   - It never changes anything before the checks in step 1 pass and you agree in step 2.
#
# NETWORK CONNECTIONS
#   - From every node: a TCP connect to HA_IP:5403 (the QNetd port), as a reachability test.
#   - From this node: SSH to HA_IP on the pairing port (22022 by default), to the add-on only.
#   - Between nodes: root SSH, as pvecm does itself (/etc/pve/nodes/<name>/ssh_known_hosts).
#   - apt on a node, only if it needs corosync-qdevice.
#
# UNDO
#   On any node: `pvecm qdevice remove`. The cluster goes back to one vote per node.
#
# EXIT CODES
#   0  set up, already set up, or --dry-run finished
#   1  stopped with an error; the message says what changed, if anything
#   2  wrong command-line arguments

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: qdevice-setup.sh HA_IP --code CODE --host-key SHA256:... [options]

Gives this Proxmox VE cluster a tie-breaker vote from the Proxmox QNetd
Home Assistant add-on. Run as root on one node. Copy the full command from
the add-on's log; it fills in HA_IP, --port, --code and --host-key.

Options:
  --port N           the add-on's pairing port (default 22022)
  --dry-run          run every check and show the planned changes, then stop
                     without changing anything
  --yes              do not ask before making the planned changes
  --replace-working  allow replacing a QDevice at another address that still works
  --force-odd        allow a cluster with an odd number of nodes, which Proxmox
                     does not recommend (passes --force to pvecm qdevice setup)
  -h, --help         show this help

The comment block at the top of this file lists every file the script
changes, every connection it makes, and how to undo it.
EOF
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

step_number=0
step_total=7
step() {
  step_number=$((step_number + 1))
  printf '\n[%d/%d] %s\n' "$step_number" "$step_total" "$*"
}
ok() { printf '      ok: %s\n' "$*"; }
note() { printf '      %s\n' "$*"; }
warn() { printf '      warning: %s\n' "$*" >&2; }
die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

ha_ip="" port=22022 code="" host_key=""
dry_run=false assume_yes=false replace_working=false force_odd=false

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) port="${2:?--port needs a value}"; shift 2 ;;
      --code) code="${2:?--code needs a value}"; shift 2 ;;
      --host-key) host_key="${2:?--host-key needs a value}"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      --yes) assume_yes=true; shift ;;
      --replace-working) replace_working=true; shift ;;
      --force-odd) force_odd=true; shift ;;
      -h | --help) usage; exit 0 ;;
      -*) usage >&2; printf '\nERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
      *)
        if [ -n "$ha_ip" ]; then
          printf 'ERROR: unexpected argument %s\n' "$1" >&2
          exit 2
        fi
        ha_ip="$1"
        shift
        ;;
    esac
  done
  if [ -z "$ha_ip" ] || [ -z "$code" ] || [ -z "$host_key" ]; then
    usage >&2
    exit 2
  fi

  # Every value below ends up in a command line or in /root/.ssh/config, so each one
  # must match a strict pattern. pvecm qdevice setup also accepts only an IP address.
  local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  [[ "$ha_ip" =~ ^$octet(\.$octet){3}$ || ("$ha_ip" =~ ^[0-9A-Fa-f:]+$ && "$ha_ip" == *:*:*) ]] ||
    die "HA_IP must be an IPv4 or IPv6 address, because pvecm qdevice setup accepts only an IP: $ha_ip"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "--port must be a number: $port"
  [[ "$code" =~ ^[A-Z0-9-]+$ ]] || die "--code looks wrong. Copy the command again from the add-on log."
  [[ "$host_key" =~ ^SHA256:[A-Za-z0-9+/]+$ ]] ||
    die "--host-key looks wrong. Copy the command again from the add-on log."
}

# ---------------------------------------------------------------------------
# The cluster, as pvecm sees it
# ---------------------------------------------------------------------------

self=""                    # this node's name
names=() ips=() online=()  # one entry per cluster member, same index in each array

# pmxcfs writes /etc/pve/.members with one line per node, for example
#   "pve1": { "id": 1, "online": 1, "ip": "192.168.1.10"},
# pvecm uses the same file for node names, addresses and online state.
read_members() {
  local line
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
}

# on_node INDEX COMMAND...: runs COMMAND on member INDEX, directly on this node or over
# root SSH with the options Proxmox uses between nodes (PVE::SSHInfo): HostKeyAlias set
# to the node name, and the node's known_hosts file under /etc/pve.
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

node_list() {
  local i out=()
  for i in "$@"; do out+=("${names[i]}"); done
  printf '%s' "${out[*]}"
}

# A node counts the QDevice vote when corosync-quorumtool shows the Qdevice flag and
# the node's own membership row is alive and voting ("A,V,...").
qdevice_vote() {
  local out
  out="$(on_node "$1" corosync-quorumtool -s 2>/dev/null)" || return 1
  grep -q '^Flags:.*Qdevice' <<<"$out" && grep -q 'A,V,' <<<"$out"
}
all_votes() {
  local i
  for i in "${!names[@]}"; do qdevice_vote "$i" || return 1; done
}

# ---------------------------------------------------------------------------
# Step 1: checks (read-only)
# ---------------------------------------------------------------------------

current=""             # host of the QDevice configured now, empty for none
current_works=false    # whether every node counts that QDevice's vote
pvecm_force=()         # (--force) for an odd node count with --force-odd
missing=() stale=()    # node indexes that lack corosync-qdevice / have old certificates

check_everything() {
  step "Checking the cluster (read-only)"

  [ "$(id -u)" -eq 0 ] || die "run as root"
  local cmd
  for cmd in pvecm corosync-quorumtool corosync-cmapctl ssh ssh-keyscan ssh-keygen timeout; do
    command -v "$cmd" >/dev/null || die "$cmd not found. Run this on a Proxmox VE node."
  done
  [ -f /root/.ssh/id_rsa ] && [ -f /root/.ssh/id_rsa.pub ] ||
    die "/root/.ssh/id_rsa is missing. pvecm qdevice setup needs it. Proxmox creates it with the cluster."
  [ -f /etc/pve/.members ] || die "/etc/pve/.members not found. Is this node part of a Proxmox VE cluster?"
  read_members

  local quorum i offline=()
  quorum="$(corosync-quorumtool -s 2>&1 || true)"
  grep -qE '^Quorate: +Yes' <<<"$quorum" || die "the cluster is not quorate"
  for i in "${!names[@]}"; do [ "${online[i]}" = 1 ] || offline+=("$i"); done
  [ "${#offline[@]}" -eq 0 ] || die "offline: $(node_list "${offline[@]}"). pvecm qdevice setup needs every node online."
  ok "quorate, ${#names[@]} nodes online: ${names[*]} (this node: $self)"

  if [ $((${#names[@]} % 2)) -eq 1 ]; then
    $force_odd || die "the cluster has ${#names[@]} nodes. Proxmox supports a QDevice only for an even number of nodes. Use --force-odd to set it up anyway."
    pvecm_force=(--force)
    warn "odd node count: pvecm will use the lms algorithm (--force-odd)"
  fi

  # SSH first: the vote check below reads every node over SSH, and a node it cannot
  # read would make a working QDevice look broken.
  local no_ssh=()
  for i in "${!names[@]}"; do on_node "$i" true 2>/dev/null || no_ssh+=("$i"); done
  [ "${#no_ssh[@]}" -eq 0 ] ||
    die "cannot reach $(node_list "${no_ssh[@]}") over SSH the way pvecm does. Check that 'pvecm updatecerts' has run and that root SSH between the nodes works."
  ok "root SSH between the nodes works"

  current="$({ corosync-cmapctl -g quorum.device.net.host 2>/dev/null || true; } | sed -n 's/^[^=]*= //p')"
  if [ -n "$current" ] && all_votes; then current_works=true; fi
  if [ "$current" = "$ha_ip" ] && $current_works; then
    printf '\nAlready done: every node counts the QDevice vote from %s.\n' "$ha_ip"
    printf 'Nothing changed. Pairing on the add-on closes by itself when its window ends.\n'
    exit 0
  fi
  if [ -z "$current" ]; then
    ok "no QDevice configured yet"
  elif $current_works; then
    $replace_working ||
      die "the cluster already has a working QDevice at $current. To replace it with $ha_ip, run again with --replace-working."
    note "a working QDevice is configured at $current (will be replaced: --replace-working)"
  else
    note "a QDevice is configured at $current, but not every node counts its vote"
  fi

  local unreachable=()
  for i in "${!names[@]}"; do
    on_node "$i" sh -c 'command -v corosync-qdevice' >/dev/null 2>&1 || missing+=("$i")
    on_node "$i" timeout 5 bash -c "</dev/tcp/$ha_ip/5403" 2>/dev/null || unreachable+=("$i")
    if on_node "$i" test -d /etc/corosync/qdevice/net/nssdb 2>/dev/null; then stale+=("$i"); fi
  done
  [ "${#unreachable[@]}" -eq 0 ] ||
    die "$(node_list "${unreachable[@]}") cannot reach $ha_ip:5403. Check firewalls, and that the add-on is running."
  ok "every node reaches the add-on at $ha_ip:5403"

  if [ "${#missing[@]}" -eq 0 ]; then
    ok "corosync-qdevice is installed on every node"
  else
    for i in "${missing[@]}"; do
      on_node "$i" sh -c 'apt-cache show corosync-qdevice >/dev/null 2>&1' ||
        die "corosync-qdevice is not available from the package sources on ${names[i]}. Run apt update there and check its repositories."
    done
    note "corosync-qdevice is missing on: $(node_list "${missing[@]}")"
  fi
  # Without a configured QDevice, `pvecm qdevice remove` will not clean these up, and
  # pvecm qdevice setup refuses to run while they exist.
  if [ -n "$current" ]; then
    stale=()
  elif [ "${#stale[@]}" -gt 0 ]; then
    note "leftover QDevice certificates on: $(node_list "${stale[@]}")"
  fi
}

# ---------------------------------------------------------------------------
# Step 2: the plan, and one question
# ---------------------------------------------------------------------------

show_plan_and_confirm() {
  step "Planned changes"
  local n=0 key_fp
  key_fp="$(ssh-keygen -lf /root/.ssh/id_rsa.pub | awk '{print $2}')"
  plan() {
    n=$((n + 1))
    printf '      %d. %s\n' "$n" "$*"
  }
  plan "Pair with the add-on at $ha_ip:$port, if its host key is $host_key, by sending"
  note "   this node's root public key ($key_fp) and the pairing code."
  [ "${#missing[@]}" -eq 0 ] || plan "Install corosync-qdevice with apt on: $(node_list "${missing[@]}")."
  [ -z "$current" ] || plan "Run 'pvecm qdevice remove' to remove the QDevice at $current."
  [ "${#stale[@]}" -eq 0 ] || plan "Delete /etc/corosync/qdevice/net/nssdb on: $(node_list "${stale[@]}")."
  plan "Run 'pvecm qdevice setup $ha_ip ${pvecm_force[*]}'. It adds a quorum.device section to"
  note "   /etc/pve/corosync.conf and enables corosync-qdevice on every node."
  plan "Close pairing on the add-on."
  note ""
  note "While this runs, a temporary block at the top of /root/.ssh/config points"
  note "pvecm's SSH connections to the add-on's port. It is removed when the script exits."

  if $dry_run; then
    printf '\nDry run: nothing was changed.\n'
    exit 0
  fi
  if $assume_yes; then
    note ""
    note "--yes given: going ahead."
    return
  fi
  # Opening /dev/tty is the real test. "[ -r /dev/tty ]" is true for root even
  # with no controlling terminal (cron, ssh without -t), and the open then fails.
  { : </dev/tty; } 2>/dev/null ||
    die "cannot ask for confirmation without a terminal. Run again with --yes to allow these changes. Nothing was changed."
  local answer=""
  read -r -p $'\n      Make these changes? [y/N] ' answer </dev/tty || true
  [[ "$answer" =~ ^[Yy] ]] || die "stopped. Nothing was changed."
}

# ---------------------------------------------------------------------------
# Step 3: pair with the add-on
# ---------------------------------------------------------------------------

work=""                                          # private temporary directory
known=/root/.ssh/qnetd-pairing.known_hosts       # the pinned add-on host key
config=""                                        # /root/.ssh/config, symlinks resolved
config_existed=false
config_changed=false
block_begin="# BEGIN qnetd-pairing (temporary, qdevice-setup.sh removes it)"
block_end="# END qnetd-pairing"

# Writes stdin to the config through a temporary file and a rename in the same
# directory, so the config is never half written.
replace_config() {
  local tmp
  tmp="$(mktemp "$(dirname "$config")/.config.qnetd-pairing.XXXXXX")"
  cat >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$config"
}
config_without_block() {
  awk -v b="$block_begin" -v e="$block_end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$config"
}

# Runs on every exit, success or failure: removes the temporary ssh config block, the
# pinned host key and the temporary directory that holds the pairing code.
cleanup() {
  if $config_changed; then
    config_without_block | replace_config
    if ! $config_existed && [ ! -s "$config" ]; then rm -f "$config"; fi
  fi
  rm -f "$known"
  [ -z "$work" ] || rm -rf "$work"
}

pair_with_addon() {
  step "Pairing with the add-on at $ha_ip:$port"
  work="$(mktemp -d)"
  install -d -m 0700 /root/.ssh
  config="$(readlink -f /root/.ssh/config)"
  [ -f "$config" ] && config_existed=true
  trap cleanup EXIT

  # Pin the host key before sending anything: compare what answers at HA_IP with the
  # fingerprint the add-on printed in its log.
  local scan seen
  scan="$(ssh-keyscan -T 10 -p "$port" -t ed25519 "$ha_ip" 2>/dev/null)" ||
    die "nothing answers on $ha_ip:$port. Start the add-on, or turn on open_pairing and restart it. If you just ran this several times, wait a minute: the add-on slows down repeated failed logins. Nothing was changed."
  seen="$(ssh-keygen -lf - <<<"$scan" | awk '{print $2}')"
  [ "$seen" = "$host_key" ] ||
    die "the SSH host key at $ha_ip:$port is $seen, but the add-on log says $host_key. Check HA_IP. Nothing was sent and nothing was changed."
  ok "the add-on's host key matches the log: $host_key"
  printf '%s\n' "$scan" >"$known"
  chmod 0600 "$known"

  # pvecm qdevice setup connects with plain `ssh`, `scp` and `ssh-copy-id` as root on
  # port 22, using /root/.ssh/id_rsa. This block, placed first in root's ssh config,
  # sends those connections to the pairing port and accepts only the pinned host key.
  # It ends with "Host *", so that options further down the file still apply to every
  # other host, as they did before.
  {
    printf '%s\n' "$block_begin" "Host $ha_ip" "  Port $port" "  User root" \
      "  UserKnownHostsFile $known" "  GlobalKnownHostsFile none" "  StrictHostKeyChecking yes" \
      "  IdentityFile /root/.ssh/id_rsa" "  IdentitiesOnly yes" \
      "  ControlMaster no" "  ControlPath none" "  ProxyJump none" "  ProxyCommand none" \
      "Host *" "$block_end"
    if $config_existed; then config_without_block; fi
  } >"$work/config"
  config_changed=true
  replace_config <"$work/config"
  ok "added the temporary block to /root/.ssh/config"

  # Enrol the public key: log in as the add-on's `pair` user with the code as its
  # password. The add-on accepts one public key on stdin from that user and nothing else.
  # SSH_ASKPASS hands ssh the code from a 0600 file, so it never appears in a prompt.
  printf '#!/bin/sh\ncat %s\n' "$work/code" >"$work/askpass"
  printf '%s\n' "$code" >"$work/code"
  chmod 0700 "$work/askpass"
  chmod 0600 "$work/code"
  SSH_ASKPASS="$work/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none \
    ssh -T -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
    -l pair "$ha_ip" </root/.ssh/id_rsa.pub >/dev/null ||
    die "the add-on refused the pairing code. Copy the command again from the add-on log; each start of the add-on makes a new code. Nothing was changed on the cluster."
  ssh -o BatchMode=yes "$ha_ip" true || die "the add-on accepted the code but not the key. Nothing was changed on the cluster."
  ok "the add-on accepted this node's root public key"
}

# ---------------------------------------------------------------------------
# Step 4: prepare the cluster
# ---------------------------------------------------------------------------

prepare_cluster() {
  step "Preparing the cluster"
  local i changed=false
  for i in "${missing[@]}"; do
    on_node "$i" sh -c 'apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq corosync-qdevice >/dev/null' ||
      die "installing corosync-qdevice on ${names[i]} failed. Install it there by hand, then run the same command again."
    ok "installed corosync-qdevice on ${names[i]}"
    changed=true
  done
  if [ -n "$current" ]; then
    pvecm qdevice remove
    ok "removed the QDevice at $current"
    changed=true
  fi
  # Checked again after the removal above, which deletes these on every node itself.
  for i in "${!names[@]}"; do
    if on_node "$i" test -d /etc/corosync/qdevice/net/nssdb 2>/dev/null; then
      on_node "$i" rm -rf /etc/corosync/qdevice/net/nssdb
      ok "deleted leftover QDevice certificates on ${names[i]}"
      changed=true
    fi
  done
  $changed || ok "nothing to prepare"
}

# ---------------------------------------------------------------------------
# Steps 5 to 7: pvecm, the vote, and closing pairing
# ---------------------------------------------------------------------------

run_pvecm_setup() {
  step "Running 'pvecm qdevice setup $ha_ip ${pvecm_force[*]}'"
  pvecm qdevice setup "$ha_ip" "${pvecm_force[@]}" ||
    die "pvecm qdevice setup failed. Fix the error above and run the same command again while pairing is open."
}

wait_for_votes() {
  step "Checking that every node counts the vote"
  local _ i
  for _ in $(seq 60); do
    all_votes && break
    sleep 1
  done
  all_votes || die "pvecm qdevice setup finished, but not every node counts the QDevice vote after 60 seconds. See 'pvecm status'."
  for i in "${!names[@]}"; do ok "${names[i]} counts the QDevice vote"; done
}

close_pairing() {
  step "Closing pairing on the add-on"
  if ssh -o BatchMode=yes "$ha_ip" "qnetd-pairing close 'set up from $self'" >/dev/null; then
    ok "pairing is closed; the add-on forgot this node's key"
  else
    warn "could not close pairing. It closes by itself when its window ends."
  fi
}

main() {
  parse_args "$@"
  check_everything        # 1
  show_plan_and_confirm   # 2 (--dry-run stops here)
  pair_with_addon         # 3
  prepare_cluster         # 4
  run_pvecm_setup         # 5
  wait_for_votes          # 6
  close_pairing           # 7
  printf '\nDone. The cluster has a tie-breaker vote from %s:5403.\n' "$ha_ip"
  printf "'pvecm status' shows it as the Qdevice member. To undo: pvecm qdevice remove\n"
}

main "$@"
