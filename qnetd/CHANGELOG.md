# Changelog

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
