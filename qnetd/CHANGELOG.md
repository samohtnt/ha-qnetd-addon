# Changelog

## 1.0.1

- Replace the port watchdog with a Docker health check that runs `corosync-qnetd-tool -s`.
- Generic setup guide with a troubleshooting table.

## 1.0.0

- First release. Runs corosync-qnetd from Debian trixie as the `coroqnetd` user.
- Keeps the qnetd certificate database in `/data/qnetd`, so it survives updates and is part of Home Assistant backups.
- Optional key-only SSH server (`setup_ssh`) so that `pvecm qdevice setup` works without changes.
