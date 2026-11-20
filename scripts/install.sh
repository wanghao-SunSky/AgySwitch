#!/usr/bin/env bash
set -euo pipefail

REPO="wanghao-SunSky/AgySwitch"
APP_NAME="AgySwitch.app"
BUNDLE_ID="com.agyacct.agyswitch"
INSTALL_DIR="${AGYSWITCH_INSTALL_DIR:-/Applications}"
VERSION="${AGYSWITCH_VERSION:-latest}"
NO_LAUNCH="${AGYSWITCH_NO_LAUNCH:-0}"

fail() {
  printf 'AgySwitch install error: %s\n' "$1" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "AgySwitch only supports macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "AgySwitch currently requires Apple Silicon (arm64)."

for cmd in curl ditto shasum plutil codesign; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required macOS tool: $cmd"
done

if [[ "$VERSION" == "latest" ]]; then
  final_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest")"
  tag="${final_url##*/}"
  [[ -n "$tag" && "$tag" != "releases" && "$tag" != "latest" ]] || fail "Unable to resolve latest release tag."
else
  tag="$VERSION"
fi

asset="AgySwitch-${tag}-macos-arm64.zip"
base_url="https://github.com/${REPO}/releases/download/${tag}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agyswitch-install.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

printf 'Downloading %s (%s)...\n' "$APP_NAME" "$tag"
curl -fsSL --proto '=https' --tlsv1.2 -o "${tmp_dir}/${asset}" "${base_url}/${asset}"
curl -fsSL --proto '=https' --tlsv1.2 -o "${tmp_dir}/SHA256SUMS.txt" "${base_url}/SHA256SUMS.txt"

expected_sha="$(awk -v name="$asset" '$2 == name { print $1; exit }' "${tmp_dir}/SHA256SUMS.txt")"
[[ -n "$expected_sha" ]] || fail "Checksum entry for ${asset} not found in SHA256SUMS.txt."
actual_sha="$(shasum -a 256 "${tmp_dir}/${asset}" | awk '{ print $1 }')"
[[ "$actual_sha" == "$expected_sha" ]] || fail "SHA-256 verification failed for ${asset}."
printf 'SHA-256 verified: %s\n' "$actual_sha"

mkdir -p "${tmp_dir}/unpack"
ditto -x -k "${tmp_dir}/${asset}" "${tmp_dir}/unpack"
staged_app="${tmp_dir}/unpack/${APP_NAME}"
[[ -d "$staged_app" ]] || fail "Archive did not contain ${APP_NAME}."

staged_id="$(plutil -extract CFBundleIdentifier raw "${staged_app}/Contents/Info.plist" 2>/dev/null || true)"
[[ "$staged_id" == "$BUNDLE_ID" ]] || fail "Unexpected bundle identifier: ${staged_id:-unknown}."
codesign --verify --deep --strict "$staged_app"

mkdir -p "$INSTALL_DIR" 2>/dev/null || fail "Cannot create install directory: ${INSTALL_DIR}"
[[ -w "$INSTALL_DIR" ]] || fail "Directory is not writable: ${INSTALL_DIR} (try AGYSWITCH_INSTALL_DIR=\"\$HOME/Applications\")"

dest="${INSTALL_DIR}/${APP_NAME}"
if [[ -e "$dest" || -L "$dest" ]]; then
  [[ ! -L "$dest" ]] || fail "Refusing to overwrite symlink at ${dest}."
  existing_id="$(plutil -extract CFBundleIdentifier raw "${dest}/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$existing_id" == "$BUNDLE_ID" ]] || fail "An unrelated item already exists at ${dest}."
  if [[ "$NO_LAUNCH" != "1" ]]; then
    pkill -x AgySwitch 2>/dev/null || true
    sleep 0.3
  fi
fi

swap_dir="$(mktemp -d "${INSTALL_DIR}/.AgySwitch-install.XXXXXX")"
swap_cleanup() {
  if [[ -e "${swap_dir}/previous.app" && ! -e "$dest" ]]; then
    mv "${swap_dir}/previous.app" "$dest" || true
  fi
  rm -rf "$swap_dir"
  cleanup
}
trap swap_cleanup EXIT

ditto "$staged_app" "${swap_dir}/${APP_NAME}"
if [[ -e "$dest" ]]; then
  mv "$dest" "${swap_dir}/previous.app"
fi
mv "${swap_dir}/${APP_NAME}" "$dest"
rm -rf "$swap_dir"
trap cleanup EXIT

printf 'Installed to %s\n' "$dest"
if [[ "$NO_LAUNCH" != "1" ]]; then
  open -a "$dest"
  printf 'AgySwitch is now running in your menu bar (⇄).\n'
fi
