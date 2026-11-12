# Rules for agents

The [README](README.md) describes the layout, the release rule, the tests and what they do not
cover. Read it first. This file lists only the rules that are easy to break.

## Releases

- The pairing command in the add-on log downloads `qdevice-setup.sh` from the tag `v<version>`,
  where the version is `version` in `qnetd/config.yaml` (see `qnetd/qnetd-pairing`).
- For every change to `qdevice-setup.sh`, bump `version` in `qnetd/config.yaml` and add a
  `## <version>` entry at the top of `qnetd/CHANGELOG.md`.
- Without a bump, the `tag` job in `.github/workflows/ci.yaml` finds the tag already there and does
  nothing, so users keep downloading the old script. Nothing checks this for you.
- Do not create or push tags by hand; the `tag` job does it on `main`.

## Dockerfile

- The apt packages in `qnetd/Dockerfile` are unpinned on purpose, so each build on the device picks
  up Debian security updates. Keep them unpinned, and keep the `# hadolint ignore=DL3008` comment.

## Scripts and lint

- Every shell script must pass `shellcheck -s bash`. When you add a script, add it to the
  `for f in ...; do` shellcheck list in the "0. Lint" step of `tests/e2e.sh`. `.forge/check` reads
  that same line, so keep it on one line in that form. Never drop a file from the list.
- Keep LF line endings (`.gitattributes` enforces them).

## Checks

- Lint runs in two places, with the same tools and the same file list:
  - Step "0. Lint" of `tests/e2e.sh`, which needs Docker. It reads the Dockerfile and each script on
    stdin:

    ```sh
    docker run --rm -i hadolint/hadolint <qnetd/Dockerfile
    for f in qnetd/run.sh qnetd/qnetd-pairing qdevice-setup.sh tests/fake-pvecm tests/e2e.sh; do
      docker run --rm -i koalaman/shellcheck:stable -s bash - <"$f"
    done
    ```

  - `.forge/check`, which runs in forge in the image from `.forge/image/Containerfile`, where
    `hadolint` and `shellcheck` are installed as binaries. It runs `hadolint - <qnetd/Dockerfile`,
    then `shellcheck -s bash - <"$f"` on every file in the union of the shellcheck list in the
    default branch's `tests/e2e.sh` and the list in the change, so a change can add a file but not
    drop one.

- End-to-end test, which needs Bash, a Docker engine and the network, and runs in GitHub CI for
  `amd64` and `arm64`: `bash tests/e2e.sh`. See the README for `ADDON_PLATFORM` and `E2E_WAIT`.
  It cannot run in forge.
- The Home Assistant add-on linter (`frenck/action-addon-linter` on `./qnetd`) runs only in GitHub CI.
