#!/usr/bin/env bash
# Checks the release rule against a base, normally the default branch:
# - the top "## " heading of qnetd/CHANGELOG.md is the version in qnetd/config.yaml, and
# - when qdevice-setup.sh differs from the base, that version is higher than the base's.
# The pairing command downloads qdevice-setup.sh from the tag v<version>, and the tag job in
# .github/workflows/ci.yaml does nothing when that tag exists, so a change to the script
# without a new version never reaches users.
#
# Usage: bash tests/check-version.sh BASE, run from the top of the tree to check.
# BASE is a directory that holds the base's files (as forge's /forge-base does) or a git revision.
# It needs only bash, coreutils and, for a git revision, git.
#
# It checks the directory it was started in, not the tree it lives in, so .forge/check can run
# the default branch's copy (/forge-base/tests/check-version.sh) on the tree under test (/work).
# A pull request then cannot weaken the check by changing this file.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 BASE (a directory or a git revision), run from the top of the tree to check" >&2; exit 2; }
base="$1"
[ -f qnetd/config.yaml ] && [ -f qdevice-setup.sh ] ||
  { echo "FAIL  no qnetd/config.yaml and qdevice-setup.sh in $PWD; run this from the top of the tree to check" >&2; exit 2; }

# Prints a file of the base, or fails when the base does not have it.
base_file() {
  if [ -d "$base" ]; then cat "$base/$1" 2>/dev/null; else git show "$base:$1" 2>/dev/null; fi
}
# The same pattern as the tag job in .github/workflows/ci.yaml.
version_in() { sed -n 's/^version: "\(.*\)"$/\1/p'; }

failed=0
fail() { printf 'FAIL  %s\n' "$*"; failed=1; }
pass() { printf 'PASS  %s\n' "$*"; }

version=$(version_in <qnetd/config.yaml)
[ -n "$version" ] || { echo 'FAIL  no version: "x.y.z" line in qnetd/config.yaml'; exit 1; }

top=$(sed -n 's/^## \(.*\)$/\1/p' qnetd/CHANGELOG.md | head -n 1)
if [ "$top" = "$version" ]; then
  pass "qnetd/CHANGELOG.md starts with ## $version"
else
  fail "the top entry of qnetd/CHANGELOG.md is '## ${top:-(none)}', not '## $version' from qnetd/config.yaml"
fi

if base_setup=$(base_file qdevice-setup.sh) && [ "$base_setup" = "$(cat qdevice-setup.sh)" ]; then
  pass "qdevice-setup.sh is unchanged from the base"
else
  base_version=$(base_file qnetd/config.yaml | version_in || true)
  if [ -z "$base_version" ]; then
    fail "qdevice-setup.sh differs from the base, and the base has no version in qnetd/config.yaml. Is '$base' the right base?"
  elif [ "$version" != "$base_version" ] &&
    [ "$(printf '%s\n%s\n' "$base_version" "$version" | sort -V | tail -n 1)" = "$version" ]; then
    pass "qdevice-setup.sh changed, and the version went from $base_version to $version"
  else
    fail "qdevice-setup.sh changed, but the version in qnetd/config.yaml is $version and the base's is $base_version." \
      "Users download the script from the tag v<version>, so raise the version and add a '## <version>' entry at the top of qnetd/CHANGELOG.md." \
      "If the base changed the script since your branch started, merge the base first."
  fi
fi

exit "$failed"
