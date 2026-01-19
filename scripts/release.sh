#!/usr/bin/env bash
## create notary like this xcrun notarytool store-credentials mcp-bundler-notary --team-id VXRLZNZH2E --apple-id test@test.com --password password
# Creates a signed Sparkle release and updates the appcast feed.
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_PATH="$ROOT_DIR/MCPBundler.xcodeproj"
readonly DEFAULT_SCHEME="${SCHEME:-MCPBundler}"
readonly DEFAULT_CONFIGURATION="${CONFIGURATION:-Release}"
readonly DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
readonly DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
readonly DEFAULT_APPCAST_PATH="${APPCAST_PATH:-$DIST_DIR/appcast.xml}"
readonly PRIVATE_KEY_PATH="${SPARKLE_PRIVATE_KEY:-$ROOT_DIR/scripts/sparkle_ed25519_private_key.pem}"
readonly SIGN_TOOL_OVERRIDE="${SIGN_UPDATE_TOOL:-}"
readonly DEFAULT_DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://mcp-bundler.com/downloads}"
readonly RELEASE_NOTES_BASE_URL="${RELEASE_NOTES_BASE_URL:-https://mcp-bundler.com/downloads/release-notes/}"
readonly RELEASE_NOTES_DIR="${RELEASE_NOTES_DIR:-$DIST_DIR/release-notes}"
readonly CHANGELOG_FILE_CANDIDATE="${CHANGELOG_PATH:-$ROOT_DIR/CHANGELOG.md}"
readonly DEFAULT_DEVELOPER_IDENTITY="Developer ID Application: Ievgen Pyvovarov (VXRLZNZH2E)"
readonly DEVELOPER_IDENTITY="${DEVELOPER_ID_IDENTITY:-${CODE_SIGN_IDENTITY:-$DEFAULT_DEVELOPER_IDENTITY}}"
readonly CODESIGN_ENTITLEMENTS_PATH="${CODESIGN_ENTITLEMENTS:-}"
readonly CODESIGN_ADDITIONAL_FLAGS="${CODESIGN_ADDITIONAL_FLAGS:-}"
readonly NOTARIZE_MODE="${NOTARIZE_APP:-auto}"
readonly NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-${NOTARY_PROFILE:-mcp-bundler-notary}}"
readonly NOTARY_PRIMARY_BUNDLE_ID="${NOTARY_PRIMARY_BUNDLE_ID:-${PRIMARY_BUNDLE_ID:-}}"

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [--download-base <url>] [--notes-url <url>] [--appcast-path <file>]

