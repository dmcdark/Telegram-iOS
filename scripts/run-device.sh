#!/bin/zsh
# Build a Development-signed app, install it on a physical iPhone, and launch it.
# This script never uploads to TestFlight.
# Set DEVICE_NOTIFICATION_SERVICE_PROFILE_FILE to the matching Development
# profile if it is not at the default Project-env path. Set
# DISABLE_EXTENSIONS=true only when intentionally building without extensions.
# Other Development profile variables: DEVELOPMENT_PROFILE_FILE and
# DEVICE_SHARE_EXTENSION_PROFILE_FILE.

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
env_file="${DEVICE_ENV_FILE:-/Users/qinsbro/Downloads/Project-env/dmctelegram.env}"

signing_root="$project_root/build/device-signing"
configuration_template="$project_root/build-system/appstore-configuration.json"
configuration_file="$signing_root/appstore-configuration.json"
artifacts_dir="$project_root/build/device"
bazel_path="$project_root/build-input/bazel-8.4.2-darwin-arm64"

if [[ -f "$env_file" ]]; then
  set -a
  source "$env_file"
  set +a
fi

profile_source="${DEVELOPMENT_PROFILE_FILE:-/Users/qinsbro/Downloads/Project-env/dmctelegram-development.mobileprovision}"
notification_service_profile_source="${DEVICE_NOTIFICATION_SERVICE_PROFILE_FILE:-${NOTIFICATION_SERVICE_PROFILE_FILE:-/Users/qinsbro/Downloads/Project-env/dmctelegram-notification-service-development.mobileprovision}}"
share_profile_source="${DEVICE_SHARE_EXTENSION_PROFILE_FILE:-${SHARE_EXTENSION_PROFILE_FILE:-}}"
disable_extensions="${DISABLE_EXTENSIONS:-false}"
device_udid="${1:-${IOS_DEVICE_UDID:-00008130-000644E20C43001C}}"
app_identifier="${APP_IDENTIFIER:-com.qinsbro.telegram}"
build_number="${BUILD_NUMBER:-$(date +%s)}"
bazel_cache_dir="${TELEGRAM_BAZEL_CACHE_DIR:-$HOME/telegram-bazel-cache}"

for variable_name in TELEGRAM_API_ID TELEGRAM_API_HASH; do
  if [[ -z "${(P)variable_name:-}" ]]; then
    print "Missing $variable_name. Add it to $env_file."
    exit 2
  fi
done

if [[ ! -f "$profile_source" ]]; then
  print "Missing Development provisioning profile: $profile_source"
  exit 1
fi
profile_get_task_allow="$(security cms -D -i "$profile_source" | plutil -extract Entitlements.get-task-allow raw -o - -)"
profile_app_identifier="$(security cms -D -i "$profile_source" | plutil -extract Entitlements.application-identifier raw -o - -)"
if [[ "$profile_get_task_allow" != "true" || "$profile_app_identifier" != *".$app_identifier" ]]; then
  print "The selected profile is not a Development profile for $app_identifier: $profile_source"
  exit 1
fi
if [[ "$disable_extensions" != "true" ]]; then
  if [[ ! -f "$notification_service_profile_source" ]]; then
    print "Missing NotificationService Development provisioning profile: $notification_service_profile_source"
    print "Set DEVICE_NOTIFICATION_SERVICE_PROFILE_FILE or set DISABLE_EXTENSIONS=true to build without extensions."
    exit 1
  fi
  notification_service_get_task_allow="$(security cms -D -i "$notification_service_profile_source" | plutil -extract Entitlements.get-task-allow raw -o - -)"
  notification_service_app_identifier="$(security cms -D -i "$notification_service_profile_source" | plutil -extract Entitlements.application-identifier raw -o - -)"
  if [[ "$notification_service_get_task_allow" != "true" || "$notification_service_app_identifier" != *".$app_identifier.NotificationService" ]]; then
    print "The selected profile is not a Development profile for $app_identifier.NotificationService: $notification_service_profile_source"
    exit 1
  fi
