#!/usr/bin/env bash
#
# Assembles the bundle: checks that every expected slot is present, writes
# versions.json, and zips the result.
#
# The slot table below is the definition of what a bundle contains. A slot path
# is where the file lands inside Assets/ExternalPlugins/ of the Unity project;
# the platform a native plugin applies to is decided by that directory name and
# by the .meta file already committed next to it, which this bundle never
# touches.
#
# See documentation/ci/native-build-spec.md §2 and §4.
#
# Usage: make-bundle.sh <slots-dir> <output-zip>
# Environment: BUNDLE_VERSION, BUILD_REF, BUILD_COMMIT,
#              EMSCRIPTEN_VERSION, EMSCRIPTEN_FEATURES, UNITY_VERSION

set -euo pipefail

SLOTS="${1:?usage: make-bundle.sh <slots-dir> <output-zip>}"
OUTPUT="${2:?missing output zip path}"
VERSIONS="scripts/VERSIONS.txt"

: "${BUNDLE_VERSION:?}" "${BUILD_REF:?}" "${BUILD_COMMIT:?}"
: "${EMSCRIPTEN_VERSION:?}" "${EMSCRIPTEN_FEATURES:?}" "${UNITY_VERSION:?}"

nuget_version() {
    local id="$1" version
    version="$(awk -v id="$id" '$1 == id && $2 == "nuget" { print $3; exit }' "$VERSIONS")"
    [ -n "$version" ] || { echo "no 'nuget' version for '$id' in $VERSIONS" >&2; exit 1; }
    printf '%s' "$version"
}

stock() { printf 'nuget:%s/%s' "$1" "$(nuget_version "$1")"; }

# sha256sum/stat -c are GNU-only; these fall back so the script can also be run
# on a developer's machine, not just on the Linux runner.
sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}
size_of() { wc -c < "$1" | tr -d ' '; }

# slot path <TAB> source description
SLOT_TABLE="$(cat <<EOF
WebGL/libSkiaSharp.a	fork
WebGL/libHarfBuzzSharp.a	fork
WebGL/SkiaSharp.dll	fork
WebGL/HarfBuzzSharp.dll	fork
x86_64/libHarfBuzzSharp.so	fork
x86_64/libSkiaSharp.so	$(stock SkiaSharp.NativeAssets.Linux.NoDependencies)
x86_64/libSkiaSharp.dll	$(stock SkiaSharp.NativeAssets.Win32)
x86_64/libHarfBuzzSharp.dll	$(stock HarfBuzzSharp.NativeAssets.Win32)
MacOS/libSkiaSharp.dylib	$(stock SkiaSharp.NativeAssets.macOS)
MacOS/libHarfBuzzSharp.dylib	$(stock HarfBuzzSharp.NativeAssets.macOS)
SkiaSharp.dll	$(stock SkiaSharp)
SkiaSharp.HarfBuzz.dll	$(stock SkiaSharp.HarfBuzz)
HarfBuzzSharp.dll	$(stock HarfBuzzSharp)
EOF
)"

# Every slot must exist and be non-empty: a job that silently produced nothing
# would otherwise ship a bundle with a hole in it.
missing=0
while IFS=$'\t' read -r slot _; do
    [ -s "$SLOTS/$slot" ] || { echo "missing or empty slot: $slot" >&2; missing=1; }
done <<< "$SLOT_TABLE"
[ "$missing" -eq 0 ] || { echo "bundle is incomplete" >&2; exit 1; }

files_json="$(
    while IFS=$'\t' read -r slot source; do
        jq -nc \
            --arg slot "$slot" \
            --arg source "$source" \
            --arg sha256 "$(sha256_of "$SLOTS/$slot")" \
            --argjson bytes "$(size_of "$SLOTS/$slot")" \
            '{slot: $slot, source: $source, sha256: $sha256, bytes: $bytes}'
    done <<< "$SLOT_TABLE" | jq -sc '.'
)"

jq -n \
    --arg bundle "$BUNDLE_VERSION" \
    --arg ref "$BUILD_REF" \
    --arg commit "$BUILD_COMMIT" \
    --arg builtAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg skiaSharp "$(nuget_version SkiaSharp)" \
    --arg harfBuzzSharp "$(nuget_version HarfBuzzSharp)" \
    --arg emscripten "$EMSCRIPTEN_VERSION" \
    --arg emscriptenFeatures "$EMSCRIPTEN_FEATURES" \
    --arg unity "$UNITY_VERSION" \
    --argjson files "$files_json" \
    '{bundle: $bundle, ref: $ref, commit: $commit, builtAt: $builtAt,
      skiaSharp: $skiaSharp, harfBuzzSharp: $harfBuzzSharp,
      emscripten: $emscripten, emscriptenFeatures: $emscriptenFeatures,
      unity: $unity, files: $files}' \
    > "$SLOTS/versions.json"

echo "versions.json:"
sed 's/^/    /' "$SLOTS/versions.json"
echo

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
(cd "$SLOTS" && zip -qr - .) > "$OUTPUT"

echo "bundle: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