Environment overrides:
  SCHEME                     Xcode scheme to build (default: MCPBundler)
  CONFIGURATION              Build configuration (default: Release)
  DERIVED_DATA_PATH          DerivedData output directory (default: build/DerivedData)
  DIST_DIR                   Directory for release artifacts (default: ./dist)
  SPARKLE_PRIVATE_KEY        Path to Sparkle EdDSA private key (default: ./scripts/sparkle_ed25519_private_key.pem)
  SIGN_UPDATE_TOOL           Path to Sparkle sign_update tool (auto-detected by default)
  SPARKLE_CHANNEL_TITLE      Channel <title> for the appcast (default: MCP Bundler Updates)
  SPARKLE_CHANNEL_DESCRIPTION Channel <description> for the appcast
  SPARKLE_CHANNEL_LINK       Channel <link> (default: https://mcp-bundler.com/downloads/appcast.xml)
  CHANGELOG_PATH             Override changelog path (default: ./CHANGELOG.md with fallbacks to ./changelog.md or ./changelog.txt)
  RELEASE_NOTES_BASE_URL     Base URL prefix for generated release notes (default: https://mcp-bundler.com/downloads/release-notes/)
  RELEASE_NOTES_DIR          Directory for generated release notes (default: dist/release-notes)
  DEVELOPER_ID_IDENTITY      Developer ID identity used to re-sign the app bundle (default: Developer ID Application: Ievgen Pyvovarov (VXRLZNZH2E))
  CODESIGN_ENTITLEMENTS      Entitlements file passed to codesign when re-signing (optional)
  CODESIGN_ADDITIONAL_FLAGS  Extra flags appended to the codesign command (optional)
  NOTARIZE_APP               yes/no/auto (default auto). When auto, notarizes if NOTARYTOOL_PROFILE is set.
  NOTARYTOOL_PROFILE         Keychain profile name for notarytool authentication (default: mcp-bundler-notary)
  NOTARY_PRIMARY_BUNDLE_ID   Primary bundle identifier passed to notarytool (optional)
  RELEASE_VERSION            Marketing version to use (skip interactive prompt)
  RELEASE_BUILD              Build number to use (skip interactive prompt)
  PERSIST_VERSION_INFO       Set to yes/no to control whether the script updates Xcode project settings.

Optional flags:
  --download-base URL        Override the download host for the archive (default: https://mcp-bundler.com/downloads).
  --notes-url URL            URL containing release notes to publish with the Sparkle item.
  --appcast-path PATH        Override output path for the generated appcast (default: dist/appcast.xml).
  -h, --help                 Show this help message.
EOF
}

DOWNLOAD_BASE="$DEFAULT_DOWNLOAD_BASE"
NOTES_URL=""
APPCAST_PATH="$DEFAULT_APPCAST_PATH"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --download-base)
      DOWNLOAD_BASE="${2:-}"
      shift 2
      ;;
    --notes-url)
      NOTES_URL="${2:-}"
      shift 2
      ;;
    --appcast-path)
      APPCAST_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

resolve_changelog_path() {
  local candidate="$1"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  local fallback
  for fallback in \
    "$ROOT_DIR/CHANGELOG.md" \
    "$ROOT_DIR/changelog.md" \
    "$ROOT_DIR/changelog.txt"
  do
    if [[ -f "$fallback" ]]; then
      printf '%s\n' "$fallback"
      return 0
    fi
  done
  echo "Error: Could not find a changelog file. Set CHANGELOG_PATH or create CHANGELOG.md." >&2
  return 1
}

