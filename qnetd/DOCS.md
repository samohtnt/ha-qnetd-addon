# Proxmox QNetd

This add-on runs `corosync-qnetd`, the server side of a Proxmox VE QDevice. A two-node cluster uses it as a third vote, so the cluster keeps quorum when one node is down.

The add-on keeps its certificate database in `/data/qnetd`. Home Assistant keeps `/data` across add-on and OS updates and includes it in backups. The backup therefore holds the QNetd CA private key, so protect it like any other secret.

## Set up the QDevice

1. Install and start the add-on.
2. Open the **Log** tab. It shows a command that starts with `curl -fsSLo /tmp/qdevice-setup.sh`.
3. Copy that command. On one Proxmox node, open a root shell and paste it.

That is all. The command checks the cluster, sets up the QDevice on every node, checks the vote, and closes pairing on the add-on. It asks before it removes or installs anything. If it stops with an error, fix the problem it names and paste the same command again.

### What you need

- A Proxmox VE cluster with an even number of nodes, usually two, all online.
- A fixed IP address for Home Assistant, such as a DHCP reservation. The cluster stores the address, so the vote breaks when it changes.
- TCP 5403 open from every node to Home Assistant, and TCP 22022 from the node where you paste the command.

### What the command does

The command downloads `qdevice-setup.sh` from this repository, at the tag that matches the add-on version, and runs it. The script does these steps:

1. Checks that the cluster is quorate, that every node is online and reaches Home Assistant on port 5403, and that `corosync-qdevice` is installed. It offers to install the package where it is missing.
2. Offers to remove a QDevice that does not give every node a vote, such as an old tie-breaker that is gone, and leftover QDevice certificates. It never replaces a working QDevice at another address unless you add `--replace-working`.
3. Checks that the add-on's SSH host key matches the one in the log, then sends the one-time pairing code and the node's root public key. Nothing is sent if the host key does not match.
4. Runs `pvecm qdevice setup`. `pvecm` uses SSH on port 22 only, so for the duration of the script a block at the top of `/root/.ssh/config` points it at port 22022 and the pinned host key. The script removes the block when it exits.
5. Waits until every node counts the QDevice vote, then closes pairing.

The script asks about every change before it pairs, and makes the changes only after pairing works. A wrong address or an old code leaves the cluster as it was.

To read the script before you run it, run only the `curl` part of the command and open `/tmp/qdevice-setup.sh`, or run `bash /tmp/qdevice-setup.sh --help`.

## Pairing

Pairing is how the Proxmox node gets SSH access to the add-on for `pvecm qdevice setup`, without you copying keys around.

- Pairing opens by itself when the add-on starts and has not set up a cluster yet. It stays open for 60 minutes, or until the setup closes it. Once a node has enrolled, pairing stays open for at least 15 more minutes, so the setup never loses it halfway.
- Each time pairing opens, the add-on makes a new code. The code is valid only while pairing is open.
- While pairing is open, an SSH server listens on port 22022. It accepts the user `pair` with the code, which can only enrol a public key, and `root` with an enrolled key. Closing pairing stops the server and forgets the enrolled keys.
- Once a cluster is set up, pairing stays closed across restarts. To add a second cluster or redo the setup, turn on `open_pairing`, restart the add-on, and turn it off again afterwards.

## Options

| Option | Default | Meaning |
|---|---|---|
| `open_pairing` | `false` | Opens pairing at start even when a cluster is already set up. |

| Port | Default | Use |
|---|---|---|
| `5403/tcp` | `5403` | QNetd. Every Proxmox node connects here. TLS with client certificates. |
| `22022/tcp` | `22022` | Pairing SSH. Nothing listens here unless pairing is open. |

If you change the pairing port in the **Network** section, the log shows the new port in the command. Do not change the QNetd port. Proxmox always connects to 5403.

## Check the vote

On any node, run `pvecm status`. For a two-node cluster it shows `Flags: Quorate Qdevice`, `Expected votes: 3`, `Total votes: 3`, and `A,V,NMW` for each node.

To test the vote without a reboot, stop the add-on. `pvecm status` then shows one vote fewer and the cluster stays quorate. Start the add-on again and the vote returns within about 30 seconds. Do not test by rebooting a node outside a maintenance window.

## Monitor the QDevice

- Probe TCP 5403 on Home Assistant, for example with a Prometheus blackbox `tcp_connect` probe. Alert when it fails for 10 minutes.
- Alert when the QDevice state in the Proxmox API is not connected for 10 minutes.

The add-on has a health check that asks `corosync-qnetd` for its status every 30 seconds. Turn on **Watchdog** on the add-on page, and Home Assistant restarts the add-on when the check fails.

## Troubleshooting

| Message or symptom | Cause and fix |
|---|---|
| `nothing answers on ...:22022` | Pairing is closed or the add-on is stopped. If no cluster is set up yet, restart the add-on. Otherwise turn on `open_pairing` and restart it. Then copy the new command. After several failed attempts, wait a minute: the add-on slows down repeated failed logins. |
| `the SSH host key ... is ..., but the add-on log says ...` | The command reached another device. Check the IP address in the command. |
| `the add-on refused the pairing code` | The code is from an earlier start. Copy the command again from the log. |
| `offline: ...` | Start every node first. `pvecm qdevice setup` needs all of them. |
| `cannot reach ... over SSH the way pvecm does` | Root SSH between the nodes is broken. Run `pvecm updatecerts` on each node. |
| `the cluster already has a working QDevice at ...` | Add `--replace-working` to the command if you mean to move the vote to this add-on. |
| `... cannot reach ...:5403` | A firewall blocks the node, or the add-on is stopped. |
| The QDevice state stays `Connect failed` later | A node cannot reach the add-on on 5403, or the Home Assistant IP address changed. |
| The nodes log TLS or certificate errors after a reinstall | The add-on lost `/data` and made a new CA. See [Recover after data loss](#recover-after-data-loss). |

## Recover after data loss

If `/data/qnetd` is lost, for example by reinstalling the add-on without a backup, the add-on creates a new CA and opens pairing. The nodes fail the TLS handshake with the new CA. Restore the add-on from a Home Assistant backup, or paste the new command from the log. The script sees the broken QDevice and offers to replace it.

## Roll back

On a quorate node, run `pvecm qdevice remove`. Then uninstall the add-on. The cluster goes back to one vote per node, with no tie-breaker.

## Rebuild for security updates

The add-on builds on your Home Assistant device from `debian:trixie-slim`. Rebuild it from the add-on page from time to time to pick up Debian security updates. The rebuild keeps `/data`.
