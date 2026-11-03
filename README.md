# Proxmox QNetd add-on for Home Assistant

[![CI](https://github.com/samohtnt/ha-qnetd-addon/actions/workflows/ci.yaml/badge.svg)](https://github.com/samohtnt/ha-qnetd-addon/actions/workflows/ci.yaml)

This repository has one Home Assistant add-on, **Proxmox QNetd**. It runs `corosync-qnetd` on a Home Assistant device, so a two-node Proxmox VE cluster has a third vote and keeps quorum when one node is down.

The add-on builds on the device from `debian:trixie-slim`, for `aarch64` and `amd64`. It keeps its certificate database in the add-on's `/data`, which survives Home Assistant OS updates and is part of Home Assistant backups.

## Install

1. In Home Assistant, go to **Settings** > **Add-ons** > **Add-on Store**.
2. Open the menu (three dots) and select **Repositories**. Add `https://github.com/samohtnt/ha-qnetd-addon`.
3. Install **Proxmox QNetd** and start it.
4. Open the add-on **Log** tab, copy the command it shows, and paste it into a root shell on one Proxmox node.

The command checks the cluster, replaces an old QDevice if there is one, runs `pvecm qdevice setup`, and checks the vote on every node. [The add-on documentation](qnetd/DOCS.md) explains each step, the pairing that makes it work, and troubleshooting.

You need a Proxmox VE cluster with an even number of nodes, all online, and a fixed IP address for Home Assistant.

## Repository layout

- `repository.yaml` names the repository for Home Assistant.
- `qnetd/config.yaml` is the add-on manifest: options, ports, and architectures.
- `qnetd/Dockerfile` installs `corosync-qnetd`, `openssh-server`, `jq`, and `curl` on Debian trixie.
- `qnetd/run.sh` starts the add-on. It creates the certificate database on first start, opens pairing when no cluster is set up yet or `open_pairing` is on, and then runs `corosync-qnetd` as the `coroqnetd` user.
- `qnetd/qnetd-pairing` runs pairing: the SSH server on port 22022, the one-time code, key enrolment, and closing.
- `qdevice-setup.sh` is the script the log tells you to run on a Proxmox node.
- `qnetd/DOCS.md` is the guide that Home Assistant shows on the add-on page.
- `tests/e2e.sh` is the end-to-end test, and `tests/fake-pvecm` stands in for `pvecm` in it.
- `.github/workflows/ci.yaml` runs the Home Assistant add-on linter, and runs the end-to-end test for `amd64` and, under QEMU, for `aarch64`.

## Release

The pairing command downloads `qdevice-setup.sh` from the tag `v<version>`, where the version comes from `qnetd/config.yaml`. After you bump the version, push a matching tag, for example `git tag v1.1.0 && git push origin v1.1.0`. Without the tag, the command in the log fails with a 404.

## Run the tests

`tests/e2e.sh` needs Bash and a Docker engine. It runs from Git Bash on Windows too.

```sh
bash tests/e2e.sh
```

To test the add-on for another platform, set `ADDON_PLATFORM`, for example `ADDON_PLATFORM=linux/arm64`. Only the add-on runs on that platform. The node containers stay native, as real `amd64` Proxmox hosts would. On an `amd64` host that needs QEMU emulation, and `E2E_WAIT=180` gives the slower emulated add-on time to start.

The script lints the shell scripts and the `Dockerfile`, builds the add-on image and a node image, and starts two node containers as a corosync cluster. The cluster starts with a QDevice configured at an address where nothing runs, and a stale certificate store, like a cluster whose old tie-breaker is gone. The script then checks the following:

- On a fresh install, `corosync-qnetd` runs as `coroqnetd` and answers on TCP 5403, pairing opens, and the log shows the command with a code and the host key the server presents.
- Pairing refuses root before a key is enrolled and refuses a wrong code. The `pair` user can only enrol a key. `qdevice-setup.sh` stops on a wrong host key before it sends the code or changes the cluster.
- `qdevice-setup.sh`, run on node1 with the code from the log, replaces the dead QDevice. Both nodes then count the vote, pairing closes and logs it, and node1's SSH config is as it was.
- A second run reports that the setup is already done and changes nothing.
- After a restart the CA is the same, pairing stays closed, and both nodes count the vote again.
- `open_pairing` reopens pairing with a new code, and the old code no longer works.

The script removes its containers, network, and volume when it exits, and it exits non-zero on the first failed check. It keeps the images it builds, so later runs are faster. It generates new SSH keys in the node containers on every run and never writes them to the host.

The tests do not cover these things:

- Home Assistant itself: the Supervisor build, the option schema, the Supervisor API calls that fill in the IP address and port in the log, and whether the watchdog restarts the add-on when the health check fails.
- A real Proxmox node. `tests/fake-pvecm` runs the same `ssh`, `scp`, and certificate commands as `pvecm qdevice setup` in `src/PVE/CLI/pvecm.pm`, but it is not `pvecm`.

## License

MIT. See [LICENSE](LICENSE).