generate_release_notes() {
  local version="$1"
  local build="$2"
  local changelog_path="$3"
  local output_dir="$4"

  mkdir -p "$output_dir"

  local sanitized_version="${version//[^A-Za-z0-9._-]/-}"
  local sanitized_build="${build//[^A-Za-z0-9._-]/-}"
  local base_filename="mcp-bundler-${sanitized_version}-${sanitized_build}"
  local md_path="$output_dir/${base_filename}.md"
  local html_path="$output_dir/${base_filename}.html"

  python3 - "$changelog_path" "$version" "$build" "$md_path" "$html_path" <<'PY'
import sys
import re
import html
from pathlib import Path
from datetime import date

changelog_path = Path(sys.argv[1])
version = sys.argv[2]
build_number = sys.argv[3]
md_path = Path(sys.argv[4])
html_path = Path(sys.argv[5])

raw = changelog_path.read_text(encoding='utf-8')
lines = [line.rstrip() for line in raw.splitlines()]

date_pattern = re.compile(r'^\s*(?:#+\s*)?(\d{4}-\d{2}-\d{2})\s*$')

sections = []
current_date = None
current_items = []

for line in lines:
    stripped = line.strip()
    if not stripped:
        continue
    match = date_pattern.match(stripped)
    if match:
        matched_date = match.group(1)
        if current_date is not None and current_items:
            sections.append((current_date, current_items))
        current_date = matched_date
        current_items = []
        continue
    if current_date is None:
        continue
    if stripped.startswith(('-', '*')):
        content = stripped[1:].strip()
    else:
        content = stripped
    if content:
        current_items.append(content)

if current_date is not None and current_items:
    sections.append((current_date, current_items))

if not sections:
    raise SystemExit(f"No changelog entries found in {changelog_path}")

md_path.parent.mkdir(parents=True, exist_ok=True)
html_path.parent.mkdir(parents=True, exist_ok=True)

today_iso = date.today().isoformat()
title = f"MCP Bundler {version} (Build {build_number}) — {today_iso}"

md_lines = [f"# {title}", ""]
for section_date, items in sections:
    md_lines.append(f"## {section_date}")
    md_lines.extend(f"- {item}" for item in items)
    md_lines.append("")
md_path.write_text("\n".join(md_lines), encoding="utf-8")

html_lines = [
    "<!DOCTYPE html>",
    "<html lang=\"en\">",
    "<head>",
    "  <meta charset=\"utf-8\" />",
    f"  <title>{html.escape(title)}</title>",
    "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />",
    "  <style>",
    "    :root { color-scheme: light dark; }",
    "    body { font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif; margin: 2rem; color: #111; background-color: #fff; }",
    "    h1 { font-size: 1.5rem; margin-bottom: 1rem; font-weight: 600; }",
    "    ul { line-height: 1.5; padding-left: 1.5rem; }",
    "    li + li { margin-top: 0.5rem; }",
    "    footer { margin-top: 2rem; font-size: 0.85rem; color: #555; }",
    "    section { margin-bottom: 2rem; }",
    "    h2 { font-size: 1.1rem; margin: 1.5rem 0 0.75rem; }",
    "    a { color: #0b5ed7; }",
    "    @media (prefers-color-scheme: dark) {",
    "      body { color: #f5f5f7; background-color: #1c1c1e; }",
    "      footer { color: #9e9e9e; }",
    "      a { color: #8ab4ff; }",
    "    }",
    "  </style>",
    "</head>",
    "<body>",
    f"  <h1>{html.escape(title)}</h1>",
]

for section_date, items in sections:
    html_lines.append(f"  <section>")
    html_lines.append(f"    <h2>{html.escape(section_date)}</h2>")
    html_lines.append("    <ul>")
    for item in items:
        html_lines.append(f"      <li>{html.escape(item)}</li>")
    html_lines.append("    </ul>")
    html_lines.append("  </section>")

html_lines.extend([
    f"  <footer>Build {html.escape(build_number)}</footer>",
    "</body>",
    "</html>",
])

html_path.write_text("\n".join(html_lines), encoding="utf-8")
PY

  printf '%s\n' "$base_filename"
}

sign_app_bundle() {
  local app_path="$1"
  local identity="$2"
  local entitlements="$3"
  local extra_flags="$4"

  local codesign_args=(--force --deep --timestamp --options runtime)
  if [[ -n "$entitlements" ]]; then
    codesign_args+=(--entitlements "$entitlements")
  fi
  if [[ -n "$extra_flags" ]]; then
    # shellcheck disable=SC2206
    local parsed_extra_flags=($extra_flags)
    codesign_args+=("${parsed_extra_flags[@]}")
  fi

  codesign "${codesign_args[@]}" --sign "$identity" "$app_path"
}

create_archive() {
  local source="$1"
  local destination="$2"

  echo "📦 Creating distributable archive: $destination"
  rm -f "$destination"
  ditto -ck --rsrc --sequesterRsrc --keepParent "$source" "$destination"
}

if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
  echo "Error: Sparkle private key not found at $PRIVATE_KEY_PATH" >&2
  echo "Set SPARKLE_PRIVATE_KEY to the correct path and retry." >&2
  exit 1
fi

if [[ -n "$CODESIGN_ENTITLEMENTS_PATH" && ! -f "$CODESIGN_ENTITLEMENTS_PATH" ]]; then
  echo "Error: Entitlements file not found at $CODESIGN_ENTITLEMENTS_PATH" >&2
  exit 1
fi

command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild not found in PATH." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 1; }

mkdir -p "$DIST_DIR"

SCHEME="$DEFAULT_SCHEME"
CONFIGURATION="$DEFAULT_CONFIGURATION"

echo "📋 Inspecting current version information…"
BUILD_SETTINGS=$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null)
CURRENT_VERSION=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/MARKETING_VERSION = / {print $2; exit}')
CURRENT_BUILD=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/CURRENT_PROJECT_VERSION = / {print $2; exit}')

