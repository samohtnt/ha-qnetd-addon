#!/usr/bin/env bash
# End-to-end proof of the qnetd add-on and qdevice-setup.sh, using Docker.
# Set ADDON_PLATFORM (for example linux/arm64) to build and run only the add-on for another platform.
# Two node containers form a corosync cluster that plays the Proxmox cluster. tests/fake-pvecm
# stands in for pvecm and runs the same commands as pvecm qdevice setup and remove.
set -euo pipefail
# Git Bash rewrites arguments that look like POSIX paths (/data, /etc/...) into Windows paths.
export MSYS_NO_PATHCONV=1

# Relative paths, because docker.exe on Windows cannot read a Git Bash /c/... path.
cd "$(dirname "$0")/.."
run_id="qnetd-e2e-$$"
image=qnetd-e2e-addon
node_image=qnetd-e2e-node
net="$run_id"
vol="$run_id"
addon="$run_id-addon"
node1="$run_id-node1"
node2="$run_id-node2"
# The nodes stay native, like real amd64 Proxmox hosts talking to an aarch64 Home Assistant device.
native="linux/$(docker version -f '{{.Server.Arch}}')"
platform=(--platform "${ADDON_PLATFORM:-$native}")
node_platform=(--platform "$native")
# Fixed addresses, so the add-on keeps its IP across restarts like a Home Assistant device with a fixed LAN address.
subnet=10.254.254.0/24
addon_ip=10.254.254.10
node1_ip=10.254.254.20
node2_ip=10.254.254.21
dead_qnetd=10.254.254.99
pairing_port=22022
qnetd_db=/etc/corosync/qnetd/nssdb

cleanup() {
  docker rm -f "$addon" "$node1" "$node2" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  docker volume rm "$vol" >/dev/null 2>&1 || true
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*" >&2
  docker logs "$addon" 2>&1 | tail -n 40 | sed 's/^/  addon log: /' >&2 || true
  for n in "$node1" "$node2"; do
    docker exec "$n" sh -c 'tail -n 20 /tmp/*.log' 2>/dev/null | sed "s/^/  ${n##*-} log: /" >&2 || true
  done
  exit 1
}
in_addon() { docker exec "$addon" "$@"; }
in_node1() { docker exec "$node1" "$@"; }
in_node2() { docker exec "$node2" "$@"; }

wait_for() {
  local what="$1"
  shift
  for _ in $(seq "${E2E_WAIT:-30}"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail "timed out waiting for $what"
}

write_options() {
  docker run --rm -i -v "$vol:/data" --entrypoint sh "${platform[@]}" "$image" -c 'cat >/data/options.json'
}

start_addon() {
  # --init, because Home Assistant starts add-ons with an init process as PID 1 unless config.yaml sets init: false.
  docker run -d --init --name "$addon" --network "$net" --ip "$addon_ip" \
    -p 5403 -p "$pairing_port" -v "$vol:/data" "${platform[@]}" "$image" >/dev/null
  wait_for "qnetd to answer corosync-qnetd-tool -s" in_addon corosync-qnetd-tool -s
  wait_for "the health check to report healthy" addon_healthy
}
addon_healthy() { [ "$(docker inspect -f '{{.State.Health.Status}}' "$addon")" = healthy ]; }

stop_addon() {
  docker stop "$addon" >/dev/null
  docker rm "$addon" >/dev/null
}

# Prints "host port" for a published container port, as the engine host sees it.
published() {
  local mapping host
  mapping="$(docker port "$addon" "$1" | head -n 1)"
  host="${mapping%:*}"
  case "$host" in 0.0.0.0 | "[::]") host=127.0.0.1 ;; esac
  echo "$host ${mapping##*:}"
}

# Runs a command on the engine host's network, to reach published ports the way the LAN does.
# Engines with a host firewall drop bridge-to-host traffic, so a container cannot use
# host.docker.internal for this.
from_host() { docker run --rm --network host "${node_platform[@]}" "$node_image" "$@"; }

ca_fingerprint() {
  in_addon certutil -L -d "$qnetd_db" -n "QNet CA" | grep -A1 'Fingerprint (SHA-256)' | tail -n 1 | tr -d ' '
}

sshd_running() { in_addon sh -c 'grep -qx sshd /proc/[0-9]*/comm'; }
sshd_stopped() { ! sshd_running; }
port_refused() { ! in_node1 timeout 5 bash -c "</dev/tcp/$addon_ip/$1" 2>/dev/null; }

