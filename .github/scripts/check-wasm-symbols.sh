#!/usr/bin/env bash
#
# Verifies that the symbol-renaming machinery actually did its job in a freshly
# built pair of wasm archives. These checks are cheap and deterministic; without
# them a broken rename surfaces as a player that fails at startup, half an hour
# of manual work later.
#
# See documentation/ci/native-build-spec.md §5.1 and §5.2.
#
# Usage: check-wasm-symbols.sh <docker-image> <libSkiaSharp.a> <libHarfBuzzSharp.a>

set -euo pipefail

IMAGE="${1:?usage: check-wasm-symbols.sh <image> <libSkiaSharp.a> <libHarfBuzzSharp.a>}"
SKIA_ARCHIVE="${2:?missing libSkiaSharp.a}"
HARFBUZZ_ARCHIVE="${3:?missing libHarfBuzzSharp.a}"

failures=0

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

# Prints at most 40 lines of context for a failure, indented. Reads all of its
# input: 'sed | head' would die of SIGPIPE under pipefail on a long list.
show() { awk 'NR <= 40 { print "        " $0 } END { if (NR > 40) print "        ... (" NR - 40 " more)" }' >&2; }

for archive in "$SKIA_ARCHIVE" "$HARFBUZZ_ARCHIVE"; do
    [ -s "$archive" ] || { echo "not found or empty: $archive" >&2; exit 1; }
done

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
echo "== libHarfBuzzSharp.a =="
hb_symbols="$(symbols "$HARFBUZZ_ARCHIVE")"
echo "   $(wc -l <<< "$hb_symbols") global symbols"

# The wasm libHarfBuzzSharp.a is linked next to Unity's own harfbuzz, so it must
# define nothing under a name harfbuzz itself uses: in a static link two strong
# definitions collide whatever their visibility, and weak ones silently merge
# across the two versions. Everything is renamed with the sksharp_ prefix and
# the managed binding's __Internal variant calls those names
# (documentation/adr/0005-webgl-harfbuzz-isolation.md).

# 4. Every name the managed binding P/Invokes has a renamed definition.
#    Name extraction mirrors GetHarfBuzzManagedApiNames in native/wasm/build.cake:
#    a bare hb_* identifier immediately followed by '(', ignoring the
#    '// typedef ...' function-pointer comments whose '(' belongs to the syntax.
managed_api="$(
    grep -hv '^[[:space:]]*// typedef' \
        binding/HarfBuzzSharp/HarfBuzzApi.cs \
        binding/HarfBuzzSharp/HarfBuzzApi.generated.cs \
    | { grep -hoP '\bhb_[A-Za-z0-9_]*\b(?=\s*\()' || true; } \
    | LC_ALL=C sort -u
)"
# If the binding files ever move, extraction would silently yield nothing and
# this check would pass while verifying absolutely nothing.
if [ -z "$managed_api" ]; then
    fail "extracted no hb_* names from the managed binding -- did binding/HarfBuzzSharp/HarfBuzzApi*.cs move?"
else
    missing="$(LC_ALL=C comm -23 <(awk '{ print "sksharp_" $0 }' <<< "$managed_api" | LC_ALL=C sort) <(printf '%s\n' "$hb_symbols"))"
    if [ -n "$missing" ]; then
        fail "$(wc -l <<< "$missing") names the binding P/Invokes have no renamed definition:"
        show <<< "$missing"
    else
        pass "all $(wc -l <<< "$managed_api") P/Invoked names defined as sksharp_hb_*"
    fi
fi

# 5. Nothing under a plain hb_* name: such a definition either collides with the
#    host's harfbuzz or, if weak, captures the host's own calls.
plain_hb="$(grep '^hb_' <<< "$hb_symbols" || true)"
if [ -n "$plain_hb" ]; then
    fail "$(wc -l <<< "$plain_hb") symbols in libHarfBuzzSharp.a still have a plain hb_* name:"
    show <<< "$plain_hb"
else
    pass "no plain hb_* symbols"
fi

# 6. Every defined global symbol is renamed -- C names start with sksharp_, C++
#    names carry it in their outermost scope (eg. _ZN11sksharp_AAT...). A name
#    left over means the generated rename headers missed something: a harfbuzz
#    update, a new mangling shape, or a flag change.
unrenamed="$(grep -v 'sksharp_' <<< "$hb_symbols" || true)"
if [ -n "$unrenamed" ]; then
    fail "$(wc -l <<< "$unrenamed") symbols in libHarfBuzzSharp.a are not renamed:"
    show <<< "$unrenamed"
else
    pass "every one of $(wc -l <<< "$hb_symbols") global symbols is renamed (sksharp_)"
fi

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
