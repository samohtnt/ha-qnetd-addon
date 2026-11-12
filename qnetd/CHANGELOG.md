# Changelog

## 1.1.1

- The setup command recovers when `pvecm qdevice setup` adds the QDevice but `corosync-qdevice` fails to start on a node with `Can't read quorum.device.model cmap key`. It reloads corosync.conf and starts the daemon again, then checks the vote. This happened on a real Proxmox VE 9 cluster.
- The plan now says the script runs every step itself, so nobody runs `pvecm qdevice remove` by hand in the middle of a setup.
- Failure messages from step 4 on say what has already changed, warn against running `pvecm qdevice` commands by hand, and say how to finish: run the same command again, with `open_pairing` if pairing has closed.

## 1.1.0

- One-command setup. On first start the add-on opens pairing for 60 minutes and prints a command for a Proxmox node. The command checks the cluster, replaces a broken QDevice, runs `pvecm qdevice setup`, checks the vote, and closes pairing.
- Pairing uses port 22022, a one-time code, and a pinned host key. Port 22 stays free for other add-ons.
- New option `open_pairing` to pair again, for example for a second cluster.
- Removed the `setup_ssh` and `authorized_key` options. Pairing replaces them.
- The add-on now runs under Home Assistant's init process.

## 1.0.1

- Replace the port watchdog with a Docker health check that runs `corosync-qnetd-tool -s`.
- Generic setup guide with a troubleshooting table.

## 1.0.0

- First release. Runs corosync-qnetd from Debian trixie as the `coroqnetd` user.
- Keeps the qnetd certificate database in `/data/qnetd`, so it survives updates and is part of Home Assistant backups.
- Optional key-only SSH server (`setup_ssh`) so that `pvecm qdevice setup` works without changes.
