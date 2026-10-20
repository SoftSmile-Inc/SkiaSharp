#!/usr/bin/env bash
#
# Verifies that symbol renaming worked in a freshly built wasm libSkiaSharp.a
# (documentation/wasm-symbol-renaming.md).
#
# Usage: check-wasm-symbols.sh <docker-image> <libSkiaSharp.a>

set -euo pipefail

IMAGE="${1:?usage: check-wasm-symbols.sh <image> <libSkiaSharp.a>}"
SKIA_ARCHIVE="${2:?missing libSkiaSharp.a}"

failures=0

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

# Prints at most 40 lines of context for a failure, indented. Reads all of its
# input: 'sed | head' would die of SIGPIPE under pipefail on a long list.
show() { awk 'NR <= 40 { print "        " $0 } END { if (NR > 40) print "        ... (" NR - 40 " more)" }' >&2; }

[ -s "$SKIA_ARCHIVE" ] || { echo "not found or empty: $SKIA_ARCHIVE" >&2; exit 1; }

# Global, defined symbols of an archive -- the ones that would take part in a
# duplicate-symbol collision. Archive member header lines don't match the
# three-field shape, so they drop out.
symbols() {
    docker run --rm --volume "$PWD:/work" --workdir /work "$IMAGE" \
        emnm --defined-only --extern-only "$1" \
        | awk 'NF == 3 && $1 ~ /^[0-9a-fA-F]+$/ { print $3 }' \
        | LC_ALL=C sort -u
}

echo "== libSkiaSharp.a =="
skia_symbols="$(symbols "$SKIA_ARCHIVE")"
echo "   $(wc -l <<< "$skia_symbols") global symbols"

# 1. Nothing from freetype2 / libjpeg-turbo / libpng may survive under its
#    original name. zlib is deliberately not covered by the mechanism (its
#    vendored Chromium fork already prefixes itself with Cr_z_), so it is not
#    checked here either.
leaked="$(grep -E '^(FT_|png_|jpeg_)' <<< "$skia_symbols" || true)"
if [ -n "$leaked" ]; then
    fail "$(wc -l <<< "$leaked") third-party symbols left unrenamed in libSkiaSharp.a:"
    show <<< "$leaked"
else
    pass "no unrenamed FT_* / png_* / jpeg_* symbols"
fi

# 2. Renaming actually ran (guards against the flag silently not taking effect).
renamed_count="$(grep -c '^sksharp_' <<< "$skia_symbols" || true)"
if [ "$renamed_count" -eq 0 ]; then
    fail "no sksharp_* symbols in libSkiaSharp.a -- did --wasmRenameThirdPartySymbols take effect?"
else
    pass "$renamed_count renamed sksharp_* symbols"
fi

# 3. SkiaSharp's own C API must be untouched by the renaming.
sk_count="$(grep -c '^sk_' <<< "$skia_symbols" || true)"
if [ "$sk_count" -eq 0 ]; then
    fail "no sk_* symbols in libSkiaSharp.a -- SkiaSharp's own C API is missing"
else
    pass "$sk_count sk_* symbols intact"
fi

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
