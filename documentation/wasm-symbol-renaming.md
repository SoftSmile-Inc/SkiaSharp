# WASM Third-Party Symbol Renaming

An opt-in build-time mechanism that avoids duplicate-symbol linker errors when the wasm `libSkiaSharp.a` static library is linked into a host application that statically links its own copies of freetype2, libjpeg-turbo, or libpng.

## TL;DR

- **Problem:** `libSkiaSharp.a` (wasm) and a host app's own freetype2/libjpeg-turbo/libpng export the same global C symbols. Statically linking both into one binary fails (or silently picks the wrong copy).
- **Solution:** an opt-in flag (`wasmRenameThirdPartySymbols`) renames every global symbol these four libraries export, via a generated `#define` header force-included into the whole wasm build. The header is regenerated automatically as part of the same build invocation that uses it, so it cannot go stale relative to the checkout, the feature flags, or the emscripten toolchain being built.
- **Off by default** — standard SkiaSharp wasm builds (and every wasm job in the current CI matrix) are unaffected.
- Relevant files: `native/wasm/build.cake`, `native/wasm/libSkiaSharp/wasm_symbol_renames.h` (generated), `scripts/Docker/wasm/build-local.sh`.

## 1. The problem being solved

Skia's wasm target statically links `freetype2`, `libjpeg-turbo`, and `libpng` into `libSkiaSharp.a` (`skia_use_system_freetype2/libjpeg_turbo/libpng = false` in `WasmSkiaGnArgs`, `native/wasm/build.cake`). These libraries export their normal C API as global symbols — `FT_Init_FreeType`, `jpeg_CreateDecompress`, `png_read_info`, and hundreds of internal helpers besides. None of them ship any built-in namespacing.

Skia's wasm target also statically links `zlib` (`skia_use_system_zlib = false`), but zlib is deliberately *not* covered by this mechanism: its vendored Chromium fork already prefixes its own public and internal symbols with `Cr_z_` (`third_party/externals/zlib/chromeconf.h`), which prevents collisions with a plain/vanilla host zlib (whose symbols are named `deflate`, `inflate`, etc., not `Cr_z_deflate`) on its own. Renaming would only additionally help in the narrow case of a host that *also* bundles a Chromium-forked zlib using the same `Cr_z_` convention — and that case was confirmed absent in the motivating production build (a real Unity WebGL project bundles plain zlib, not a Chromium fork) — so zlib was left out rather than carried as an inert fifth entry.

`libSkiaSharp.a` is designed to be statically linked into a host application — the motivating case is a Unity build — that may bundle its own copies of the same libraries. When both static libraries end up in the same final link, the linker sees two definitions of the same global symbol and either fails outright with a duplicate-symbol error, or (depending on link order) silently resolves to one copy, which can be an ABI-incompatible or unexpected version.

The requirement: make every third-party symbol `libSkiaSharp.a` exports unique to it, without touching SkiaSharp's own C API surface (`sk_*`), without requiring any change in the host application, and without hand-maintaining a list of symbols that will inevitably drift as freetype2/libjpeg-turbo/libpng are updated.

## 2. The solution

### 2.1 Mechanism

- Off by default; enabled with `--wasmRenameThirdPartySymbols=true` (or `WASM_RENAME_THIRDPARTY_SYMBOLS=true`) passed to the `native/wasm/build.cake` invocation.
- Every global symbol freetype2/libjpeg-turbo/libpng actually export is renamed to `sksharp_<original>`, via a generated C header (`native/wasm/libSkiaSharp/wasm_symbol_renames.h`) containing one `#define original sksharp_original` per symbol.
- That header is force-included into every translation unit of the wasm build (`-include <header>` added to `extra_cflags` in `WasmSkiaGnArgs`). Because the `-include` applies build-wide, both the third-party libraries' own definitions *and* every call site inside Skia's own code get rewritten to the same renamed identifier — the two sides can't fall out of sync.
- **Discovering "every global symbol"** is automated rather than hand-maintained: the `generate-wasm-symbol-renames` Cake task builds freetype2/libjpeg-turbo/libpng in isolation, into a dedicated `out/wasm-symgen` directory so the normal build output is untouched, then runs `nm --defined-only --extern-only` on the resulting `.a` archives to enumerate every symbol that would actually participate in a link-time collision. Each library's archive is located by searching for a symbol unique to it (`FT_Init_FreeType`, `jpeg_CreateDecompress`, `Cr_z_deflate`, `png_read_info`), since GN's `third_party()` template doesn't guarantee output archive filenames.
- This approach was chosen over libpng's own partial prefixing option (`PNG_PREFIX`) because it only covers documented public APIs — internal helpers that are still exported as globals (and can still collide) are missed. Discovering symbols via `nm` on the real compiled output is complete by construction and keeps all three libraries on one uniform mechanism.
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

## 4. Known limitations / open follow-ups

- **Discovery-build efficiency.** `generate-wasm-symbol-renames` runs a full `gn gen` once per library (4×, with identical args) instead of once for all four, and re-runs `nm` on every archive in the output directory multiple times (once per library while searching, then again to collect its final symbol set) instead of caching per-archive results. Correct, but does more work than necessary — not addressed as part of this change since it only affects the (opt-in, infrequent) build time, not correctness.
- **`out/wasm-symgen` is never cleaned** between runs, unlike the main `libSkiaSharp` task's merge directory. Unlikely to matter for a single clean checkout, but stale artifacts from a previous local run could in principle affect archive discovery.

