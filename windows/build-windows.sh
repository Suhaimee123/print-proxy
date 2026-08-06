#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/meesystempos-win.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

pkg_bin="${PKG_BIN:-}"
if [[ -z "$pkg_bin" ]]; then
  pkg_bin="$(find "$HOME/.npm/_npx" -path '*/node_modules/.bin/pkg' -type f -o -path '*/node_modules/.bin/pkg' -type l 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$pkg_bin" ]]; then
  pkg_bin="npx pkg@5.8.1"
fi

compiler="${MINGW_CC:-x86_64-w64-mingw32-gcc}"
resource_compiler="${MINGW_WINDRES:-x86_64-w64-mingw32-windres}"
command -v "$compiler" >/dev/null || { echo "Missing $compiler (install mingw-w64)"; exit 1; }
command -v "$resource_compiler" >/dev/null || { echo "Missing $resource_compiler (install mingw-w64)"; exit 1; }

if [[ "$pkg_bin" == "npx pkg@5.8.1" ]]; then
  (cd "$project_dir" && npx pkg@5.8.1 server.js --targets node18-win-x64 --output "$build_dir/print-proxy-server-win.exe")
else
  (cd "$project_dir" && "$pkg_bin" server.js --targets node18-win-x64 --output "$build_dir/print-proxy-server-win.exe")
fi

(cd "$build_dir" && "$resource_compiler" -I "$script_dir" "$script_dir/windows-tray.rc" -O coff -o windows-tray-res.o)
"$compiler" -Os -s -municode -mwindows -static -finput-charset=UTF-8 \
  "$script_dir/windows-tray.c" "$build_dir/windows-tray-res.o" \
  -o "$build_dir/print-proxy-win.exe" \
  -lshell32 -lws2_32 -lgdi32 -luser32

mv "$build_dir/print-proxy-win.exe" "$script_dir/print-proxy-win.exe"
echo "Built: $script_dir/print-proxy-win.exe"
