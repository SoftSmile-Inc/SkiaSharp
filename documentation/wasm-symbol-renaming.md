# WASM Third-Party Symbol Renaming

An opt-in build-time mechanism that avoids duplicate-symbol linker errors when the wasm `libSkiaSharp.a`/`libHarfBuzzSharp.a` static libraries are linked into a host application that statically links its own copies of freetype2, libjpeg-turbo, zlib, libpng, or harfbuzz.

## TL;DR

- **Problem:** `libSkiaSharp.a`/`libHarfBuzzSharp.a` (wasm) and a host app's own freetype2/libjpeg-turbo/zlib/libpng/harfbuzz export the same global C symbols. Statically linking both into one binary fails (or silently picks the wrong copy).
- **Solution:** an opt-in flag (`wasmRenameThirdPartySymbols`) renames every global symbol these libraries export, via a generated `#define` header force-included into the whole wasm build. The header is regenerated automatically as part of the same build invocation that uses it, so it cannot go stale relative to the checkout, the feature flags, or the emscripten toolchain being built.
  - harfbuzz needs a second mechanism on top of this, because it's C++ (mostly unreachable by textual renaming) and because its public API — unlike freetype2/libjpeg-turbo/zlib/libpng — is also what the managed `HarfBuzzSharp` binding P/Invokes directly. See [§5](#5-harfbuzz-hiding--aliasing-instead-of-a-plain-rename).
- **Off by default** — standard SkiaSharp wasm builds (and every wasm job in the current CI matrix) are unaffected.
- Relevant files: `native/wasm/build.cake`, `native/wasm/libSkiaSharp/wasm_symbol_renames.h` (generated), `native/wasm/libHarfBuzzSharp/wasm_symbol_renames.h` (generated), `native/wasm/libHarfBuzzSharp/wasm_hb_extern_visibility.h`, `native/wasm/libHarfBuzzSharp/wasm_symbol_aliases.h` (generated), `scripts/Docker/wasm/build-local.sh`, `scripts/Docker/wasm/generate-symbol-renames-local.sh`.

## 1. The problem being solved

Skia's wasm target statically links `freetype2`, `libjpeg-turbo`, `zlib`, and `libpng` into `libSkiaSharp.a` (`skia_use_system_freetype2/libjpeg_turbo/libpng/zlib = false` in `WasmSkiaGnArgs`, `native/wasm/build.cake`). These libraries export their normal C API as global symbols — `FT_Init_FreeType`, `jpeg_CreateDecompress`, `png_read_info`, and hundreds of internal helpers besides. None of freetype2, libjpeg-turbo, or libpng ship any built-in namespacing; zlib's vendored Chromium fork prefixes its own public and internal symbols with `Cr_z_` (`third_party/externals/zlib/chromeconf.h`), which already prevents collisions with a plain/vanilla host zlib (whose symbols are named `deflate`, `inflate`, etc., not `Cr_z_deflate`) — but not with another *Chromium-forked* zlib using the same `Cr_z_` convention.

`libSkiaSharp.a` is designed to be statically linked into a host application — the motivating case is a Unity build — that may bundle its own copies of the same libraries. When both static libraries end up in the same final link, the linker sees two definitions of the same global symbol and either fails outright with a duplicate-symbol error, or (depending on link order) silently resolves to one copy, which can be an ABI-incompatible or unexpected version.

The requirement: make every third-party symbol `libSkiaSharp.a` exports unique to it, without touching SkiaSharp's own C API surface (`sk_*`), without requiring any change in the host application, and without hand-maintaining a list of symbols that will inevitably drift as freetype2/libjpeg-turbo/zlib/libpng are updated.

## 2. The solution

### 2.1 Mechanism