fi
if [[ -n "$share_profile_source" && "$disable_extensions" != "true" ]]; then
  if [[ ! -f "$share_profile_source" ]]; then
    print "Missing Share Development provisioning profile: $share_profile_source"
    exit 1
  fi
  share_get_task_allow="$(security cms -D -i "$share_profile_source" | plutil -extract Entitlements.get-task-allow raw -o - -)"
  share_app_identifier="$(security cms -D -i "$share_profile_source" | plutil -extract Entitlements.application-identifier raw -o - -)"
  if [[ "$share_get_task_allow" != "true" || "$share_app_identifier" != *".$app_identifier.Share" ]]; then
    print "The selected profile is not a Development profile for $app_identifier.Share: $share_profile_source"
    exit 1
  fi
fi
if [[ ! -x "$bazel_path" ]]; then
  print "Missing executable Bazel binary: $bazel_path"
  exit 1
fi
if ! xcrun devicectl list devices | grep -Fq "$device_udid"; then
  print "The requested iPhone is not connected or paired: $device_udid"
  exit 1
fi

cd "$project_root"
mkdir -p "$signing_root/profiles" "$artifacts_dir"
rm -f "$signing_root/profiles"/*.mobileprovision(N)
cp "$profile_source" "$signing_root/profiles/dmctelegram-development.mobileprovision"
if [[ "$disable_extensions" != "true" ]]; then
  cp "$notification_service_profile_source" "$signing_root/profiles/dmctelegram-notification-service-development.mobileprovision"
fi
if [[ -n "$share_profile_source" && "$disable_extensions" != "true" ]]; then
  cp "$share_profile_source" "$signing_root/profiles/dmctelegram-share-development.mobileprovision"
fi

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
elif [[ -n "$share_profile_source" ]]; then
  bazel_arguments+=("--//Telegram:notificationServiceExtensionOnly=True")
  bazel_arguments+=("--//Telegram:shareExtensionOnly=True")
else
  bazel_arguments+=("--//Telegram:notificationServiceExtensionOnly=True")
fi
bazel_arguments+=(
  "--copt=-Wno-deprecated-declarations"
  "--@build_bazel_rules_swift//swift:copt=-no-warnings-as-errors"
)

python3 build-system/Make/Make.py \
  --bazel="$bazel_path" \
  --overrideXcodeVersion \
  --cacheDir="$bazel_cache_dir" \
  --bazelArguments="${(j: :)bazel_arguments}" \
  build \
  --buildNumber="$build_number" \
  --configurationPath="$configuration_file" \
  --codesigningInformationPath="$signing_root" \
  --configuration=debug_arm64 \
  --outputBuildArtifactsPath="$artifacts_dir"

temporary_directory="$(mktemp -d -t telegram-device)"
trap 'rm -rf "$temporary_directory"' EXIT
ditto -x -k "$artifacts_dir/Telegram.ipa" "$temporary_directory"
app_path="$temporary_directory/Payload/Telegram.app"

codesign --verify --deep --strict "$app_path"
xcrun devicectl device install app --device "$device_udid" "$app_path"
xcrun devicectl device process launch --device "$device_udid" "$app_identifier"

# The app is installed on the phone; keep the IPA only if install/launch failed.
rm -f "$artifacts_dir/Telegram.ipa"

print "Development build $build_number is running on $device_udid."
if [[ "$disable_extensions" != "true" ]]; then
  if [[ -n "$share_profile_source" ]]; then
    print "NotificationService and Share extensions are included; other extensions are disabled."
  else
    print "NotificationService extension is included; other extensions are disabled."
  fi
else
  print "All extensions are disabled by DISABLE_EXTENSIONS=true."
fi
print "No TestFlight upload was performed."