# The pairing command the add-on printed most recently.
banner() { docker logs "$addon" 2>&1 | grep -- '--code ' | tail -n 1; }
banner_code() { banner | sed -n 's/.* --code \([^ ]*\) .*/\1/p'; }
banner_key() { banner | sed -n 's/.* --host-key \([^ ]*\)$/\1/p'; }

# Logs in as the pair user with a password, the way qdevice-setup.sh does. The refusal tests run
# from node2, so that the per-source penalties sshd gives failed logins never slow down node1.
pair_login() {
  local password="$1"
  shift
  printf '#!/bin/sh\necho %s\n' "$password" | docker exec -i "$node2" sh -c 'cat >/tmp/askpass && chmod 700 /tmp/askpass'
  docker exec -e SSH_ASKPASS=/tmp/askpass -e SSH_ASKPASS_REQUIRE=force -e DISPLAY=none "$node2" \
    ssh -p "$pairing_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 "pair@$addon_ip" "$@"
}
root_login() {
  in_node2 ssh -p "$pairing_port" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@$addon_ip" "$@"
}

votes_on() { docker exec "$1" corosync-quorumtool -s 2>/dev/null; }
qdevice_vote() { votes_on "$1" | grep -q '^Flags:.*Qdevice' && votes_on "$1" | grep -q 'A,V,'; }
both_vote() { qdevice_vote "$node1" && qdevice_vote "$node2"; }
quorate() { votes_on "$node1" | grep -qE '^Quorate: +Yes'; }
cluster_listed() { in_addon corosync-qnetd-tool -l | grep -q 'Cluster "e2e"'; }

step "0. Lint"
docker run --rm -i hadolint/hadolint <qnetd/Dockerfile || fail "hadolint qnetd/Dockerfile"
pass "hadolint qnetd/Dockerfile"
for f in qnetd/run.sh qnetd/qnetd-pairing qdevice-setup.sh tests/fake-pvecm tests/e2e.sh; do
  docker run --rm -i koalaman/shellcheck:stable -s bash - <"$f" || fail "shellcheck $f"
  pass "shellcheck $f"
done