- Off by default; enabled with `--wasmRenameThirdPartySymbols=true` (or `WASM_RENAME_THIRDPARTY_SYMBOLS=true`) passed to the `native/wasm/build.cake` invocation.
- Every global symbol freetype2/libjpeg-turbo/zlib/libpng actually export is renamed to `sksharp_<original>`, via a generated C header (`native/wasm/libSkiaSharp/wasm_symbol_renames.h`) containing one `#define original sksharp_original` per symbol.
- That header is force-included into every translation unit of the wasm build (`-include <header>` added to `extra_cflags` in `WasmSkiaGnArgs`). Because the `-include` applies build-wide, both the third-party libraries' own definitions *and* every call site inside Skia's own code get rewritten to the same renamed identifier — the two sides can't fall out of sync.
- **Discovering "every global symbol"** is automated rather than hand-maintained: the `generate-wasm-symbol-renames` Cake task builds freetype2/libjpeg-turbo/zlib/libpng in isolation, into a dedicated `out/wasm-symgen` directory so the normal build output is untouched, then runs `nm --defined-only --extern-only` on the resulting `.a` archives to enumerate every symbol that would actually participate in a link-time collision. Each library's archive is located by searching for a symbol unique to it (`FT_Init_FreeType`, `jpeg_CreateDecompress`, `Cr_z_deflate`, `png_read_info`), since GN's `third_party()` template doesn't guarantee output archive filenames.
- This approach was chosen over each library's own partial prefixing options (zlib's `Z_PREFIX`, libpng's `PNG_PREFIX`) because those only cover documented public APIs — internal helpers that are still exported as globals (and can still collide) are missed. Discovering symbols via `nm` on the real compiled output is complete by construction and keeps all four libraries on one uniform mechanism.
- **libpng's `PNG_USE_READ_MACROS` would otherwise defeat the rename for exactly three symbols.** `png_get_uint_16`/`png_get_uint_32`/`png_get_int_32` are enabled by default (`PNG_DEFAULT_READ_MACROS 1` in `pnglibconf.h.prebuilt`) to also be redefined as function-like macros by `png.h`, later in the same translation unit than our forced `-include`. That redefinition wins over our plain `#define <symbol> sksharp_<symbol>` for just these three names — and `pngrutil.c` deliberately declares them as `TYPE (PNGAPI\nname)(args)` (parenthesized specifically so the name isn't immediately followed by `(`), which also happens to prevent the function-like macro from firing at the definition site, so the untouched original name leaks into the compiled object. `extra_cflags` therefore also passes `-DPNG_NO_USE_READ_MACROS` whenever renaming is enabled, so these three symbols go through the same plain-function/plain-rename path as everything else.

### 2.2 Keeping the generated header from going stale

A generated header is only as good as its freshness — the header can drift from what's actually being compiled after a Skia DEPS bump, or when built with a different combination of SIMD/threading/exception-handling flags (`--emscriptenFeatures=...`) than whatever it was last generated against. Rather than relying on a human remembering to regenerate and commit it, the design closes this gap structurally:

- `generate-wasm-symbol-renames` is a dependency of the `libSkiaSharp` task (`.IsDependentOn("generate-wasm-symbol-renames")`), gated by `.WithCriteria(IsRunningOnLinux() && ENABLE_SYMBOL_RENAMES)`. When renaming is off — the default, and every wasm job in the current CI matrix (`scripts/azure-templates-stages-native-wasm.yml`) — the task is skipped at near-zero cost. When it's on, it always runs immediately before `libSkiaSharp`, in the same Cake invocation, against the exact same checkout and toolchain container.
- The discovery build shares the same `HAS_SIMD_ENABLED` / `HAS_THREADING_ENABLED` / `HAS_WASM_EH` flags as the real build (computed once, at file scope, in `native/wasm/build.cake`, instead of being recomputed — and previously hardcoded to `false` for discovery — separately per task). The two builds' GN args, and therefore their exported symbols, cannot drift apart within a single invocation.
- Net effect: a single build command is sufficient end-to-end. There is no separate "run the generator, review the diff, commit it, then build" workflow to forget a step of.

## 3. Usage

Build with renaming enabled, via the Docker helper script:

```bash
./scripts/Docker/wasm/build-local.sh 3.1.34 --wasmRenameThirdPartySymbols=true
```

