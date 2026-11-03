#!/usr/bin/env bash
# End-to-end proof of the qnetd add-on, using Docker. Set DOCKER_DEFAULT_PLATFORM to test another platform.
# A second container plays the Proxmox node and replays what pvecm qdevice setup does.
set -euo pipefail
# Git Bash rewrites arguments that look like POSIX paths (/data, /etc/...) into Windows paths.
export MSYS_NO_PATHCONV=1

# Relative paths, because docker.exe on Windows cannot read a Git Bash /c/... path.
cd "$(dirname "$0")/.."
run_id="qnetd-e2e-$$"
image=qnetd-e2e-addon
client_image=qnetd-e2e-client
net="$run_id"
vol="$run_id"
addon="$run_id-addon"
client="$run_id-client"
cluster=e2e
# Fixed addresses, so the add-on keeps its IP across restarts like a Home Assistant device with a fixed LAN address.
subnet=10.254.254.0/24
addon_ip=10.254.254.10
client_ip=10.254.254.20
qnetd_db=/etc/corosync/qnetd/nssdb
node_db=/etc/corosync/qdevice/net/nssdb

cleanup() {
  docker rm -f "$addon" "$client" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  docker volume rm "$vol" >/dev/null 2>&1 || true
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*" >&2
  docker logs "$addon" 2>/dev/null | tail -n 30 | sed 's/^/  addon log: /' >&2 || true
  exit 1
}
in_addon() { docker exec "$addon" "$@"; }
in_client() { docker exec "$client" "$@"; }

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
  docker run --rm -i -v "$vol:/data" --entrypoint sh "$image" -c 'cat >/data/options.json'
}

start_addon() {
  docker run -d --name "$addon" --network "$net" --ip "$addon_ip" \
    -p 5403 -p 22 -v "$vol:/data" "$image" >/dev/null
  wait_for "qnetd to answer corosync-qnetd-tool -s" in_addon corosync-qnetd-tool -s
}

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

# Runs a command on the engine host's network, holding the node's private key, to reach
# published ports the way the LAN does. Engines with a host firewall drop bridge-to-host traffic,
# so the client container cannot use host.docker.internal for this.
from_host() {
  in_client cat /root/.ssh/id_rsa | docker run --rm -i --network host "$client_image" bash -c \
    'install -d -m 700 /root/.ssh && cat >/root/.ssh/id_rsa && chmod 600 /root/.ssh/id_rsa && exec "$@"' _ "$@"
}

ca_fingerprint() {
  in_addon certutil -L -d "$qnetd_db" -n "QNet CA" | grep -A1 'Fingerprint (SHA-256)' | tail -n 1 | tr -d ' '
}

replay() {
  local ref="$1"
  shift
  printf '  [pvecm.pm:%s] %s\n' "$ref" "$*"
  in_client "$@" || fail "pvecm.pm:$ref exited non-zero"
}

sshd_running() { in_addon sh -c 'grep -qx sshd /proc/[0-9]*/comm'; }

step "7. Lint"
docker run --rm -i hadolint/hadolint <qnetd/Dockerfile || fail "hadolint qnetd/Dockerfile"
pass "hadolint qnetd/Dockerfile"
for f in qnetd/run.sh tests/e2e.sh; do
  docker run --rm -i koalaman/shellcheck:stable -s bash - <"$f" || fail "shellcheck $f"
  pass "shellcheck $f"
done

