# Proxmox QNetd

This add-on runs `corosync-qnetd`, the server side of a Proxmox VE QDevice. A two-node cluster uses it as a third vote, so the cluster keeps quorum when one node is down.

The add-on keeps its certificate database in `/data/qnetd`. Home Assistant keeps `/data` across add-on and OS updates and includes it in backups. The backup therefore holds the QNetd CA private key, so protect it like any other secret.

## Options

| Option | Default | Meaning |
|---|---|---|
| `setup_ssh` | `false` | Starts an SSH server that accepts only the key in `authorized_key`, for root. `pvecm qdevice setup` needs it. Turn it off after setup. |
| `authorized_key` | none | One public key line. Use the full contents of `/root/.ssh/id_rsa.pub` on the Proxmox node where you run `pvecm qdevice setup`. |

| Port | Default | Use |
|---|---|---|
| `5403/tcp` | `5403` | QNetd. Every Proxmox node connects here. TLS with client certificates. |
| `22/tcp` | disabled | SSH, during setup only. |

## Before you start

You need these things:

- A Proxmox VE cluster with an even number of nodes, usually two. For an odd number of nodes, Proxmox advises against a QDevice, and `pvecm qdevice setup` refuses without `--force`.
- Root shell access to one node. This guide calls it the *setup node*.
- The IP address of your Home Assistant device, written as `HA_IP` below. Give it a fixed address, such as a DHCP reservation. The cluster stores the address in `corosync.conf`, so the vote breaks when the address changes.
- A network path from every node to `HA_IP` on TCP 5403, and from the setup node to `HA_IP` on TCP 22.

One add-on can serve more than one cluster. Run the setup once from each cluster.

## Set up the QDevice

### Check the starting state

1. On the setup node, run `pvecm status`. The cluster must be quorate with all nodes online.
2. On every node, check that the `corosync-qdevice` package is installed. If it is not, run `apt install corosync-qdevice`.
3. On the setup node, check that `/root/.ssh/id_rsa.pub` exists. Proxmox creates this key when it creates or joins a cluster.
4. In Home Assistant, take a backup.

### Remove the old QDevice

Skip this section if the cluster has no QDevice. `pvecm qdevice setup` refuses to run while one is configured.

1. On the setup node, run `pvecm qdevice remove`.
2. Run `pvecm status`. Check that `Expected votes` and `Total votes` equal the number of nodes, and that the cluster is `Quorate`.

### Install the add-on in setup mode

1. In Home Assistant, go to **Settings** > **Add-ons** > **Add-on Store**.
2. Open the menu (three dots) and select **Repositories**. Add the URL of this repository.
3. Install **Proxmox QNetd**.
4. If another add-on uses port 22, such as **Terminal & SSH**, stop it for the duration of the setup.
5. On the setup node, print the root public key with `cat /root/.ssh/id_rsa.pub`.
6. On the add-on **Configuration** tab, set `setup_ssh` to on and paste the key into `authorized_key`.
7. In the **Network** section of the same tab, set `22/tcp` to `22`. Save.
8. Start the add-on and open the **Log** tab. The log shows `Setup SSH is ON` and an `SSH host key: 256 SHA256:...` line. Keep the log open for the next step.
9. On the setup node, run `ssh root@HA_IP command -v corosync-qnetd-certutil`. Check that the fingerprint SSH asks you to accept matches the `SSH host key` line in the log, then type `yes`. The command prints `/usr/bin/corosync-qnetd-certutil`.

`pvecm qdevice setup` connects with `/root/.ssh/id_rsa` and fixed SSH options. It cannot use another key or another port. That is why the add-on asks for that key and port 22.

### Join the QDevice

1. On the setup node, run `pvecm qdevice setup HA_IP`.

   The command signs a certificate for the cluster on the add-on, installs it on every node, adds a `quorum.device` section to `corosync.conf`, and starts `corosync-qdevice` on every node. For a cluster with an even number of nodes it uses the `ffsplit` algorithm.

   The first command prints `Certificate database (/etc/corosync/qnetd/nssdb) already exists`. That is expected, because the add-on creates its database on first start. `pvecm` ignores the error.
2. On every node, run `pvecm status`. For a two-node cluster, check for `Flags: Quorate Qdevice`, `Expected votes: 3`, `Total votes: 3`, and a `Qdevice` membership line with `A,V,NMW`.
3. In the Proxmox web interface, or with `pvesh get /cluster/config/qdevice`, check that the state is connected and the host is `HA_IP`.

### Close setup access

1. On the add-on **Configuration** tab, set `setup_ssh` to off and clear the `22/tcp` port. Save and restart the add-on.
2. Start **Terminal & SSH** again if you stopped it.
3. On every node, run `pvecm status` again. The QDevice vote returns within about 30 seconds of the add-on restart.

## Test the vote without a reboot

Do not test by rebooting a node outside a maintenance window.

1. Stop the add-on. On the setup node, `pvecm status` now shows one vote fewer and the cluster stays quorate.
2. Start the add-on. The vote returns within about 30 seconds.

## Monitor the QDevice

- Probe `HA_IP:5403` over TCP, for example with a Prometheus blackbox `tcp_connect` probe. Alert when it fails for 10 minutes.
- Alert when the QDevice state in the Proxmox API is not connected for 10 minutes.

The add-on also has a health check that asks `corosync-qnetd` for its status every 30 seconds. Turn on **Watchdog** on the add-on page, and Home Assistant restarts the add-on when the check fails.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `pvecm qdevice setup` fails with `Permission denied (publickey)` | The key in `authorized_key` is not the setup node's `/root/.ssh/id_rsa.pub`, or `setup_ssh` is off. Fix the option and restart the add-on. |
| `pvecm qdevice setup` fails with `Connection refused` on port 22 | `22/tcp` is not mapped in the **Network** section, or another add-on holds port 22. |
| The add-on log says `setup_ssh is on but authorized_key is empty` | Paste the key, or turn `setup_ssh` off. |
| The QDevice state stays `Connect failed` | A node cannot reach `HA_IP:5403`. Check the firewalls between the nodes and Home Assistant, and check that `HA_IP` has not changed. |
| The nodes log TLS or certificate errors after a reinstall | The add-on lost `/data` and made a new CA. See [Recover after data loss](#recover-after-data-loss). |

## Recover after data loss

If `/data/qnetd` is lost, for example by reinstalling the add-on without a backup, the add-on creates a new CA. The nodes then fail the TLS handshake. Restore the add-on from a Home Assistant backup, or repeat the setup from [Remove the old QDevice](#remove-the-old-qdevice).

## Roll back

On a quorate node, run `pvecm qdevice remove`. Then uninstall the add-on. The cluster goes back to one vote per node, with no tie-breaker.

## Rebuild for security updates

The add-on builds on your Home Assistant device from `debian:trixie-slim`. Rebuild it from the add-on page from time to time to pick up Debian security updates. The rebuild keeps `/data`.