[[ -z "$CURRENT_VERSION" ]] && CURRENT_VERSION="1.0"
[[ -z "$CURRENT_BUILD" ]] && CURRENT_BUILD="1"

if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  DEFAULT_BUILD=$((CURRENT_BUILD + 1))
else
  DEFAULT_BUILD="$CURRENT_BUILD"
fi

if [[ -n "${RELEASE_VERSION:-}" ]]; then
  TARGET_VERSION="$RELEASE_VERSION"
  echo "• Using marketing version from RELEASE_VERSION: $TARGET_VERSION"
else
  read -r -p "Current marketing version is $CURRENT_VERSION. Enter new version (or press Enter to keep): " INPUT_VERSION
  TARGET_VERSION=${INPUT_VERSION:-$CURRENT_VERSION}
fi

if [[ -n "${RELEASE_BUILD:-}" ]]; then
  TARGET_BUILD="$RELEASE_BUILD"
  echo "• Using build number from RELEASE_BUILD: $TARGET_BUILD"
else
  if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    read -r -p "Current build is $CURRENT_BUILD. Enter new build number (default ${DEFAULT_BUILD}): " INPUT_BUILD
    TARGET_BUILD=${INPUT_BUILD:-$DEFAULT_BUILD}
  else
    read -r -p "Current build is $CURRENT_BUILD. Enter new build number (or press Enter to keep): " INPUT_BUILD
    TARGET_BUILD=${INPUT_BUILD:-$CURRENT_BUILD}
  fi
fi

echo "• Building version $TARGET_VERSION (build $TARGET_BUILD)"

persist_choice_input="${PERSIST_VERSION_INFO:-}"
if [[ -z "$persist_choice_input" ]]; then
  read -r -p "Persist these version values to the Xcode project for next time? [Y/n]: " persist_choice_input
  persist_choice_input=${persist_choice_input:-y}
fi

persist_choice=$(tr '[:upper:]' '[:lower:]' <<<"${persist_choice_input:-}")
if [[ "$persist_choice" == "y" || "$persist_choice" == "yes" ]]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "⚠️  xcrun not found; cannot persist version info. Continuing without updating project." >&2
  elif [[ ! "$TARGET_BUILD" =~ ^[0-9]+$ ]]; then
    echo "⚠️  Build number \"$TARGET_BUILD\" is not numeric; skipping project update." >&2
  else
    echo "🛠️  Updating Xcode project version settings (MARKETING_VERSION=$TARGET_VERSION, CURRENT_PROJECT_VERSION=$TARGET_BUILD)…"
    pushd "$ROOT_DIR" > /dev/null
    if ! AGV_OUTPUT=$(xcrun agvtool new-marketing-version "$TARGET_VERSION" 2>&1); then
      echo "$AGV_OUTPUT" >&2
      echo "⚠️  Failed to set marketing version; continuing with build overrides only." >&2
    else
      printf '%s\n' "$AGV_OUTPUT" | grep -v 'Cannot find "MCPBundler.xcodeproj/../' || true
    fi
    if ! AGV_OUTPUT=$(xcrun agvtool new-version -all "$TARGET_BUILD" 2>&1); then
      echo "$AGV_OUTPUT" >&2
      echo "⚠️  Failed to set build number; continuing with build overrides only." >&2
    else
      printf '%s\n' "$AGV_OUTPUT" | grep -v 'Cannot find "MCPBundler.xcodeproj/../' || true
    fi
    popd > /dev/null
  fi
fi

CHANGELOG_PATH_RESOLVED=$(resolve_changelog_path "$CHANGELOG_FILE_CANDIDATE")
echo "📝 Using changelog source: $CHANGELOG_PATH_RESOLVED"
NOTES_BASE_FILENAME=$(generate_release_notes "$TARGET_VERSION" "$TARGET_BUILD" "$CHANGELOG_PATH_RESOLVED" "$RELEASE_NOTES_DIR")
NOTES_MD_PATH="$RELEASE_NOTES_DIR/${NOTES_BASE_FILENAME}.md"
NOTES_HTML_PATH="$RELEASE_NOTES_DIR/${NOTES_BASE_FILENAME}.html"
echo "🗒️  Generated release notes:"
echo "    • Markdown: $NOTES_MD_PATH"
echo "    • HTML    : $NOTES_HTML_PATH"