With a specific feature combination — the discovery build automatically matches it:

```bash
./scripts/Docker/wasm/build-local.sh 3.1.34 --wasmRenameThirdPartySymbols=true --emscriptenFeatures=_wasmeh,mt,simd
```

To inspect the generated header on its own, without running the full `libSkiaSharp` build:

```bash
./scripts/Docker/wasm/generate-symbol-renames-local.sh 3.1.34
```

(this internally passes `--wasmRenameThirdPartySymbols=true` so the task's criteria is met; it writes `native/wasm/libSkiaSharp/wasm_symbol_renames.h`)

## 4. Usage: harfbuzz on its own

```bash
./scripts/Docker/wasm/build-local.sh 3.1.34 --wasmRenameThirdPartySymbols=true --target=externals-wasm
```

already regenerates both `native/wasm/libSkiaSharp/wasm_symbol_renames.h` and
`native/wasm/libHarfBuzzSharp/wasm_symbol_renames.h` / `wasm_symbol_aliases.h` (the
`libHarfBuzzSharp` task depends on `generate-wasm-harfbuzz-symbol-renames` the same way
`libSkiaSharp` depends on `generate-wasm-symbol-renames`). To inspect just the harfbuzz output,
without running the full `libHarfBuzzSharp` build:

```bash
./scripts/Docker/wasm/build-local.sh 3.1.34 --wasmRenameThirdPartySymbols=true --target=generate-wasm-harfbuzz-symbol-renames
```

## 5. harfbuzz: hiding + aliasing instead of a plain rename

harfbuzz needs a different (heavier) mechanism than freetype2/libjpeg-turbo/zlib/libpng, for two
reasons specific to it:

1. **It's C++.** `harfbuzz-subset.cc` (compiled directly into the `HarfBuzzSharp` GN target —
   there is no separate `third_party/harfbuzz:harfbuzz` dependency in play here) `#include`s
   nearly the entire harfbuzz source tree as one translation unit. Its internal implementation is
   mostly C++-mangled, and a textual `#define original renamed` substitution — the mechanism used
   for the four C libraries above — can't touch a mangled name, because that name never appears
   as a token in the source; the mangling only happens at compile time.
2. **Its public API is also SkiaSharp.HarfBuzz's P/Invoke surface.** Unlike SkiaSharp, which
   insulates its callers behind its own `sk_*` C API (so renaming `FT_*`/`png_*`/etc. underneath
   it is invisible to consumers), the managed `HarfBuzzSharp` binding (`binding/HarfBuzzSharp/
   HarfBuzzApi*.cs`) P/Invokes harfbuzz's own `hb_*` names directly, with no wrapper layer. A
   plain rename would make the compiled archive stop exporting the exact names the managed layer
   looks up.

The fix combines three pieces, all gated behind `--wasmRenameThirdPartySymbols` like everything
else here:

- **Hide internal symbols instead of renaming them.** `visibility_hidden` (a `skia.gni` arg,
  overridden to `false` here previously) is left at Skia's own default (`true`) when renaming is
  enabled, adding `-fvisibility=hidden -fvisibility-inlines-hidden`. This removes harfbuzz's
  (mostly mangled) internals from the archive's global symbol table entirely — the only mechanism
  that actually reaches them — without needing to identify or rename a single one of them
  individually. This is safe: hidden visibility only affects what is visible to code *outside*
  the archive, not linking between `.o` files already inside it.
- **`wasm_hb_extern_visibility.h`** (static, hand-written, always force-included when renaming is
  enabled): harfbuzz's own public headers define `HB_EXTERN` as a plain `extern`
  (`hb-common.h`), so `-fvisibility=hidden` would hide harfbuzz's genuine public API right along
  with the internals. This overrides `HB_EXTERN` to `extern __attribute__((visibility("default")))`
  before any harfbuzz header is processed, keeping the public API exported.
