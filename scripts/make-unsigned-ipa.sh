#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

PROJECT_PATH="${PROJECT_PATH:-Yomi.xcodeproj}"
SCHEME="${SCHEME:-Yomi}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-$SCHEME}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_ROOT/build/UnsignedIPADerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/build/ipa}"
IPA_NAME="${IPA_NAME:-${APP_NAME}-unsigned.ipa}"

if [[ "$IPA_NAME" != *.ipa ]]; then
  IPA_NAME="${IPA_NAME}.ipa"
fi

IPA_PATH="$OUTPUT_DIR/$IPA_NAME"

build_settings=(
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
  CODE_SIGN_STYLE=Manual
  PROVISIONING_PROFILE_SPECIFIER=
  DEVELOPMENT_TEAM=
  AD_HOC_CODE_SIGNING_ALLOWED=NO
)

if [[ -n "${BUNDLE_IDENTIFIER:-}" ]]; then
  build_settings+=(PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER")
fi

echo "Building unsigned iOS device app..."
/usr/bin/xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  clean build \
  "${build_settings[@]}"

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphoneos"
APP_PATH="$PRODUCTS_DIR/${APP_NAME}.app"

if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$(/usr/bin/find "$PRODUCTS_DIR" -maxdepth 1 -type d -name "*.app" -print -quit)"
fi

if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
  echo "Could not find a built .app in $PRODUCTS_DIR" >&2
  exit 1
fi

WORK_DIR="$(/usr/bin/mktemp -d "$PROJECT_ROOT/build/unsigned-ipa.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

PAYLOAD_DIR="$WORK_DIR/Payload"
PACKAGED_APP="$PAYLOAD_DIR/$(basename "$APP_PATH")"

/bin/mkdir -p "$PAYLOAD_DIR" "$OUTPUT_DIR"
/usr/bin/ditto "$APP_PATH" "$PACKAGED_APP"

# Keep the package ready for sideloading tools that apply their own signature.
/bin/rm -rf "$PACKAGED_APP/_CodeSignature"
/bin/rm -f "$PACKAGED_APP/embedded.mobileprovision"

/bin/rm -f "$IPA_PATH"
(
  cd "$WORK_DIR"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "$IPA_PATH" Payload
)

/usr/bin/unzip -tq "$IPA_PATH" >/dev/null

echo "Created unsigned IPA:"
echo "$IPA_PATH"
echo
echo "You can now sign this IPA with SideStore, Sideloadly, AltStore, or a similar sideloading tool."
