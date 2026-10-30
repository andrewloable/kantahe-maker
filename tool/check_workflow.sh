#!/bin/sh
# Checks .github/workflows/build.yml and the README release section. Prints PASS, FAIL or
# SKIP per check and exits 1 if any check fails. Run it from anywhere: sh tool/check_workflow.sh
cd "$(dirname "$0")/.." || exit 2
W=.github/workflows/build.yml
fail=0

check() { # name function
  if "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi
}

attach_job() { sed -n '/^  attach:/,$p' "$W"; }

actionlint_clean() { actionlint "$W" >/dev/null 2>&1; }
triggers() {
  grep -q '^  workflow_dispatch:' "$W" && grep -q 'types: \[published\]' "$W" &&
    ! grep -q 'tags:' "$W"
}
only_these_events() {
  # The events under "on:" are exactly workflow_dispatch and release.
  events=$(awk '/^on:/{f=1;next} /^[a-z]/{f=0} f && /^  [a-z_]+:/{gsub(/[ :]/,"");print}' "$W" | sort | tr '\n' ' ')
  [ "$events" = "release workflow_dispatch " ]
}
only_known_permissions() {
  # "permissions:" appears twice: once at the top, once in the attach job; nothing else.
  [ "$(grep -c 'permissions:' "$W")" -eq 2 ] &&
    grep -n 'permissions:' "$W" | head -1 | grep -q ':permissions:$' &&
    [ "$(grep -n 'permissions:' "$W" | tail -1 | cut -d: -f1)" -gt "$(grep -n '^  attach:' "$W" | cut -d: -f1)" ] &&
    ! grep -qE 'write-all|read-all' "$W"
}
top_level_read() { awk '/^jobs:/{exit} /contents: read/{f=1} END{exit !f}' "$W"; }
single_write() {
  [ "$(grep -c 'contents: write' "$W")" -eq 1 ] || return 1
  line=$(grep -n 'contents: write' "$W" | cut -d: -f1)
  start=$(grep -n '^  attach:' "$W" | cut -d: -f1)
  [ -n "$start" ] && [ "$line" -gt "$start" ]
}
no_release_creation() {
  ! grep -qE 'git push|git tag|gh release create|softprops|action-gh-release|create-release|ncipollo' "$W"
}
attach_after_builds() {
  attach_job | grep -q 'needs: \[macos, linux, windows\]' &&
    attach_job | grep -q "if: github.event_name == 'release'"
}
tag_not_in_script() {
  [ "$(grep -c 'github.event.release.tag_name' "$W")" -eq 1 ] &&
    grep 'github.event.release.tag_name' "$W" | grep -qE '^ *TAG: '
}
three_os_jobs() {
  grep -q 'macos-latest' "$W" && grep -q 'ubuntu-latest' "$W" && grep -q 'windows-latest' "$W"
}
three_uploads() { [ "$(grep -c 'actions/upload-artifact@' "$W")" -eq 3 ]; }
build_commands() {
  grep -q 'flutter build macos --release' "$W" && grep -q 'flutter build linux --release' "$W" &&
    grep -q 'flutter build windows --release' "$W"
}
gate_steps() {
  [ "$(grep -c 'flutter analyze' "$W")" -eq 3 ] && [ "$(grep -c 'flutter test' "$W")" -eq 3 ]
}
macos_zip_quoted() {
  grep -qF '"build/macos/Build/Products/Release/Kantahe Maker.app"' "$W"
}
actions_pinned() {
  grep -q 'uses:' "$W" && ! grep 'uses:' "$W" | grep -qvE '@v[0-9]+\.[0-9]+\.[0-9]+'
}
flutter_version_pinned() {
  v=$(flutter --version | head -1 | awk '{print $2}')
  [ -n "$v" ] && [ "$(grep -cF "flutter-version: '$v'" "$W")" -eq 3 ]
}
readme_section() {
  grep -q 'Building releases' README.md && grep -q 'libmpv' README.md &&
    grep -q 'unsigned' README.md && grep -q 'SmartScreen' README.md &&
    grep -q 'assets/branding/lockup-light.png' README.md && grep -q 'published' README.md
}

if command -v actionlint >/dev/null 2>&1; then
  check actionlint_clean actionlint_clean
else
  echo "SKIP actionlint_clean (actionlint is not installed)"
fi
check triggers triggers
check only_these_events only_these_events
check top_level_read top_level_read
check only_known_permissions only_known_permissions
check single_write single_write
check no_release_creation no_release_creation
check attach_after_builds attach_after_builds
check tag_not_in_script tag_not_in_script
check three_os_jobs three_os_jobs
check three_uploads three_uploads
check build_commands build_commands
check gate_steps gate_steps
check macos_zip_quoted macos_zip_quoted
check actions_pinned actions_pinned
if command -v flutter >/dev/null 2>&1; then
  check flutter_version_pinned flutter_version_pinned
else
  echo "SKIP flutter_version_pinned (flutter is not installed)"
fi
check readme_section readme_section
exit $fail
