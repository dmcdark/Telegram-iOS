#!/bin/zsh
# Build and run on a physical iPhone, or build, upload, and distribute a
# signed IPA through TestFlight.
#
# Usage:
#   ./scripts/build-testflight.sh 13
#
# The interactive menu offers:
#   1. Build, install, and launch the Development app on the configured iPhone.
#   2. Build and upload an App Store-signed IPA to TestFlight.
#
# The build number is the required first argument. For non-interactive use, set
# TELEGRAM_ACTION=device/testflight. WHAT_TO_TEST continues to come from
# dmctelegram.env.
#
# Credentials are read from /Users/qinsbro/Downloads/Project-env/dmctelegram.env (or TESTFLIGHT_ENV_FILE):
#   APP_STORE_CONNECT_KEY_ID=...
#   APP_STORE_CONNECT_ISSUER_ID=...
#   APP_STORE_CONNECT_KEY_FILE=/absolute/path/AuthKey_XXXX.p8
#   TELEGRAM_API_ID=12345678
#   TELEGRAM_API_HASH=your_api_hash_from_my.telegram.org
#   APP_IDENTIFIER=com.qinsbro.telegram
#   APP_STORE_PROFILE_FILE=/absolute/path/to/main-app-app-store.mobileprovision
#   TESTFLIGHT_NOTIFICATION_SERVICE_PROFILE_FILE=/absolute/path/to/notification-service-app-store.mobileprovision
#   TESTFLIGHT_SHARE_PROFILE_FILE=/absolute/path/to/share-app-store.mobileprovision
# Device action (Development profiles; separate from the TestFlight profiles):
#   DEVELOPMENT_PROFILE_FILE=/absolute/path/to/main-app-development.mobileprovision
#   DEVICE_NOTIFICATION_SERVICE_PROFILE_FILE=/absolute/path/to/notification-service-development.mobileprovision
#   DEVICE_SHARE_EXTENSION_PROFILE_FILE=/absolute/path/to/share-development.mobileprovision
#   WHAT_TO_TEST=Fixed release notes for internal testers
#   TESTFLIGHT_INTERNAL_GROUP=internal
#   WAIT_SECONDS=15
#
# The marketing version is read from versions.json. The build number is entered
# on the command line before choosing the device or TestFlight action.
#
# Signing uses the Xcode-managed distribution certificate in the login
# keychain. Before the first run:
#   1. Sign in to Xcode > Settings > Accounts with this Apple Developer account.
#   2. In Manage Certificates, create or download a distribution certificate
#      (Apple Distribution or the legacy iOS/iPhone Distribution type). Its
#      private key must appear in the login keychain.
#   3. Enable Push Notifications and App Groups for com.qinsbro.telegram.
#   4. Put the App Store Connect profiles in /Users/qinsbro/Downloads/Project-env:
#      dmctelegram.mobileprovision, dmctelegramnotificationservice.mobileprovision,
#      and dmctelegramshare.mobileprovision

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
script_dir="$(cd "$(dirname "$0")" && pwd)"
env_file="${TESTFLIGHT_ENV_FILE:-/Users/qinsbro/Downloads/Project-env/dmctelegram.env}"
if (( $# != 1 )); then
  print "Usage: $0 <build-number>"
  exit 2
fi
build_number="$1"
if [[ ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
  print "Build number must be a positive integer."
  exit 2
fi
if [[ -f "$env_file" ]]; then
  set -a
  source "$env_file"
  set +a
fi

selected_action="${TELEGRAM_ACTION:-}"
if [[ -z "$selected_action" ]]; then
  print "请选择操作："
  print "  1）Build to iPhone 15 Pro Max"
  print "  2）Release to TestFlight"
  print -n "请选择 1 或 2: "
  if [[ -t 0 ]]; then
    if ! read -r -k 1 selected_action; then
      print "\n没有读取到选项。"
      exit 2
    fi
    print
  elif ! IFS= read -r selected_action; then
    print "没有读取到选项。"
    exit 2
  fi
fi

case "$selected_action" in
  1|device)
    export DEVICE_ENV_FILE="$env_file"
    export BUILD_NUMBER="$build_number"
    exec "$script_dir/run-device.sh"
    ;;
  2|testflight)
    ;;
  *)
    print "无效选项：$selected_action（请选择 1 或 2）。"
    exit 2
    ;;
esac

project_env_dir="/Users/qinsbro/Downloads/Project-env"
profile_source="${APP_STORE_PROFILE_FILE:-$project_env_dir/dmctelegram.mobileprovision}"
notification_service_profile_source="${TESTFLIGHT_NOTIFICATION_SERVICE_PROFILE_FILE:-$project_env_dir/dmctelegramnotificationservice.mobileprovision}"
share_profile_source="${TESTFLIGHT_SHARE_PROFILE_FILE:-$project_env_dir/dmctelegramshare.mobileprovision}"
disable_extensions="${TESTFLIGHT_DISABLE_EXTENSIONS:-false}"
signing_root="$project_root/build/testflight-signing"
configuration_template="$project_root/build-system/appstore-configuration.json"
configuration_file="$signing_root/appstore-configuration.json"
artifacts_dir="$project_root/build/testflight"

download_ipa="$HOME/Downloads/Telegram-TestFlight-${build_number}.ipa"
api_key_json="$artifacts_dir/AppStoreConnectKey.json"
app_identifier="${APP_IDENTIFIER:-com.qinsbro.telegram}"
what_to_test="${WHAT_TO_TEST:-Local TestFlight build $build_number}"
internal_group="${TESTFLIGHT_INTERNAL_GROUP:-internal}"
wait_seconds="${WAIT_SECONDS:-15}"
auth_retry_count="${TESTFLIGHT_AUTH_RETRIES:-3}"
marketing_version="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["app"])' "$project_root/versions.json" 2>/dev/null || true)"
bazel_path="$project_root/build-input/bazel-8.4.2-darwin-arm64"

# Keep the persistent Bazel disk cache so release rebuilds can reuse artifacts.
# The script reports its size after each build; clean it manually when needed.
bazel_cache_dir="${TELEGRAM_BAZEL_CACHE_DIR:-$HOME/telegram-bazel-cache}"
bazel_output_user_root="${TELEGRAM_BAZEL_OUTPUT_USER_ROOT:-/private/var/tmp/_bazel_qinsbro}"

for variable_name in APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_KEY_FILE TELEGRAM_API_ID TELEGRAM_API_HASH; do
  if [[ -z "${(P)variable_name:-}" ]]; then
    print "Missing $variable_name. Add it to $env_file."
    exit 2
  fi
done
if [[ ! "$TELEGRAM_API_ID" =~ '^[1-9][0-9]*$' ]]; then
  print "TELEGRAM_API_ID must be a positive integer."
  exit 2
fi
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
if [[ ! "$wait_seconds" =~ '^[1-9][0-9]*$' ]]; then
  print "WAIT_SECONDS must be a positive integer."
  exit 2
fi
if [[ ! "$auth_retry_count" =~ '^[1-9][0-9]*$' ]]; then
  print "TESTFLIGHT_AUTH_RETRIES must be a positive integer."
  exit 2
fi

if [[ ! -f "$configuration_template" ]]; then
  print "Missing build configuration template: $configuration_template"
  exit 1
fi

if [[ ! -f "$profile_source" ]]; then
  print "Missing App Store Connect provisioning profile: $profile_source"
  exit 1
fi
if [[ "$disable_extensions" != "true" ]]; then
  if [[ ! -f "$notification_service_profile_source" ]]; then
    print "Missing App Store Connect Notification Service provisioning profile: $notification_service_profile_source"
    print "Set TESTFLIGHT_NOTIFICATION_SERVICE_PROFILE_FILE or set TESTFLIGHT_DISABLE_EXTENSIONS=true to build without extensions."
    exit 1
  fi
  if [[ ! -f "$share_profile_source" ]]; then
    print "Missing App Store Connect Share provisioning profile: $share_profile_source"
    exit 1
  fi
fi
if strings "$profile_source" | grep -q '<key>ProvisionedDevices</key>'; then
  print "The main provisioning profile is a development/ad hoc profile, not an App Store profile: $profile_source"
  print "Replace it with an App Store Connect distribution profile for $app_identifier."
  exit 1
fi
if ! strings "$profile_source" | grep -q '<string>production</string>'; then
  print "The main provisioning profile does not appear to use production entitlements: $profile_source"
  print "Replace it with an App Store Connect distribution profile for $app_identifier."
  exit 1
fi
if [[ "$disable_extensions" != "true" ]]; then
  for extension_profile in "$notification_service_profile_source" "$share_profile_source"; do
    if strings "$extension_profile" | grep -q '<key>ProvisionedDevices</key>'; then
      print "An extension provisioning profile is development/ad hoc, not an App Store profile: $extension_profile"
      exit 1
    fi
    extension_get_task_allow="$(security cms -D -i "$extension_profile" | plutil -extract Entitlements.get-task-allow raw -o - -)"
    extension_provisions_all_devices="$(security cms -D -i "$extension_profile" | plutil -extract ProvisionsAllDevices raw -o - - 2>/dev/null || true)"
    if [[ "$extension_get_task_allow" != "false" || "$extension_provisions_all_devices" == "true" ]]; then
      print "An extension provisioning profile is not an App Store Connect distribution profile: $extension_profile"
      exit 1
    fi
  done
  notification_service_app_identifier="$(security cms -D -i "$notification_service_profile_source" | plutil -extract Entitlements.application-identifier raw -o - -)"
  share_app_identifier="$(security cms -D -i "$share_profile_source" | plutil -extract Entitlements.application-identifier raw -o - -)"
  if [[ "$notification_service_app_identifier" != *".$app_identifier.NotificationService" ]]; then
    print "The Notification Service profile does not match $app_identifier.NotificationService: $notification_service_profile_source"
    exit 1
  fi
  if [[ "$share_app_identifier" != *".$app_identifier.Share" ]]; then
    print "The Share profile does not match $app_identifier.Share: $share_profile_source"
    exit 1
  fi
fi
if python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("enable_icloud") else 1)' "$configuration_template" && ! strings "$profile_source" | grep -q 'com.apple.developer.icloud-services'; then
  print "The build configuration template enables iCloud, but the provisioning profile does not include iCloud entitlements."
  print "Either disable enable_icloud in $configuration_file or regenerate $profile_source with iCloud enabled."
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

