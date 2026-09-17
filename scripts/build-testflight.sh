#!/bin/zsh
# Build, upload, and distribute a signed IPA through TestFlight.
#
# Credentials are read from scripts/.env.testflight (or TESTFLIGHT_ENV_FILE):
#   APP_STORE_CONNECT_KEY_ID=...
#   APP_STORE_CONNECT_ISSUER_ID=...
#   APP_STORE_CONNECT_KEY_FILE=/absolute/path/AuthKey_XXXX.p8
#   APP_IDENTIFIER=com.qinsbro.telegram
#   WHAT_TO_TEST=Optional release notes
#   TESTFLIGHT_INTERNAL_GROUP=internal
#
# Signing uses the Xcode-managed distribution certificate in the login
# keychain. Before the first run:
#   1. Sign in to Xcode > Settings > Accounts with this Apple Developer account.
#   2. In Manage Certificates, create or download a distribution certificate
#      (Apple Distribution or the legacy iOS/iPhone Distribution type). Its
#      private key must appear in the login keychain.
#   3. Enable Push Notifications and App Groups for com.qinsbro.telegram.
#   4. Download its App Store Connect profile to the project root as:
#      dmctelegram.mobileprovision

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
script_dir="$(cd "$(dirname "$0")" && pwd)"
env_file="${TESTFLIGHT_ENV_FILE:-$script_dir/.env.testflight}"
if [[ -f "$env_file" ]]; then
  set -a
  source "$env_file"
  set +a
fi
profile_source="$project_root/dmctelegram.mobileprovision"
signing_root="$project_root/build/testflight-signing"
profile_file="$signing_root/profiles/a.mobileprovision"
configuration_file="$project_root/build-system/development-configuration.json"
artifacts_dir="$project_root/build/testflight"
build_number="${1:-}"
download_ipa="$HOME/Downloads/Telegram-TestFlight-${build_number}.ipa"
api_key_json="$artifacts_dir/AppStoreConnectKey.json"
app_identifier="${APP_IDENTIFIER:-com.qinsbro.telegram}"
what_to_test="${WHAT_TO_TEST:-Local TestFlight build $build_number}"
internal_group="${TESTFLIGHT_INTERNAL_GROUP:-internal}"
marketing_version="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["app"])' "$project_root/versions.json" 2>/dev/null || true)"
bazel_path="$project_root/build-input/bazel-8.4.2-darwin-arm64"

# Keep the persistent Bazel disk cache so release rebuilds can reuse artifacts.
# The script reports its size after each build; clean it manually when needed.
bazel_cache_dir="${TELEGRAM_BAZEL_CACHE_DIR:-$HOME/telegram-bazel-cache}"
bazel_output_user_root="${TELEGRAM_BAZEL_OUTPUT_USER_ROOT:-/private/var/tmp/_bazel_qinsbro}"

if [[ -z "$build_number" || ! "$build_number" =~ '^[0-9]+$' ]]; then
  print "Usage: $0 <build-number>"
  print "Example: $0 1"
  exit 2
fi

for variable_name in APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_KEY_FILE; do
  if [[ -z "${(P)variable_name:-}" ]]; then
    print "Missing $variable_name. Add it to $env_file."
    exit 2
  fi
done
if [[ ! -f "$APP_STORE_CONNECT_KEY_FILE" ]]; then
  print "APP_STORE_CONNECT_KEY_FILE does not point to a readable .p8 key."
  exit 2
fi
if [[ -z "$marketing_version" ]]; then
  print "Could not read the marketing version from $project_root/versions.json."
  exit 2
fi
if ! command -v fastlane >/dev/null 2>&1; then
  print "fastlane is required. Install it with: gem install fastlane"
  exit 2
fi

if [[ -e "$download_ipa" ]]; then
  print "Refusing to overwrite existing IPA: $download_ipa"
  print "Use a new build number or move the existing file first."
  exit 1
fi

if [[ ! -f "$configuration_file" ]]; then
  print "Missing local build configuration: $configuration_file"
  exit 1
fi

if [[ ! -f "$profile_source" ]]; then
  print "Missing App Store Connect provisioning profile: $profile_source"
  exit 1
fi

