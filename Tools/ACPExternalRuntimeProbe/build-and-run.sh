#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
derived_data="$repo_root/build/ACPExternalRuntimeProbeDerived"
fixture_directory=$(mktemp -d "${TMPDIR:-/tmp}/acp-external-runtime-fixture.XXXXXX")
unauthorized_directory=$(mktemp -d "${TMPDIR:-/tmp}/acp-external-runtime-unauthorized.XXXXXX")
fixture="$fixture_directory/acp-fixture"
trap 'rm -rf "$fixture_directory" "$unauthorized_directory"' EXIT HUP INT TERM

cp "$repo_root/Tools/ACPExternalRuntimeProbe/Fixture/acp-fixture.sh" "$fixture"
chmod 700 "$fixture"

xcodebuild \
  -project "$repo_root/OkamiUNI.xcodeproj" \
  -scheme ACPExternalRuntimeProbe \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  build CODE_SIGNING_ALLOWED=YES

app="$derived_data/Build/Products/Release/ACPExternalRuntimeProbe.app"
binary="$app/Contents/MacOS/ACPExternalRuntimeProbe"
service="$app/Contents/XPCServices/AgentRuntimeServiceProbe.xpc"

codesign --verify --deep --strict "$app"
codesign -d --entitlements :- "$app" 2>&1
codesign -d --entitlements :- "$service" 2>&1
set +e
"$binary" "$fixture"
status=$?
set -e

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

# Re-sign a copy with the same Apple Development identity but a host bundle
# identifier that the helper's signed Info.plist does not allow. The embedded
# service remains present, so this exercises the XPC peer requirement instead
# of merely checking a requirement string with codesign.
unauthorized_app="$unauthorized_directory/ACPExternalRuntimeProbe.app"
cp -R "$app" "$unauthorized_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.okamiops.okamiuni.acp-release-probe.unauthorized' "$unauthorized_app/Contents/Info.plist"
signing_identity=$(security find-identity -v -p codesigning | awk '/Apple Development:/ { print $2; exit }')
if [ -z "$signing_identity" ]; then
  echo 'No Apple Development signing identity is available for the negative XPC authorization proof.' >&2
  exit 1
fi
codesign --force --deep --sign "$signing_identity" "$unauthorized_app"

set +e
unauthorized_output="$("$unauthorized_app/Contents/MacOS/ACPExternalRuntimeProbe" "$fixture")"
unauthorized_status=$?
set -e
printf '%s\n' "$unauthorized_output"

if [ "$unauthorized_status" -eq 0 ] || [ "$unauthorized_output" != 'ACP_EXTERNAL_RUNTIME_PROBE_FAILED handshake-unavailable' ]; then
  echo 'The XPC helper accepted a host with an unauthorized signed identifier.' >&2
  exit 1
fi

echo 'ACP_EXTERNAL_RUNTIME_PROBE_AUTH_REJECTED signed-id=unauthorized'
