#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/meesystempos-mac.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

pkg_bin="${PKG_BIN:-}"
if [[ -z "$pkg_bin" ]]; then
  pkg_bin="$(find "$HOME/.npm/_npx" \( -type f -o -type l \) -path '*/node_modules/.bin/pkg' 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$pkg_bin" ]]; then
  pkg_bin="npx pkg@5.8.1"
fi

sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ ! -d "$sdk" ]]; then
  sdk="$(xcrun --show-sdk-path --sdk macosx)"
fi

app_dir="$build_dir/print-proxy-macos.app"
cache_root="${MEESYSTEMPOS_BUILD_CACHE:-/tmp}"
module_cache_arm64="$cache_root/print-proxy-module-cache-arm"
module_cache_x86_64="$cache_root/print-proxy-module-cache-x64"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$module_cache_arm64" "$module_cache_x86_64"

if [[ "$pkg_bin" == "npx pkg@5.8.1" ]]; then
  (cd "$project_dir" && npx pkg@5.8.1 server.js --targets node18-macos-x64 --output "$app_dir/Contents/Resources/print-proxy-server-bin")
else
  (cd "$project_dir" && "$pkg_bin" server.js --targets node18-macos-x64 --output "$app_dir/Contents/Resources/print-proxy-server-bin")
fi

swiftc -O -target arm64-apple-macos12.0 -sdk "$sdk" \
  -module-cache-path "$module_cache_arm64" \
  -o "$build_dir/menu-arm64" "$script_dir/menu.swift"
swiftc -O -target x86_64-apple-macos12.0 -sdk "$sdk" \
  -module-cache-path "$module_cache_x86_64" \
  -o "$build_dir/menu-x86_64" "$script_dir/menu.swift"
lipo -create "$build_dir/menu-arm64" "$build_dir/menu-x86_64" \
  -output "$app_dir/Contents/MacOS/print-proxy-macos"

cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"
chmod +x "$app_dir/Contents/MacOS/print-proxy-macos" "$app_dir/Contents/Resources/print-proxy-server-bin"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

rm -rf "$script_dir/print-proxy-macos.app"
mv "$app_dir" "$script_dir/print-proxy-macos.app"
xattr -cr "$script_dir/print-proxy-macos.app"
codesign --force --deep --sign - "$script_dir/print-proxy-macos.app"

zip_tmp="$build_dir/MeeSystemPos-Print-Proxy-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$script_dir/print-proxy-macos.app" "$zip_tmp"
mv "$zip_tmp" "$script_dir/MeeSystemPos-Print-Proxy-macOS.zip"

echo "Built: $script_dir/print-proxy-macos.app"
echo "Package: $script_dir/MeeSystemPos-Print-Proxy-macOS.zip"