if [[ -z "$NOTES_URL" ]]; then
  NOTES_URL="${RELEASE_NOTES_BASE_URL%/}/${NOTES_BASE_FILENAME}.html"
  echo "• Release notes URL set to $NOTES_URL"
else
  echo "• Using provided release notes URL: $NOTES_URL"
fi

echo "🔨 Building $SCHEME ($CONFIGURATION)…"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  MARKETING_VERSION="$TARGET_VERSION" \
  CURRENT_PROJECT_VERSION="$TARGET_BUILD" \
  ARCHS="arm64 x86_64" \
  clean build > "$DIST_DIR/release-build.log"

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION"
APP_NAME="MCPBundler.app"
APP_PATH="$PRODUCTS_DIR/$APP_NAME"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: Built app not found at $APP_PATH" >&2
  exit 1
fi

# Ensure the packaged Info.plist reflects the selected identifiers even if the
# project settings were not persisted.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $TARGET_VERSION" "$APP_PATH/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TARGET_BUILD" "$APP_PATH/Contents/Info.plist" >/dev/null

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

if [[ -n "$DEVELOPER_IDENTITY" ]]; then
  echo "🔐 Signing app bundle with ${DEVELOPER_IDENTITY}…"
  if ! sign_app_bundle "$APP_PATH" "$DEVELOPER_IDENTITY" "$CODESIGN_ENTITLEMENTS_PATH" "$CODESIGN_ADDITIONAL_FLAGS"; then
    echo "Error: codesign failed for $APP_PATH" >&2
    exit 1
  fi
else
  echo "⚠️  DEVELOPER_ID_IDENTITY not set; relying on Xcode project signing configuration." >&2
fi

echo "🔍 Validating code signature…"
if ! codesign --verify --deep --strict --verbose=2 "$APP_PATH"; then
  echo "Error: Code signature verification failed for $APP_PATH" >&2
  exit 1
fi

ZIP_NAME="MCPBundler-${VERSION}-${BUILD_NUMBER}.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

create_archive "$APP_PATH" "$ZIP_PATH"

should_notarize="false"
case "$(tr '[:upper:]' '[:lower:]' <<<"$NOTARIZE_MODE")" in
  yes|true|1)
    should_notarize="true"
    ;;
  auto|"")
    if [[ -n "$NOTARY_PROFILE" ]]; then
      should_notarize="true"
    fi
    ;;
  no|false|0)
    should_notarize="false"
    ;;
  *)
    echo "⚠️  Unknown NOTARIZE_APP value \"$NOTARIZE_MODE\"; defaulting to auto." >&2
    if [[ -n "$NOTARY_PROFILE" ]]; then
      should_notarize="true"
    fi
    ;;
esac

if [[ "$should_notarize" == "true" ]]; then
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "Error: NOTARYTOOL_PROFILE must be set when NOTARIZE_APP=$NOTARIZE_MODE." >&2
    exit 1
  fi
  echo "📮 Submitting $ZIP_PATH for notarization (profile: $NOTARY_PROFILE)…"
  NOTARY_ARGS=(notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait)
  if [[ -n "$NOTARY_PRIMARY_BUNDLE_ID" ]]; then
    NOTARY_ARGS+=(--primary-bundle-id "$NOTARY_PRIMARY_BUNDLE_ID")
  fi
  if ! xcrun "${NOTARY_ARGS[@]}"; then
    echo "Error: Notarization failed." >&2
    exit 1
  fi
  echo "📎 Stapling notarization ticket to app bundle…"
  if ! xcrun stapler staple "$APP_PATH"; then
    echo "Error: Stapling notarization ticket failed." >&2
    exit 1
  fi
  echo "📦 Repackaging stapled app…"
  create_archive "$APP_PATH" "$ZIP_PATH"
  echo "🔍 Re-validating code signature post-staple…"
  if ! codesign --verify --deep --strict --verbose=2 "$APP_PATH"; then
    echo "Error: Code signature verification failed after stapling." >&2
    exit 1
  fi
  if command -v spctl >/dev/null 2>&1; then
    if ! spctl --assess --type execute --verbose "$APP_PATH"; then
      echo "Error: Gatekeeper assessment failed after stapling." >&2
      exit 1
    fi
  fi
  echo "✅ Notarization complete."
