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

BASELINE_FILE="documentation/ci/harfbuzz-symbol-baseline.txt"
failures=0

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

# Prints at most 40 lines of context for a failure, indented.
show() { sed 's/^/        /' | head -40 >&2; }

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
        | sort -u
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
    | grep -hoP '\bhb_[A-Za-z0-9_]*\b(?=\s*\()' \
    | sort -u
)"
# If the binding files ever move, extraction would silently yield nothing and
# this check would pass while verifying absolutely nothing.
if [ -z "$managed_api" ]; then
    fail "extracted no hb_* names from the managed binding -- did binding/HarfBuzzSharp/HarfBuzzApi*.cs move?"
else
    missing="$(comm -23 <(printf '%s\n' "$managed_api") <(printf '%s\n' "$hb_symbols"))"
    if [ -n "$missing" ]; then
        fail "$(wc -l <<< "$missing") hb_* names P/Invoked by the binding are not exported:"
        show <<< "$missing"
    else
        pass "all $(wc -l <<< "$managed_api") P/Invoked hb_* names exported under their original names"
    fi
fi

# 5. Guard on harfbuzz's unprotected C++ internals. This does not fix the gap
#    documented in documentation/adr/0003-harfbuzz-cpp-internals-residual-risk.md
#    -- it turns a silent, DEPS-bump-fragile risk into a build-time signal.
#    Until a baseline is recorded, this only reports.
unprotected="$(grep '^_Z' <<< "$hb_symbols" | grep -cv '^sksharp_' || true)"
echo "   unprotected mangled C++ symbols (_Z* without sksharp_): $unprotected"

if [ -f "$BASELINE_FILE" ]; then
    baseline="$(grep -oE '^[0-9]+' "$BASELINE_FILE" | head -1)"
    if [ -z "$baseline" ]; then
        fail "$BASELINE_FILE exists but holds no number"
    elif [ "$unprotected" -gt "$baseline" ]; then
        fail "unprotected mangled symbols grew: $unprotected > $baseline (baseline in $BASELINE_FILE).
        Something widened the collision surface against a host's own harfbuzz --
        a harfbuzz DEPS bump, a flag change, or a regression in the rename mechanism.
        See documentation/adr/0003-harfbuzz-cpp-internals-residual-risk.md before raising the baseline."
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
    echo "         archive, this one is the total in our archive."
fi

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
