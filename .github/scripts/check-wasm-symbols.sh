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

# Overridable because CI takes the baseline from the workflow's own commit,
# not from the ref being built (which may predate the file).
BASELINE_FILE="${BASELINE_FILE:-documentation/ci/harfbuzz-symbol-baseline.txt}"
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

# 4. Every hb_* name the managed binding P/Invokes must still be exported under
#    its original name, via the alias mechanism. If the aliases didn't land, the
#    archive links fine and the player dies at startup instead.
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
    missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$managed_api") <(printf '%s\n' "$hb_symbols"))"
    if [ -n "$missing" ]; then
        fail "$(wc -l <<< "$missing") hb_* names P/Invoked by the binding are not exported:"
        show <<< "$missing"
        # An alias declared without extern "C" in a C++ translation unit is
        # exported as _Z<len><name>v instead -- present, but not under the name
        # the P/Invoke looks for.
        mangled="$(
            while read -r name; do printf '_Z%d%sv\n' "${#name}" "$name"; done <<< "$missing" \
            | LC_ALL=C sort | LC_ALL=C comm -12 - <(printf '%s\n' "$hb_symbols")
        )"
        if [ -n "$mangled" ]; then
            echo "        $(wc -l <<< "$mangled") of them are exported only C++-mangled, e.g. $(head -1 <<< "$mangled"):" >&2
            echo "        the alias declarations have C++ linkage (missing extern \"C\")." >&2
        fi
    else
        pass "all $(wc -l <<< "$managed_api") P/Invoked hb_* names exported under their original names"
    fi
fi

# 5. harfbuzz's own renaming actually ran. Check 4 alone would pass on a
#    completely unrenamed archive, since every hb_* name is then present anyway.
hb_renamed="$(grep -c '^sksharp_hb_' <<< "$hb_symbols" || true)"
if [ "$hb_renamed" -eq 0 ]; then
    fail "no sksharp_hb_* symbols in libHarfBuzzSharp.a -- the harfbuzz rename header did not take effect"
else
    pass "$hb_renamed renamed sksharp_hb_* symbols"
fi

# 6. Guard on harfbuzz's unrenamed C++ internals. libHarfBuzzSharp.a is not
#    shipped for the Unity player (documentation/adr/0004-*), so this keeps the
#    mechanism in a known state for its stage B rather than protecting a link;
#    it still fails the build on purpose, so a drift is noticed when it happens.
#    Until a baseline is recorded, this only reports.
#    Renamed symbols start with sksharp_, so every _Z* name is unprotected.
unprotected="$(grep -c '^_Z' <<< "$hb_symbols" || true)"
echo "   unprotected mangled C++ symbols (_Z*): $unprotected"

if [ -f "$BASELINE_FILE" ]; then
    baseline="$(grep -oE '^[0-9]+' "$BASELINE_FILE" | head -1 || true)"
    if [ -z "$baseline" ]; then
        fail "$BASELINE_FILE exists but holds no number"
    elif [ "$unprotected" -gt "$baseline" ]; then
        fail "unprotected mangled symbols grew: $unprotected > $baseline (baseline in $BASELINE_FILE).
        Something added unrenamed C++ symbols -- a harfbuzz DEPS bump or a change
        of build flags. See documentation/ci/native-build-spec.md §5.2 and
        documentation/adr/0004-webgl-harfbuzzsharp-binds-to-unity-harfbuzz.md
        before raising the baseline."
    else
        pass "unprotected mangled symbols within baseline ($unprotected <= $baseline)"
    fi
else
    echo
    echo "   NOTE: no baseline recorded yet. To start enforcing this guard, commit"
    echo "         the measured value:"
    echo
    echo "           echo '$unprotected' > $BASELINE_FILE"
    echo
    echo "         Do not confuse this number with the 1027 in ADR 0003 -- that one"
    echo "         is the intersection with a specific Unity editor's own harfbuzz"
    echo "         archive, this one is the total in our archive (weak included)."
fi

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