# Make copies only in an ignored build directory. Make.py scans every
# .mobileprovision under profiles/, so keep this directory limited to the two
# profiles used by this TestFlight build.
mkdir -p "$signing_root/profiles"
rm -f "$signing_root/profiles"/*.mobileprovision(N)
cp "$profile_source" "$signing_root/profiles/dmctelegram.mobileprovision"
if [[ "$disable_extensions" != "true" ]]; then
  cp "$notification_service_profile_source" "$signing_root/profiles/dmctelegramnotificationservice.mobileprovision"
  cp "$share_profile_source" "$signing_root/profiles/dmctelegramshare.mobileprovision"
fi

# Keep the Telegram application credentials out of the repository. The build
# configuration passed to Make.py exists only under the ignored build/ folder.
python3 - "$configuration_template" "$configuration_file" "$TELEGRAM_API_ID" "$TELEGRAM_API_HASH" <<'PY'
import json
import sys

template_path, output_path, api_id, api_hash = sys.argv[1:]
with open(template_path, encoding="utf-8") as source:
    configuration = json.load(source)
configuration["api_id"] = api_id
configuration["api_hash"] = api_hash
with open(output_path, "w", encoding="utf-8") as destination:
    json.dump(configuration, destination, indent=2)
    destination.write("\n")
PY

bazel_arguments=()
if [[ "$disable_extensions" == "true" ]]; then
  bazel_arguments+=("--//Telegram:disableExtensions=True")
else
  bazel_arguments+=("--//Telegram:notificationServiceExtensionOnly=True")
  bazel_arguments+=("--//Telegram:shareExtensionOnly=True")
fi
bazel_arguments+=(
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
fastlane_auth_retries=0
while true; do
  fastlane_log="$(mktemp -t telegram-testflight-upload)"
  if fastlane pilot upload \
    --ipa "$download_ipa" \
    --api_key_path "$api_key_json" \
    --skip_submission true \
    --skip_waiting_for_build_processing true >"$fastlane_log" 2>&1; then
    cat "$fastlane_log"
    rm -f "$fastlane_log"
    break
  else
    fastlane_status=$?
  fi

  if grep -Fq 'Creating authorization token' "$fastlane_log" \
    && grep -Fq 'SSL_read: unexpected eof while reading' "$fastlane_log" \
    && (( fastlane_auth_retries < auth_retry_count )); then
    (( fastlane_auth_retries += 1 ))
    print "Fastlane lost its SSL connection while creating the App Store Connect token; retrying in $((fastlane_auth_retries * 5))s ($fastlane_auth_retries/$auth_retry_count)..." >&2
    rm -f "$fastlane_log"
    sleep $((fastlane_auth_retries * 5))
    continue
  fi

  cat "$fastlane_log" >&2
  rm -f "$fastlane_log"
  exit "$fastlane_status"
done
rm -f "$download_ipa"
print "Uploaded IPA removed from: $download_ipa"

print "Waiting for build $marketing_version ($build_number) to finish processing..."
fastlane_auth_retries=0
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
    if grep -Fq 'Creating authorization token' "$distribution_log" \
      && grep -Fq 'SSL_read: unexpected eof while reading' "$distribution_log" \
      && (( fastlane_auth_retries < auth_retry_count )); then
      (( fastlane_auth_retries += 1 ))
      print "Fastlane lost its SSL connection while creating the App Store Connect token; retrying in $((fastlane_auth_retries * 5))s ($fastlane_auth_retries/$auth_retry_count)..." >&2
      rm -f "$distribution_log"
      sleep $((fastlane_auth_retries * 5))
      continue
    fi
    cat "$distribution_log" >&2
    rm -f "$distribution_log"
    exit 1
  fi
  rm -f "$distribution_log"
  print "Build is still processing; checking again in ${wait_seconds}s..."
  sleep "$wait_seconds"
done

print "Timed out waiting for App Store Connect to process build $marketing_version ($build_number)." >&2
exit 1
