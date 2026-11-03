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
| `5403/tcp` | `5403` | QNetd. Both Proxmox nodes connect here. TLS with client certificates. |
| `22/tcp` | disabled | SSH, during setup only. |

## Set up the QDevice

These steps use the example cluster `sov-arbiter`, with the nodes `sovereign` (`192.168.9.55`) and `Arbiter` (`192.168.9.101`), and Home Assistant at `192.168.9.202`. Use your own addresses.

### Check the starting state

1. On `sovereign`, run `pvecm status`. The cluster must be quorate with both nodes online.
2. On both nodes, check that the `corosync-qdevice` package is installed. If it is not, run `apt install corosync-qdevice`.
3. In Home Assistant, take a backup.

### Remove the old QDevice

If the cluster still has a QDevice in its configuration, remove it first. `pvecm qdevice setup` refuses to run while one is configured.

1. On `sovereign`, run `pvecm qdevice remove`.
2. Run `pvecm status`. Check that it shows `Expected votes: 2`, `Total votes: 2`, and `Quorate`.

### Install the add-on in setup mode

1. In Home Assistant, go to **Settings** > **Add-ons** > **Add-on Store**.
2. Open the menu (three dots) and select **Repositories**. Add the URL of this repository.
3. Install **Proxmox QNetd**.
4. If another add-on uses port 22, such as **Terminal & SSH**, stop it for the duration of the setup.
5. On `sovereign`, print the root public key with `cat /root/.ssh/id_rsa.pub`.
6. On the add-on **Configuration** tab, set `setup_ssh` to on and paste the key into `authorized_key`.
7. In the **Network** section of the same tab, set `22/tcp` to `22`. Save.
8. Start the add-on and open the **Log** tab. The log shows `Setup SSH is ON` and an `SSH host key: 256 SHA256:...` line. Keep the log open for the next step.
9. On `sovereign`, run `ssh root@192.168.9.202 command -v corosync-qnetd-certutil`. Check that the fingerprint SSH asks you to accept matches the `SSH host key` line in the log, then type `yes`. The command prints `/usr/bin/corosync-qnetd-certutil`.

`pvecm qdevice setup` connects with `/root/.ssh/id_rsa` and fixed SSH options. It cannot use another key or another port. That is why the add-on asks for that key and port 22.

### Join the QDevice

1. On `sovereign`, run `pvecm qdevice setup 192.168.9.202`.

   The command signs a certificate for the cluster on the add-on, installs it on both nodes, adds a `quorum.device` section to `corosync.conf`, and starts `corosync-qdevice` on both nodes. For a cluster with an even number of nodes it uses the `ffsplit` algorithm.

   The first command prints `Certificate database (/etc/corosync/qnetd/nssdb) already exists`. That is expected, because the add-on creates its database on first start. `pvecm` ignores the error.
2. On both nodes, run `pvecm status`. Check for `Flags: Quorate Qdevice`, `Expected votes: 3`, `Total votes: 3`, and a `Qdevice` membership line with `A,V,NMW`.
3. In the Proxmox web interface, or with `pvesh get /cluster/config/qdevice`, check that the state is connected and the host is `192.168.9.202`.

### Close setup access

1. On the add-on **Configuration** tab, set `setup_ssh` to off and clear the `22/tcp` port. Save and restart the add-on.
2. Start **Terminal & SSH** again if you stopped it.
3. On both nodes, run `pvecm status` again. The QDevice vote returns within about 30 seconds of the add-on restart.

## Test the vote without a reboot

Do not test by rebooting a node outside a maintenance window.

1. Stop the add-on. On `sovereign`, `pvecm status` now shows `Total votes: 2` of 3 and the cluster stays quorate.
2. Start the add-on. The vote returns within about 30 seconds.

## Monitor the QDevice

- Probe `192.168.9.202:5403` over TCP, for example with a Prometheus blackbox `tcp_connect` probe. Alert when it fails for 10 minutes.
- Alert when the QDevice state in the Proxmox API is not connected for 10 minutes.

The add-on also has a Home Assistant watchdog on port 5403. Home Assistant restarts the add-on when the port stops answering.

## Recover after data loss

If `/data/qnetd` is lost, for example by reinstalling the add-on without a backup, the add-on creates a new CA. The nodes then fail the TLS handshake. Restore the add-on from a Home Assistant backup, or repeat the setup from [Remove the old QDevice](#remove-the-old-qdevice).

## Roll back

On a quorate node, run `pvecm qdevice remove`. Then uninstall the add-on. The cluster returns to two votes without a tie-breaker.

## Rebuild for security updates

The add-on builds on your Home Assistant device from `debian:trixie-slim`. Rebuild it from the add-on page from time to time to pick up Debian security updates. The rebuild keeps `/data`.