else
  if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "⚠️  Notarization disabled via NOTARIZE_APP=$NOTARIZE_MODE (profile ignored)." >&2
  else
    echo "⚠️  Notarization skipped (NOTARYTOOL_PROFILE not set)." >&2
  fi
  if command -v spctl >/dev/null 2>&1; then
    echo "🔍 Assessing app with Gatekeeper (not notarized)…"
    if ! spctl --assess --type execute --verbose "$APP_PATH"; then
      echo "Error: Gatekeeper assessment failed. Notarize the app or clear the quarantine attribute before distribution." >&2
      exit 1
    fi
  fi
fi

LATEST_ZIP_PATH="$DIST_DIR/MCPBundler-latest.zip"
echo "🔁 Updating latest archive alias: $LATEST_ZIP_PATH"
cp "$ZIP_PATH" "$LATEST_ZIP_PATH"

ARCHIVE_SIZE=$(stat -f%z "$ZIP_PATH")

if [[ -n "$SIGN_TOOL_OVERRIDE" ]]; then
  SIGN_TOOL="$SIGN_TOOL_OVERRIDE"
else
  SIGN_TOOL="$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
fi

if [[ ! -x "$SIGN_TOOL" ]]; then
  echo "Error: Sparkle sign_update tool not found at $SIGN_TOOL" >&2
  echo "You may need to build once so SwiftPM fetches Sparkle, or set SIGN_UPDATE_TOOL." >&2
  exit 1
fi