step "1. Image builds"
docker build -q -t "$image" qnetd >/dev/null || fail "add-on image build"
pass "add-on image $image built from qnetd/Dockerfile"
docker build -q -t "$client_image" - >/dev/null <<'EOF' || fail "client image build"
FROM debian:trixie-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      corosync corosync-qdevice openssh-client \
 && rm -rf /var/lib/apt/lists/*
EOF
pass "client image $client_image built (plays the Proxmox node)"

docker network create --subnet "$subnet" "$net" >/dev/null
docker volume create "$vol" >/dev/null
docker run -d --name "$client" --hostname node1 --network "$net" --ip "$client_ip" \
  "$client_image" sleep infinity >/dev/null
in_client sh -c 'mkdir -p -m 700 /root/.ssh /etc/pve \
  && ssh-keygen -q -t rsa -b 3072 -N "" -f /root/.ssh/id_rsa \
  && printf "StrictHostKeyChecking accept-new\n" >/root/.ssh/config'

step "2. Default mode"
printf '{"setup_ssh": false}' | write_options
start_addon
pid1="$(in_addon cat /proc/1/comm) as $(in_addon stat -c %U /proc/1)"
[ "$pid1" = "corosync-qnetd as coroqnetd" ] || fail "PID 1 is $pid1"
pass "PID 1 is $pid1"
read -r host port <<<"$(published 5403/tcp)"
from_host timeout 5 bash -c "</dev/tcp/$host/$port" || fail "TCP 5403 via $host:$port"
pass "TCP 5403 accepts connections through the published port $host:$port"
status="$(in_addon corosync-qnetd-tool -s)"
grep -q 'QNetd address:.*5403' <<<"$status" || fail "corosync-qnetd-tool -s: $status"
pass "corosync-qnetd-tool -s answers: $(grep 'QNetd address' <<<"$status" | tr -s '\t ' ' ')"
if sshd_running; then fail "sshd is running in default mode"; fi
pass "no sshd process in the add-on"
if out="$(in_client timeout 5 bash -c "</dev/tcp/$addon_ip/22" 2>&1)"; then fail "port 22 is open"; fi
grep -q 'Connection refused' <<<"$out" || fail "port 22 probe: $out"
pass "port 22 refuses connections: $(tail -n 1 <<<"$out")"

step "3. Restart keeps the CA"
ca_before="$(ca_fingerprint)"
stop_addon
start_addon
ca_after="$(ca_fingerprint)"
[ -n "$ca_before" ] && [ "$ca_before" = "$ca_after" ] || fail "CA changed: $ca_before -> $ca_after"
pass "CA SHA-256 unchanged after recreating the container: $ca_after"
if docker logs "$addon" 2>&1 | grep -q 'creating a new CA'; then fail "second start created a new CA"; fi
pass "second start reused the existing database"

step "4. Setup mode SSH"
printf '{"setup_ssh": true, "authorized_key": "%s"}' "$(in_client cat /root/.ssh/id_rsa.pub)" | write_options
stop_addon
start_addon
wait_for "sshd" sshd_running
read -r host port <<<"$(published 22/tcp)"
uid="$(from_host ssh -o BatchMode=yes -o StrictHostKeyChecking=no -p "$port" "root@$host" id -u)" || fail "key login"
[ "$uid" = 0 ] || fail "key login gave uid $uid"
pass "key login as root through the published port $host:$port gives uid $uid"
if out="$(from_host ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o PubkeyAuthentication=no -p "$port" "root@$host" true 2>&1)"; then
  fail "login without a key succeeded"
fi
grep -q 'Permission denied (publickey)' <<<"$out" || fail "password probe: $out"
pass "login without the key is refused and the server offers only publickey: $(tail -n 1 <<<"$out")"
fingerprint="$(from_host sh -c "ssh-keyscan -t ed25519 -p $port $host 2>/dev/null | ssh-keygen -lf - | cut -d' ' -f2")"
logged="$(docker logs "$addon" 2>&1 | grep 'SSH host key:')"
[[ -n "$fingerprint" && "$logged" == *"$fingerprint"* ]] || fail "add-on log does not show host key $fingerprint"
pass "add-on log shows the host key the client sees: $fingerprint"
hostkey_before="$(from_host ssh-keyscan -t ed25519 -p "$port" "$host" 2>/dev/null | awk '{print $3}')"
stop_addon
start_addon
wait_for "sshd" sshd_running
read -r host port <<<"$(published 22/tcp)"
hostkey_after="$(from_host ssh-keyscan -t ed25519 -p "$port" "$host" 2>/dev/null | awk '{print $3}')"
[ -n "$hostkey_before" ] && [ "$hostkey_before" = "$hostkey_after" ] || fail "SSH host key changed"
pass "SSH host key unchanged after recreating the container"

step "5. Replay pvecm qdevice setup against the add-on at $addon_ip"
replay 155 ssh-copy-id -i /root/.ssh/id_rsa "root@$addon_ip"
echo "  [pvecm.pm:170] ssh -o BatchMode=yes -lroot $addon_ip corosync-qnetd-certutil -i"
if ! in_client ssh -o BatchMode=yes -lroot "$addon_ip" corosync-qnetd-certutil -i; then
  echo "  exited non-zero because the database exists, which pvecm ignores (noerr => 1)"
fi
replay 175 scp -o BatchMode=yes "root@[$addon_ip]:$qnetd_db/qnetd-cacert.crt" /etc/pve/qnetd-cacert.crt
replay 186 corosync-qdevice-net-certutil -i -c /etc/pve/qnetd-cacert.crt
replay 195 rm /etc/pve/qnetd-cacert.crt
replay 198 corosync-qdevice-net-certutil -r -n "$cluster"
replay 201 scp -o BatchMode=yes "$node_db/qdevice-net-node.crq" "root@[$addon_ip]:/tmp"
replay 204 ssh -o BatchMode=yes -lroot "$addon_ip" corosync-qnetd-certutil -s -c /tmp/qdevice-net-node.crq -n "$cluster"
replay 216 scp -o BatchMode=yes "root@[$addon_ip]:$qnetd_db/cluster-$cluster.crt" "$node_db"
replay 223 corosync-qdevice-net-certutil -M -c "$node_db/cluster-$cluster.crt"
replay 226 scp -o BatchMode=yes "$node_db/qdevice-net-node.p12" /etc/pve/
replay 236 corosync-qdevice-net-certutil -m -c /etc/pve/qdevice-net-node.p12
in_client test -s /etc/pve/qdevice-net-node.p12 || fail "no .p12 on the node"
pass "node has /etc/pve/qdevice-net-node.p12 ($(in_client stat -c %s /etc/pve/qdevice-net-node.p12) bytes)"
issuer="$(in_client certutil -L -d "$node_db" -n "Cluster Cert" | grep -m1 'Issuer:')" || fail "no Cluster Cert in node db"
pass "node db holds the signed Cluster Cert, $(tr -s ' ' <<<"$issuer")"

step "6. Real connection: corosync + corosync-qdevice on the node"
docker exec -i "$client" sh -c 'cat >/etc/corosync/corosync.conf' <<EOF
totem {
  version: 2
  cluster_name: $cluster
  transport: knet
  crypto_cipher: none
  crypto_hash: none
}
nodelist {
  node {
    name: node1
    nodeid: 1
    ring0_addr: $client_ip
  }
}
quorum {
  provider: corosync_votequorum
  device {
    model: net
    votes: 1
    net {
      tls: on
      host: $addon_ip
      algorithm: ffsplit
    }
  }
}
logging {
  to_stderr: yes
  to_syslog: no
}
EOF
docker exec -d "$client" corosync -f
wait_for "corosync" in_client corosync-cmapctl totem.cluster_name
docker exec -d "$client" corosync-qdevice -f
cluster_listed() { in_addon corosync-qnetd-tool -l | grep -q "Cluster \"$cluster\""; }
wait_for "qnetd to list cluster $cluster" cluster_listed
in_addon corosync-qnetd-tool -l | sed 's/^/  /'
pass "qnetd lists cluster \"$cluster\""
qdevice_vote() { in_client corosync-quorumtool -s | grep -q 'Flags:.*Quorate Qdevice'; }
wait_for "the node to count the Qdevice vote" qdevice_vote
in_client corosync-quorumtool -s | sed -n '/Votequorum information/,$p' | sed 's/^/  /'
pass "node counts the Qdevice vote"

step "6b. Setup mode off, restart, the node reconnects"
printf '{"setup_ssh": false}' | write_options
stop_addon
start_addon
if sshd_running; then fail "sshd still running after setup_ssh was turned off"; fi
pass "sshd is gone after turning setup_ssh off"
wait_for "the node to reconnect" cluster_listed
pass "qnetd lists cluster \"$cluster\" again after the restart"
wait_for "the node to count the Qdevice vote again" qdevice_vote
pass "node counts the Qdevice vote again: $(in_client corosync-quorumtool -s | grep 'Flags:' | tr -s ' ')"

printf '\nAll checks passed.\n'
