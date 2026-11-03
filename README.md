# Proxmox QNetd add-on for Home Assistant

This repository has one Home Assistant add-on, **Proxmox QNetd**. It runs `corosync-qnetd` on a Home Assistant device, so a two-node Proxmox VE cluster has a third vote and keeps quorum when one node is down.

The add-on builds on the device from `debian:trixie-slim`, for `aarch64` and `amd64`. It keeps its certificate database in the add-on's `/data`, which survives Home Assistant OS updates and is part of Home Assistant backups.

## Add the repository

1. In Home Assistant, go to **Settings** > **Add-ons** > **Add-on Store**.
2. Open the menu (three dots) and select **Repositories**.
3. Add `https://github.com/samohtnt/ha-qnetd-addon` and select **Add**.
4. Install **Proxmox QNetd**, then follow [the add-on documentation](qnetd/DOCS.md) to join it to your cluster.

You need a two-node Proxmox VE cluster, root shell access to one node, and a fixed IP address for Home Assistant. The guide walks through the rest, including removing an old QDevice.

## Repository layout

- `repository.yaml` names the repository for Home Assistant.
- `qnetd/config.yaml` is the add-on manifest: options, ports, and architectures.
- `qnetd/Dockerfile` installs `corosync-qnetd`, `openssh-server`, and `jq` on Debian trixie.
- `qnetd/run.sh` starts the add-on. It creates the certificate database on first start, starts the setup SSH server when `setup_ssh` is on, and then runs `corosync-qnetd` as the `coroqnetd` user.
- `qnetd/DOCS.md` is the operator guide that Home Assistant shows on the add-on page.
- `tests/e2e.sh` is the end-to-end test.
- `.github/workflows/ci.yaml` runs the Home Assistant add-on linter, and runs the end-to-end test for `amd64` and, under QEMU, for `aarch64`.

## Run the tests

`tests/e2e.sh` needs Bash and a Docker engine. It runs from Git Bash on Windows too.

```sh
bash tests/e2e.sh
```

To test another platform, set `DOCKER_DEFAULT_PLATFORM`, for example `DOCKER_DEFAULT_PLATFORM=linux/arm64`. On an `amd64` host that needs QEMU emulation, and `E2E_WAIT=180` gives the slower emulated services time to start.

The script lints `run.sh`, `e2e.sh`, and the `Dockerfile` with the `koalaman/shellcheck` and `hadolint/hadolint` images. It then builds the add-on image and a second image that plays a Proxmox node. With those it checks the following:

- In default mode, `corosync-qnetd` runs as `coroqnetd` and answers on TCP 5403, and nothing listens on port 22.
- After the container is recreated with the same `/data`, the CA fingerprint is the same.
- In setup mode, root can log in with the test key, and the server refuses logins without it.
- The node container replays every command that `pvecm qdevice setup` runs, with the same arguments, and ends with a signed cluster certificate and a `.p12` file.
- A one-node corosync cluster with `corosync-qdevice` connects to the add-on, `corosync-qnetd-tool -l` lists it, and the node counts the QDevice vote. The node reconnects after the add-on restarts with setup mode off.

The script removes its containers, network, and volume when it exits, and it exits non-zero on the first failed check. It keeps the two images it builds, so later runs are faster. It generates a new SSH key in the node container on every run and never writes it to the host.

The tests do not cover these things:

- Home Assistant itself: the Supervisor build, the option schema validation, the port mapping in the **Network** section, and the watchdog.
- A real Proxmox node. The replay copies the `pvecm` commands from `src/PVE/CLI/pvecm.pm` in `pve-cluster`, but it does not run `pvecm`.

## License

MIT. See [LICENSE](LICENSE).