echo "🔏 Signing archive with Sparkle…"
SIGN_OUTPUT=$("$SIGN_TOOL" --ed-key-file "$PRIVATE_KEY_PATH" "$ZIP_PATH")
SIGNATURE=$(printf '%s\n' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')

if [[ -z "$SIGNATURE" ]]; then
  echo "Error: Could not extract Sparkle signature from sign_update output:" >&2
  echo "$SIGN_OUTPUT" >&2
  exit 1
fi

PUB_DATE=$(LC_ALL=C date -R)
DOWNLOAD_URL="${DOWNLOAD_BASE%/}/$ZIP_NAME"

CHANNEL_TITLE="${SPARKLE_CHANNEL_TITLE:-MCP Bundler Updates}"
CHANNEL_DESCRIPTION="${SPARKLE_CHANNEL_DESCRIPTION:-Latest builds of MCP Bundler for macOS.}"
CHANNEL_LINK="${SPARKLE_CHANNEL_LINK:-https://mcp-bundler.com/downloads/appcast.xml}"

python3 - <<'PY' "$APPCAST_PATH" "$CHANNEL_TITLE" "$CHANNEL_LINK" "$CHANNEL_DESCRIPTION" "$VERSION" "$BUILD_NUMBER" "$PUB_DATE" "$DOWNLOAD_URL" "$SIGNATURE" "$ARCHIVE_SIZE" "$NOTES_URL"
import sys
import xml.etree.ElementTree as ET
import re
from pathlib import Path

appcast_path = Path(sys.argv[1])
channel_title = sys.argv[2]
channel_link = sys.argv[3]
channel_description = sys.argv[4]
version_string = sys.argv[5]
build_number = sys.argv[6]
pub_date = sys.argv[7]
download_url = sys.argv[8]
signature = sys.argv[9]
archive_length = sys.argv[10]
notes_url = sys.argv[11]

namespaces = {
    'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle',
    'dc': 'http://purl.org/dc/elements/1.1/'
}

for prefix, uri in namespaces.items():
    ET.register_namespace(prefix, uri)

def ensure_channel_element(channel: ET.Element, tag: str, text: str) -> None:
    element = channel.find(tag)
    if element is None:
        element = ET.SubElement(channel, tag)
    if text and (element.text is None or not element.text.strip()):
        element.text = text

def dedupe_namespace_attributes(raw: str) -> str:
    def _dedupe(text: str, attr: str) -> str:
        pattern = re.compile(rf'\s{attr}="[^"]*"')
        matches = list(pattern.finditer(text))
        if len(matches) > 1:
            for match in reversed(matches[1:]):
                text = text[:match.start()] + text[match.end():]
        return text

    for attr in ("xmlns:sparkle", "xmlns:dc"):
        raw = _dedupe(raw, attr)
    return raw

if appcast_path.exists():
    try:
        tree = ET.parse(appcast_path)
    except ET.ParseError:
        cleaned = dedupe_namespace_attributes(appcast_path.read_text())
        appcast_path.write_text(cleaned)
        tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel = root.find('channel')
    if channel is None:
        channel = ET.SubElement(root, 'channel')
else:
    root = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(root, 'channel')
    tree = ET.ElementTree(root)

ensure_channel_element(channel, 'title', channel_title)
ensure_channel_element(channel, 'link', channel_link)
ensure_channel_element(channel, 'description', channel_description)
ensure_channel_element(channel, 'language', 'en')

# Remove any existing entries that share the same version identifiers to avoid duplicates.
for existing in list(channel.findall('item')):
    existing_version = existing.find('{http://www.andymatuschak.org/xml-namespaces/sparkle}version')
    existing_short = existing.find('{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString')
    if existing_version is not None and existing_short is not None:
        if existing_version.text == build_number and existing_short.text == version_string:
            channel.remove(existing)

item = ET.Element('item')
title = ET.SubElement(item, 'title')
title.text = f"MCP Bundler {version_string}"
sparkle_version = ET.SubElement(item, '{http://www.andymatuschak.org/xml-namespaces/sparkle}version')
sparkle_version.text = build_number
sparkle_short = ET.SubElement(item, '{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString')
sparkle_short.text = version_string
pub_date_el = ET.SubElement(item, 'pubDate')
pub_date_el.text = pub_date
enclosure = ET.SubElement(item, 'enclosure', {
    'url': download_url,
    '{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature': signature,
    'length': archive_length,
    'type': 'application/zip'
})
if notes_url:
    notes = ET.SubElement(item, '{http://www.andymatuschak.org/xml-namespaces/sparkle}releaseNotesLink')
    notes.text = notes_url

channel.insert(0, item)

appcast_path.parent.mkdir(parents=True, exist_ok=True)
tree.write(appcast_path, encoding='utf-8', xml_declaration=True)
PY

SHA256=""
SHA_PATH="$DIST_DIR/${ZIP_NAME}.sha256"
if command -v shasum >/dev/null 2>&1; then
  SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
  printf '%s  %s\n' "$SHA256" "$ZIP_NAME" > "$SHA_PATH"
fi

echo
echo "✅ Release artifacts created:"
echo "  • App bundle : $APP_PATH"
echo "  • Archive    : $ZIP_PATH"
echo "  • Appcast    : $APPCAST_PATH"
if [[ -n "$SHA256" ]]; then
  echo "  • SHA256     : $SHA256"
  echo "  • SHA file   : $SHA_PATH"
fi
echo
echo "Next steps:"
echo "  1. Upload $ZIP_PATH to ${DOWNLOAD_BASE}"
echo "  2. Upload $APPCAST_PATH to your hosting at ${CHANNEL_LINK}"
echo "  3. (Optional) Publish release notes at ${NOTES_URL:-<provide with --notes-url>}"
if [[ -n "$SHA256" ]]; then
  echo "  4. Update Homebrew cask with version ${VERSION}, sha256 ${SHA256}, url ${DOWNLOAD_URL}"
fi
echo
echo "Done."