if ! security find-identity -v -p codesigning 2>/dev/null | grep -Eq '(Apple|iOS|iPhone) Distribution'; then
  print "No distribution signing identity is available in the login keychain."
  print "In Xcode > Settings > Accounts > Manage Certificates, create or download one first."
  exit 1
fi

if [[ ! -x "$bazel_path" ]]; then
  print "Missing executable Bazel binary: $bazel_path"
  exit 1
fi

cd "$project_root"

# Make copies only in an ignored build directory: Make.py expects profiles/
# beneath --codesigningInformationPath and maps the main app profile by bundle ID.
mkdir -p "$signing_root/profiles"
cp "$profile_source" "$profile_file"

bazel_arguments=(
  "--//Telegram:disableExtensions=True"
  "--copt=-Wno-deprecated-declarations"
  "--@build_bazel_rules_swift//swift:copt=-no-warnings-as-errors"
)

make_arguments=(
  --bazel="$bazel_path"
  --overrideXcodeVersion
  --bazelArguments="${(j: :)bazel_arguments}"
  build
  --buildNumber="$build_number"
  --configurationPath="$configuration_file"
  --codesigningInformationPath="$signing_root"
  --configuration=release_arm64
  --outputBuildArtifactsPath="$artifacts_dir"
)

if [[ -n "$bazel_cache_dir" ]]; then
  make_arguments=(
    --cacheDir="$bazel_cache_dir"
    "${make_arguments[@]}"
  )
fi

python3 build-system/Make/Make.py "${make_arguments[@]}"

report_bazel_storage_size() {
  print "\nBazel storage size:"
  if [[ -d "$bazel_output_user_root" ]]; then
    du -sh "$bazel_output_user_root"
  else
    print "0B\t$bazel_output_user_root"
  fi

  if [[ -d "$bazel_cache_dir" ]]; then
    du -sh "$bazel_cache_dir"
  else
    print "0B\t$bazel_cache_dir"
  fi
}

report_bazel_storage_size

mv "$artifacts_dir/Telegram.ipa" "$download_ipa"
print "\nTestFlight IPA moved to: $download_ipa"

# Fastlane accepts this compact key file and resolves the App Store Connect app
# from APP_IDENTIFIER, so neither a numeric App ID nor a beta-group ID is needed.
python3 - "$api_key_json" "$APP_STORE_CONNECT_KEY_ID" "$APP_STORE_CONNECT_ISSUER_ID" "$APP_STORE_CONNECT_KEY_FILE" <<'PY'
import json
import sys

output, key_id, issuer_id, key_path = sys.argv[1:]
with open(key_path, encoding="utf-8") as source:
    key = source.read()
with open(output, "w", encoding="utf-8") as destination:
    json.dump({"key_id": key_id, "issuer_id": issuer_id, "key": key}, destination)
PY
trap 'rm -f "$api_key_json"' EXIT

print "\nUploading IPA to TestFlight..."
fastlane pilot upload \
  --ipa "$download_ipa" \
  --api_key_path "$api_key_json" \
  --skip_submission true \
  --skip_waiting_for_build_processing true

print "Waiting for build $marketing_version ($build_number) to finish processing..."
for attempt in {1..60}; do
  distribution_log="$(mktemp -t telegram-testflight-distribute)"
  if fastlane pilot distribute \
    --api_key_path "$api_key_json" \
    --app_identifier "$app_identifier" \
    --app_platform ios \
    --app_version "$marketing_version" \
    --build_number "$build_number" \
    --changelog "$what_to_test" \
    --groups "$internal_group" \
    --submit_beta_review false \
    --distribute_external false >"$distribution_log" 2>&1; then
    cat "$distribution_log"
    rm -f "$distribution_log"
    print "Build $marketing_version ($build_number) is available to internal TestFlight group $internal_group."
    report_bazel_storage_size
    exit 0
  fi
  # `grep` is available on a standard macOS installation; don't require ripgrep
  # just to recognize the expected App Store Connect processing responses.
  if ! grep -Eiq 'No build to distribute|Could not find build|processing' "$distribution_log"; then
    cat "$distribution_log" >&2
    rm -f "$distribution_log"
    exit 1
  fi
  rm -f "$distribution_log"
  sleep 10
done

print "Timed out waiting for App Store Connect to process build $marketing_version ($build_number)." >&2
exit 1