step "1. Image builds"
docker build -q "${platform[@]}" -t "$image" qnetd >/dev/null || fail "add-on image build"
pass "add-on image $image built from qnetd/Dockerfile"
docker build -q "${node_platform[@]}" -t "$node_image" - >/dev/null <<'EOF' || fail "node image build"
FROM debian:trixie-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      corosync corosync-qdevice openssh-client openssh-server procps \
 && rm -rf /var/lib/apt/lists/*
EOF
pass "node image $node_image built (plays a Proxmox node)"

step "2. A two-node cluster with a dead QDevice, like one whose old qnetd host is gone"
docker network create --subnet "$subnet" "$net" >/dev/null
docker volume create "$vol" >/dev/null
for n in "$node1:$node1_ip:node1" "$node2:$node2_ip:node2"; do
  IFS=: read -r name ip host <<<"$n"
  # knet forces its socket buffer size with SO_RCVBUFFORCE, which needs CAP_NET_ADMIN, as on a real node.
  docker run -d --name "$name" --hostname "$host" --network "$net" --ip "$ip" --cap-add NET_ADMIN \
    "${node_platform[@]}" "$node_image" sleep infinity >/dev/null
  docker cp tests/fake-pvecm "$name:/usr/local/bin/pvecm"
  # The root ssh config Proxmox writes: one global Ciphers line, no Host block.
  docker exec "$name" sh -c 'chmod 755 /usr/local/bin/pvecm && mkdir -p -m 700 /root/.ssh /etc/pve /run/sshd \
    && ssh-keygen -q -t rsa -b 3072 -N "" -f /root/.ssh/id_rsa \
    && echo "Ciphers aes128-ctr,aes192-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com" >/root/.ssh/config \
    && /usr/sbin/sshd'
done
in_node1 cat /root/.ssh/id_rsa.pub | docker exec -i "$node2" sh -c 'cat >>/root/.ssh/authorized_keys'
in_node2 cat /root/.ssh/id_rsa.pub | docker exec -i "$node1" sh -c 'cat >>/root/.ssh/authorized_keys'
# What pmxcfs provides on a current Proxmox cluster: /etc/pve/.members, and each node's host key
# in /etc/pve/nodes/<name>/ssh_known_hosts. Nothing goes into the global known_hosts.
for n in "$node1:node1" "$node2:node2"; do
  IFS=: read -r name host <<<"$n"
  key="$(docker exec "$name" cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f1-2)"
  for target in "$node1" "$node2"; do
    docker exec "$target" sh -c "mkdir -p /etc/pve/nodes/$host && echo '$host $key' >/etc/pve/nodes/$host/ssh_known_hosts"
  done
done
for n in "$node1:node1" "$node2:node2"; do
  IFS=: read -r name host <<<"$n"
  docker exec -i "$name" sh -c 'cat >/etc/pve/.members' <<EOF
{
"nodename": "$host",
"version": 4,
"cluster": { "name": "e2e", "version": 2, "nodes": 2, "quorate": 1 },
"nodelist": {
  "node1": { "id": 1, "online": 1, "ip": "$node1_ip"},
  "node2": { "id": 2, "online": 1, "ip": "$node2_ip"}
  }
}
EOF
done
for n in "$node1" "$node2"; do docker cp qdevice-setup.sh "$n:/usr/local/bin/qdevice-setup.sh"; done
in_node1 pvecm fake-write-conf "$dead_qnetd"
for n in "$node1" "$node2"; do docker exec -d "$n" sh -c 'corosync -f >/tmp/corosync.log 2>&1'; done
wait_for "the cluster to be quorate" quorate
in_node1 mkdir -p /etc/corosync/qdevice/net/nssdb
pass "nodes quorate with a QDevice configured at $dead_qnetd and a stale certificate store on node1"

step "3. Fresh install opens pairing"
printf '{"open_pairing": false}' | write_options
start_addon
# shellcheck disable=SC2016 # $p expands in the add-on's shell
qnetd_user="$(in_addon sh -c 'for p in /proc/[0-9]*; do [ "$(cat "$p/comm")" = corosync-qnetd ] && stat -c %U "$p"; done; true')"
[ "$qnetd_user" = coroqnetd ] || fail "corosync-qnetd runs as '$qnetd_user'"
pass "corosync-qnetd runs as coroqnetd"
read -r host port <<<"$(published 5403/tcp)"
from_host timeout 5 bash -c "</dev/tcp/$host/$port" || fail "TCP 5403 via $host:$port"
pass "TCP 5403 accepts connections through the published port $host:$port"
wait_for "sshd" sshd_running
code="$(banner_code)"
key="$(banner_key)"
[[ "$code" =~ ^[A-Z2-9]{5}(-[A-Z2-9]{5}){3}$ ]] || fail "no pairing code in the log: $(banner)"
pass "log prints the pairing command: $(banner | sed 's/^ *//')"
seen="$(in_node1 sh -c "ssh-keyscan -p $pairing_port -t ed25519 $addon_ip 2>/dev/null | ssh-keygen -lf - | cut -d' ' -f2")"
[ "$seen" = "$key" ] || fail "log host key $key, server presents $seen"
pass "the logged host key is the one the server presents"
port_refused 22 || fail "port 22 is open"
pass "nothing listens on port 22"

step "4. Pairing refuses what it should"
if root_login true 2>/dev/null; then fail "root logged in before any key was enrolled"; fi
pass "root cannot log in before enrolment"
out="$(pair_login WRONG-CODE true 2>&1 </dev/null || true)"
[[ "$out" == *"Permission denied"* ]] || fail "wrong code: $out"
pass "a wrong pairing code is refused: $(tail -n 1 <<<"$out")"
out="$(pair_login "$code" id 2>&1 </dev/null || true)"
[[ "$out" != *uid=* && "$out" == *"send one OpenSSH public key"* ]] || fail "pair ran a command: $out"
pass "the pair user can only enrol a key: $(tail -n 1 <<<"$out")"
out="$(in_node2 qdevice-setup.sh "$addon_ip" --code "$code" --host-key SHA256:wrongwrongwrong --yes 2>&1)" &&
  fail "setup accepted a wrong host key"
[[ "$out" == *"Nothing was sent"* ]] || fail "wrong host key: $out"
if root_login true 2>/dev/null; then fail "a key got enrolled despite the wrong host key"; fi
[ "$(in_node1 corosync-cmapctl -g quorum.device.net.host | sed 's/.*= //')" = "$dead_qnetd" ] ||
  fail "the wrong-host-key run changed the cluster"
pass "qdevice-setup.sh stops on a wrong host key before it sends the code or changes the cluster"
out="$(in_node2 qdevice-setup.sh "$addon_ip" --code "$code" --host-key "$key" --dry-run 2>&1)" || fail "dry run: $out"
[[ "$out" == *"Planned changes"* && "$out" == *"pvecm qdevice remove"* && "$out" == *"Dry run: nothing was changed."* ]] ||
  fail "dry run output: $out"
