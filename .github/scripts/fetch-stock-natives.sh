#!/usr/bin/env bash
#
# Downloads the stock half of the bundle from nuget.org.
#
# Versions are read from scripts/VERSIONS.txt of the checked-out ref, never
# hardcoded here, so the stock half cannot drift from the fork-built half.
#
# Usage: fetch-stock-natives.sh <output-dir>
# Output: files laid out under <output-dir> by their slot path in
#         Assets/ExternalPlugins/ of the Unity project.

set -euo pipefail

OUT="${1:?usage: fetch-stock-natives.sh <output-dir>}"
VERSIONS="scripts/VERSIONS.txt"

[ -f "$VERSIONS" ] || { echo "not found: $VERSIONS (run from the repo root)" >&2; exit 1; }

# Reads "<id><spaces>nuget<spaces><version>" out of scripts/VERSIONS.txt.
nuget_version() {
    local id="$1" version
    version="$(awk -v id="$id" '$1 == id && $2 == "nuget" { print $3; exit }' "$VERSIONS")"
    [ -n "$version" ] || { echo "no 'nuget' version for '$id' in $VERSIONS" >&2; exit 1; }
    printf '%s' "$version"
}

# fetch <package-id> <path-inside-nupkg> <slot-path>
fetch() {
    local id="$1" src="$2" slot="$3"
    local version lower tmp
    version="$(nuget_version "$id")"
    lower="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    curl -fsSL --retry 3 --retry-delay 2 \
        "https://api.nuget.org/v3-flatcontainer/${lower}/${version}/${lower}.${version}.nupkg" \
        -o "$tmp/pkg.nupkg"

    mkdir -p "$OUT/$(dirname "$slot")"
    # unzip -p writes to stdout, so a missing entry yields an empty file rather
    # than an error -- hence the explicit size check below.
    unzip -p "$tmp/pkg.nupkg" "$src" > "$OUT/$slot"
    [ -s "$OUT/$slot" ] || {
        echo "empty or missing entry '$src' in ${id}/${version}" >&2
        exit 1
    }

    printf '%-42s <- %s/%s!%s\n' "$slot" "$id" "$version" "$src"
}

mkdir -p "$OUT"

# Native assets. Windows and macOS are consumed by the Unity Editor and the
# desktop players; linux-x64 libSkiaSharp.so is stock because the fork's Linux
# change touches only the libHarfBuzzSharp target.
fetch SkiaSharp.NativeAssets.Win32                 'runtimes/win-x64/native/libSkiaSharp.dll'      'x86_64/libSkiaSharp.dll'
fetch HarfBuzzSharp.NativeAssets.Win32             'runtimes/win-x64/native/libHarfBuzzSharp.dll'  'x86_64/libHarfBuzzSharp.dll'
fetch SkiaSharp.NativeAssets.macOS                 'runtimes/osx/native/libSkiaSharp.dylib'        'MacOS/libSkiaSharp.dylib'
fetch HarfBuzzSharp.NativeAssets.macOS             'runtimes/osx/native/libHarfBuzzSharp.dylib'    'MacOS/libHarfBuzzSharp.dylib'
fetch SkiaSharp.NativeAssets.Linux.NoDependencies  'runtimes/linux-x64/native/libSkiaSharp.so'     'x86_64/libSkiaSharp.so'

# Managed assemblies for every platform except WebGL. The WebGL variants are
# built from this repo with SkiaSharpUnityWebGLInternal=true; these are stock.
fetch SkiaSharp            'lib/netstandard2.1/SkiaSharp.dll'            'SkiaSharp.dll'
fetch SkiaSharp.HarfBuzz   'lib/netstandard2.1/SkiaSharp.HarfBuzz.dll'   'SkiaSharp.HarfBuzz.dll'
fetch HarfBuzzSharp        'lib/netstandard2.1/HarfBuzzSharp.dll'        'HarfBuzzSharp.dll'