- **`wasm_symbol_renames.h` + `wasm_symbol_aliases.h`** (both generated by
  `generate-wasm-harfbuzz-symbol-renames`, the same way as `libSkiaSharp`'s discovery task):
  with internals hidden, `nm` on a discovery build of the real `HarfBuzzSharp` target now reports
  *only* harfbuzz's genuine public API (plain, unmangled `hb_*` names) — exactly the symbols the
  textual rename mechanism can (and needs to) reach. Every one of them is renamed to
  `sksharp_hb_*`, same as the four C libraries. `GetHarfBuzzManagedApiNames` (`native/wasm/
  build.cake`) then parses `binding/HarfBuzzSharp/HarfBuzzApi.cs` and `HarfBuzzApi.generated.cs`
  for the exact `hb_*` names the managed binding P/Invokes (derived from the DllImport/
  LibraryImport declarations themselves, not hand-maintained), and `wasm_symbol_aliases.h`
  re-exports each one under its original name via `__attribute__((alias(...)))`, pointing at its
  renamed definition.
  `__attribute__((alias(...)))` requires its target to be *defined in the same translation
  unit* (Clang: "the function or variable specified in an alias must refer to its mangled name")
  — it cannot bridge a symbol compiled into a different `.o`, the way a first attempt at this
  (compiling the aliases as their own `.c` file and `ar`-merging the resulting object into the
  finished archive) assumed. It happens to work here because `harfbuzz-subset.cc` — the sole
  source file of the `HarfBuzzSharp` GN target — already amalgamates essentially all of harfbuzz
  into *one* translation unit: `wasm_symbol_aliases.h` is force-included into that same compile
  (via `HarfBuzzSharpGnArgs`, *before* `wasm_symbol_renames.h`, so its declarations keep their
  original, un-renamed names), and Clang resolves `alias` targets only once the whole translation
  unit has been parsed — by which point the real (renamed) definition has appeared later in the
  same file, via `harfbuzz-subset.cc`'s own `#include` chain. If a future harfbuzz version ever
  split `HarfBuzzSharp`'s sources across more than one `.cc` file, this would start failing loudly
  again (the same "alias must point to a defined variable or function" error) rather than silently
  producing a broken archive.
- **A handful of harfbuzz functions can't be renamed at all, and are deliberately excluded.**
  harfbuzz defines a few of its own public functions (eg. `hb_color_get_alpha`,
  `hb_glyph_info_get_glyph_flags`) *twice* in its own headers: once as a real prototype, and once
  as a performance-oriented function-like macro right after it (eg. `#define hb_color_get_alpha
  (color) ((color) & 0xFF)`), so most callers get it inlined. The `.cc` definition of the real,
  out-of-line function then wraps its own name in parens (`(hb_color_get_alpha) (...)`) so the
  macro doesn't fire *there*. That parenthesization also defeats our rename: by the time that
  definition is reached, the active macro for the name is harfbuzz's own (later, function-like)
  one, not our (earlier, object-like) rename, so the definition stays as the real name while the
  *prototype* earlier in the header — seen before harfbuzz's own macro redefinition — still gets
  renamed. The result is a declaration/definition mismatch that fails to compile under
  `-Wmissing-prototypes` (an error in this build). `GetHarfBuzzMacroShadowedNames`
  (`native/wasm/build.cake`) detects every such function generically, by scanning harfbuzz's own
  sources for that exact `(name) (` idiom — not a hardcoded list — and `generate-wasm-harfbuzz-
  symbol-renames` simply leaves them out of the rename table (and, since they were never renamed,
  out of the alias file too — aliasing to a `sksharp_*` name that doesn't exist would fail to
  link). Both sides then agree on the real name, exactly as in an unmodified build; these specific
  functions remain a small, harfbuzz-picked residual collision surface.

Net effect: harfbuzz's internal implementation is invisible to the linker (can't collide with
anything), harfbuzz's public API that the managed binding doesn't use is renamed and *not*
aliased back (still can't collide, and isn't needed under its original name), and the specific
subset the managed binding does call is renamed *and* aliased back to its original name (can't
collide with a host's own harfbuzz internally, still resolves correctly from C#).

**This has been verified to build `libHarfBuzzSharp.a` successfully** (against an actual emsdk/
GN/ninja toolchain, including the `-Wmissing-prototypes` fix in the previous bullet and the
same-translation-unit alias fix above — both were discovered and fixed against real build
failures, not anticipated in advance). **It has not been verified beyond that** — in particular,
that Unity's IL2CPP static-link/export step actually resolves each aliased `hb_*` export by name,
and that a real shaping call from C# works end-to-end. The environment this was iterated in has
no Unity to link against, so that step still needs to be confirmed independently.

## 6. Known limitations / open follow-ups

- **zlib's inclusion is largely redundant.** The vendored zlib fork already renames essentially everything (151 `#define`s in `chromeconf.h`, including internal helpers) to `Cr_z_*`. A host app's own *plain* zlib cannot collide with `Cr_z_*` names regardless of this mechanism; the extra `sksharp_Cr_z_*` layer only helps in the narrow case where the host also bundles a Chromium-forked zlib. Kept for completeness/uniformity across the four libraries, not because a real gap was found.
- **Discovery-build efficiency.** `generate-wasm-symbol-renames` runs a full `gn gen` once per library (4×, with identical args) instead of once for all four, and re-runs `nm` on every archive in the output directory multiple times (once per library while searching, then again to collect its final symbol set) instead of caching per-archive results. Correct, but does more work than necessary — not addressed as part of this change since it only affects the (opt-in, infrequent) build time, not correctness.
- **`out/wasm-symgen` is never cleaned** between runs, unlike the main `libSkiaSharp` task's merge directory. Unlikely to matter for a single clean checkout, but stale artifacts from a previous local run could in principle affect archive discovery.
- **Shell script duplication.** `scripts/Docker/wasm/build-local.sh` and `scripts/Docker/wasm/generate-symbol-renames-local.sh` share nearly all of their Docker build/run logic; only the final `dotnet cake` line differs. Not consolidated as part of this change.
- **Git tracking of the generated header is still undecided.** `native/wasm/libSkiaSharp/wasm_symbol_renames.h` (and, now, the two generated harfbuzz files) remain tracked files. Since they are rewritten by every build that enables renaming, local builds will show them as modified even when their content is materially unchanged. Whether to keep committing them (for human review of what changes after a DEPS bump) or move them to an untracked build-output path has not been decided.
- **The harfbuzz alias mechanism builds successfully, but is unverified past that.** `libHarfBuzzSharp.a` now compiles and links cleanly with a real emsdk/GN/ninja toolchain (see §5). Whether Unity's IL2CPP actually resolves the resulting `hb_*` exports by name at its own final link step, and whether a real shaping call then works end-to-end from C#, has not been exercised.
- **`wasm_symbol_aliases.h` depends on `HarfBuzzSharp` staying a single translation unit.** It works today because `harfbuzz-subset.cc` is the only source file in that GN target (`__attribute__((alias(...)))` requires same-TU resolution — see §5). If a future harfbuzz version splits that amalgamation across multiple `.cc` files, this would need reworking; it would fail loudly (a compile error) rather than silently produce a broken archive.
- **`-fvisibility=hidden` doesn't reach every kind of symbol.** C++ RTTI/`type_info` and vtable symbols for classes with virtual functions are typically emitted as `weak`/COMDAT globals regardless of `-fvisibility`, so a handful of these may still show up in `nm`'s output for harfbuzz's internal C++ classes. Weak duplicates don't produce a hard "duplicate symbol" linker error the way strong ones do (the linker just picks one), so this is lower-risk than the plain public-API case, but it hasn't been specifically audited.
- **HarfBuzzSharp's public-but-unused API is renamed, not hidden.** Public `hb_*` functions the managed binding doesn't call still end up as `sksharp_hb_*` in the final archive (renamed but not aliased back) rather than also being hidden — they're harmless where they are, just slightly wasteful to keep around; not addressed since it only affects binary size, not correctness.
