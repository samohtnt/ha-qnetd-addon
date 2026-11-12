# Rules for agents

The [README](README.md) describes the layout, the release rule, the tests and what they do not
cover. Read it first. This file lists only the rules that are easy to break.

## Releases

- The pairing command in the add-on log downloads `qdevice-setup.sh` from the tag `v<version>`,
  where the version is `version` in `qnetd/config.yaml` (see `qnetd/qnetd-pairing`).
- For every change to `qdevice-setup.sh`, bump `version` in `qnetd/config.yaml` and add a
  `## <version>` entry at the top of `qnetd/CHANGELOG.md`.
- Without a bump, the `tag` job in `.github/workflows/ci.yaml` finds the tag already there and does
  nothing, so users keep downloading the old script. `tests/check-version.sh` catches a missing bump
  or CHANGELOG entry: `.forge/check` runs it against the default branch, and `tests/e2e.sh` runs it
  on GitHub pull requests. Run `bash tests/check-version.sh origin/main` before you commit.
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

- Lint runs in two places, with the same tool versions and the same file list:
  - Step "0. Lint" of `tests/e2e.sh`, which needs Docker. It runs the pinned images
    `hadolint/hadolint:v2.15.1` and `koalaman/shellcheck:v0.11.0`, set at the top of that step, and
    reads the Dockerfile and each script on stdin:

    ```sh
    hadolint_image=hadolint/hadolint:v2.15.1
    shellcheck_image=koalaman/shellcheck:v0.11.0
    docker run --rm -i "$hadolint_image" <qnetd/Dockerfile
    for f in qnetd/run.sh qnetd/qnetd-pairing qdevice-setup.sh tests/fake-pvecm tests/fake-systemctl tests/e2e.sh tests/check-version.sh; do
      docker run --rm -i "$shellcheck_image" -s bash - <"$f"
    done
    ```

    Keep these fixed tags; never switch to `latest`, `stable` or an untagged image. They keep a new
    upstream release from changing CI, and they match the binaries that
    `.forge/image/Containerfile` copies from the same images, pinned by digest. To move to a new
    version, change the tag in `tests/e2e.sh`, the digest and comment in
    `.forge/image/Containerfile`, and the versions in the README and here, together.

  - `.forge/check`, which runs in forge in the image from `.forge/image/Containerfile`, where
    `hadolint` and `shellcheck` are installed as binaries. It runs `hadolint - <qnetd/Dockerfile`,
    then `shellcheck -s bash - <"$f"` on every file in the union of the shellcheck list in the
    default branch's `tests/e2e.sh` and the list in the change, so a change can add a file but not
    drop one. Then, from `/work`, it runs the default branch's copy of the script,
    `bash /forge-base/tests/check-version.sh /forge-base`, the release rule above, so a change
    cannot weaken the script that judges it. The script checks the directory it is started in.

- End-to-end test, which needs Bash, a Docker engine and the network, and runs in GitHub CI for
  `amd64` and `arm64`: `bash tests/e2e.sh`. See the README for `ADDON_PLATFORM` and `E2E_WAIT`.
  It cannot run in forge.
- The Home Assistant add-on linter (`frenck/action-addon-linter` on `./qnetd`) runs only in GitHub CI.