[ "$(in_node1 corosync-cmapctl -g quorum.device.net.host | sed 's/.*= //')" = "$dead_qnetd" ] || fail "the dry run changed the cluster"
if in_node2 grep -q qnetd-pairing /root/.ssh/config; then fail "the dry run touched the ssh config"; fi
pass "--dry-run lists the planned changes and changes nothing"
out="$(in_node2 qdevice-setup.sh "$addon_ip" --code "$code" --host-key "$key" 2>&1)" && fail "ran without a terminal or --yes"
[[ "$out" == *"Run again with --yes"* ]] || fail "no-terminal run: $out"
[ "$(in_node1 corosync-cmapctl -g quorum.device.net.host | sed 's/.*= //')" = "$dead_qnetd" ] || fail "the no-terminal run changed the cluster"
pass "without a terminal and without --yes it stops before changing anything"

step "5. qdevice-setup.sh from node1"
config_before="$(in_node1 sha256sum /root/.ssh/config)"
in_node1 qdevice-setup.sh "$addon_ip" --code "$code" --host-key "$key" --yes 2>&1 | sed 's/^/  | /' ||
  fail "qdevice-setup.sh failed"
both_vote || fail "not both nodes count the QDevice vote"
pass "both nodes count the QDevice vote: $(votes_on "$node1" | grep 'Flags:' | tr -s ' ')"
cluster_listed || fail "qnetd does not list cluster e2e"
pass "qnetd lists cluster \"e2e\""
[ "$(in_node1 corosync-cmapctl -g quorum.device.net.host | sed 's/.*= //')" = "$addon_ip" ] || fail "device host"
pass "the dead QDevice was replaced by $addon_ip"
wait_for "sshd to stop" sshd_stopped
zombies="$(in_addon sh -c 'grep -l "^State:.*Z" /proc/[0-9]*/status 2>/dev/null | wc -l')"
[ "$zombies" -eq 0 ] || fail "$zombies zombie processes in the add-on"
port_refused "$pairing_port" || fail "pairing port still open"
docker logs "$addon" 2>&1 | grep -q 'Pairing closed: set up from node1' || fail "no close message in the log"
pass "pairing closed and logged it"
[ "$(in_node1 sha256sum /root/.ssh/config)" = "$config_before" ] || fail "node1 ssh config changed: $(in_node1 cat /root/.ssh/config)"
if in_node1 test -e /root/.ssh/qnetd-pairing.known_hosts; then fail "known_hosts file left behind"; fi
pass "node1 ssh config is back to how it was"

step "6. Running it again changes nothing"
out="$(in_node1 qdevice-setup.sh "$addon_ip" --code "$code" --host-key "$key" --yes 2>&1)" || fail "rerun: $out"
[[ "$out" == *"Already done"* ]] || fail "rerun did not detect the finished setup: $out"
pass "a second run reports Already done and exits 0"
out="$(in_node1 qdevice-setup.sh "$dead_qnetd" --code "$code" --host-key "$key" --yes 2>&1)" &&
  fail "setup replaced a working QDevice: $out"
[[ "$out" == *"--replace-working"* ]] || fail "working QDevice: $out"
[ "$(in_node1 corosync-cmapctl -g quorum.device.net.host | sed 's/.*= //')" = "$addon_ip" ] || fail "device host changed"
pass "--yes alone does not replace a working QDevice at another address"

step "7. Restart keeps the CA and the vote, and pairing stays closed"
ca_before="$(ca_fingerprint)"
stop_addon
start_addon
[ "$ca_before" = "$(ca_fingerprint)" ] || fail "CA changed across the restart"
pass "CA SHA-256 unchanged: $ca_before"
if sshd_running; then fail "pairing reopened after a restart"; fi
docker logs "$addon" 2>&1 | grep -q 'Pairing is closed' || fail "no closed message"
pass "pairing stays closed once a cluster is set up"
wait_for "both nodes to count the vote again" both_vote
pass "both nodes count the vote again after the restart"

step "8. open_pairing reopens it with a new code"
printf '{"open_pairing": true}' | write_options
stop_addon
start_addon
wait_for "sshd" sshd_running
new_code="$(banner_code)"
[ -n "$new_code" ] && [ "$new_code" != "$code" ] || fail "no new code: $new_code"
pass "open_pairing opens pairing with a new code"
out="$(pair_login "$code" true 2>&1 </dev/null || true)"
[[ "$out" == *"Permission denied"* ]] || fail "old code: $out"
pass "the old code no longer works"

printf '\nAll checks passed.\n'
