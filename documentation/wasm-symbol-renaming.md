# WASM Third-Party Symbol Renaming

An opt-in build-time mechanism that avoids duplicate-symbol linker errors when the wasm `libSkiaSharp.a`/`libHarfBuzzSharp.a` static libraries are linked into a host application that statically links its own copies of freetype2, libjpeg-turbo, libpng, or harfbuzz.

## TL;DR

- **Problem:** `libSkiaSharp.a`/`libHarfBuzzSharp.a` (wasm) and a host app's own freetype2/libjpeg-turbo/libpng/harfbuzz export the same global C symbols. Statically linking both into one binary fails (or silently picks the wrong copy).
- **Solution:** an opt-in flag (`wasmRenameThirdPartySymbols`) renames every global symbol these libraries export, via a generated `#define` header force-included into the whole wasm build. The header is regenerated automatically as part of the same build invocation that uses it, so it cannot go stale relative to the checkout, the feature flags, or the emscripten toolchain being built.
  - harfbuzz is renamed completely, C++ symbols included, and nothing is exported under an `hb_*` name. HarfBuzzSharp built for this archive calls the renamed `sksharp_hb_*` functions. See [§5](#5-harfbuzz-full-rename).
- **Off by default** — standard SkiaSharp wasm builds (and every wasm job in the current CI matrix) are unaffected.
- Relevant files: `native/wasm/build.cake`, `native/wasm/libSkiaSharp/wasm_symbol_renames.h` (generated), `native/wasm/libHarfBuzzSharp/wasm_symbol_renames.h` and `wasm_cxx_renames.h` (generated), `native/wasm/libHarfBuzzSharp/wasm_hb_extern_visibility.h`, `scripts/Docker/wasm/build-local.sh`, `.github/scripts/check-wasm-symbols.sh`.

## 1. The problem being solved

Skia's wasm target statically links `freetype2`, `libjpeg-turbo`, and `libpng` into `libSkiaSharp.a` (`skia_use_system_freetype2/libjpeg_turbo/libpng = false` in `WasmSkiaGnArgs`, `native/wasm/build.cake`). These libraries export their normal C API as global symbols — `FT_Init_FreeType`, `jpeg_CreateDecompress`, `png_read_info`, and hundreds of internal helpers besides. None of them ship any built-in namespacing.

Skia's wasm target also statically links `zlib` (`skia_use_system_zlib = false`), but zlib is deliberately *not* covered by this mechanism: its vendored Chromium fork already prefixes its own public and internal symbols with `Cr_z_` (apart from three cpu-feature globals no Unity archive defines) (`third_party/externals/zlib/chromeconf.h`), which prevents collisions with a plain/vanilla host zlib (whose symbols are named `deflate`, `inflate`, etc., not `Cr_z_deflate`) on its own. Renaming would only additionally help in the narrow case of a host that *also* bundles a Chromium-forked zlib using the same `Cr_z_` convention — and that case was confirmed absent in the motivating production build (a real Unity WebGL project bundles plain zlib, not a Chromium fork) — so zlib was left out rather than carried as an inert fifth entry.

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

## 4. Usage: harfbuzz on its own

```bash
./scripts/Docker/wasm/build-local.sh 3.1.34 --wasmRenameThirdPartySymbols=true --target=externals-wasm
```

already regenerates `native/wasm/libSkiaSharp/wasm_symbol_renames.h` and both harfbuzz headers (the `libHarfBuzzSharp` task depends on `generate-wasm-harfbuzz-symbol-renames` the same way `libSkiaSharp` depends on `generate-wasm-symbol-renames`). To inspect just the harfbuzz output, without running the full `libHarfBuzzSharp` build:

```bash
./scripts/Docker/wasm/build-local.sh 3.1.34 --wasmRenameThirdPartySymbols=true --target=generate-wasm-harfbuzz-symbol-renames
```

## 5. harfbuzz: full rename

harfbuzz needs more than the three C libraries above:

1. **It's C++.** `harfbuzz-subset.cc`, the only source file of the `HarfBuzzSharp` GN target, `#include`s nearly all of harfbuzz as one translation unit, and most of its symbols are C++-mangled. A `#define` can't match a mangled name, only a source identifier.
2. **Its public API is HarfBuzzSharp's P/Invoke surface.** The managed binding calls `hb_*` directly, with no wrapper layer, so renaming the API means the binding has to call the new names.

Hidden visibility doesn't help: in a static wasm link two strong definitions of one name fail with `duplicate symbol` whatever their visibility, and weak ones (template instantiations, inline functions) silently merge with the host's copy. So `generate-wasm-harfbuzz-symbol-renames` renames every symbol a discovery build defines, at the source level:

- **`wasm_symbol_renames.h`** — `#define hb_x sksharp_hb_x` for every plain (C-linkage) symbol. A few functions harfbuzz shadows with its own function-like macro (eg. `hb_color_get_alpha`, defined as `(hb_color_get_alpha) (...)` so that macro doesn't fire) get `#pragma redefine_extname` instead, which renames the symbol without touching the token. `GetHarfBuzzMacroShadowedNames` finds them by scanning harfbuzz's sources for that idiom.
- **`wasm_cxx_renames.h`** — a `#define` for the outermost name of every mangled symbol: namespaces (`OT`, `AAT`, `CFF`, `graph`), global classes and functions (`hb_buffer_t`, `hb_aat_layout_compile_map`). Renaming the outer name renames everything nested in it, weak instantiations included. `GetTopLevelCxxName` parses the Itanium mangling; names under `::std` are left alone (any harfbuzz type in their template arguments is renamed anyway).

The generator fails the build on a mangling shape it doesn't understand, on a name both headers would rename, and on a function the binding calls that has no definition to rename. Nothing is patched in the vendored harfbuzz sources.

The managed half: the binding generator writes `EntryPoint = HARFBUZZ_ENTRY_POINT_PREFIX + "hb_x"` on every P/Invoke, and the constant is `"sksharp_"` when HarfBuzzSharp is built with `SkiaSharpHarfBuzzRenamedSymbols=true`, the default for the Unity WebGL `__Internal` variant (see [unity-webgl-internal-pinvoke.md](unity-webgl-internal-pinvoke.md)). The archive and that assembly go together: a binding with plain `hb_*` names doesn't use the renamed archive at all (in Unity it silently binds to Unity's own harfbuzz), and one with `sksharp_hb_*` names doesn't link without it. Consumers of a regular wasm build need an archive built without the flag.

`-fvisibility=hidden` and `wasm_hb_extern_visibility.h` (which keeps the `HB_EXTERN` public API exported under hidden visibility) are still applied when renaming is on; the renaming is what keeps the symbols apart.

In a Unity 6000.3.8f1 WebGL player this archive shares no defined name with Unity's harfbuzz (8.0.1) or any other Unity wasm module. Unity's text engine keeps using its harfbuzz and HarfBuzzSharp uses ours (8.3.1), including functions Unity's copy lacks (`hb_buffer_serialize*`). The cost is a second harfbuzz in the wasm module (about +200 KB brotli-compressed in the first Unity build).

`.github/scripts/check-wasm-symbols.sh` checks each CI build: every P/Invoked name is defined as `sksharp_<name>`, every defined global symbol contains `sksharp_`, and the archive references no harfbuzz name it doesn't define itself.

## 6. Approaches rejected

- **Hidden visibility plus aliases** (the first design: hide the internals, rename the public API and alias the P/Invoked part back to `hb_*`). Against Unity's harfbuzz it gave 436 duplicate symbols: 125 C++ internals and 311 plain `hb_*` aliases. Renaming only one of the two halves leaves the other.
- **`llvm-objcopy --redefine-sym`** after compilation. The wasm backend of `llvm-objcopy` in the pinned emsdk (3.1.34, 3.1.39) doesn't edit the symbol table.
- **Wrapping the translation unit in a namespace** (`namespace sksharp_hb { #include "harfbuzz-subset.cc" }`). `hb-cplusplus.hh` specializes `std::hash`, which has to live in the real `::std`; inside the wrapper it creates `sksharp_hb::std` and breaks other `std::` references. Fixing that means patching vendored harfbuzz.
- **`--allow-multiple-definition`**. Unity's `wasm-ld` (LLD 17) doesn't accept it.

## 7. Known limitations

- **Discovery-build efficiency.** `generate-wasm-symbol-renames` runs `gn gen` once per library instead of once for all, and re-runs `nm` on the same archives several times. Correct, just slower than necessary; only affects the opt-in build.
- **`out/wasm-symgen` is never cleaned** between runs, unlike the main `libSkiaSharp` task's merge directory. Stale artifacts from a previous local run could in principle affect archive discovery.
- **The C++ `#define`s are textual**, so they also apply to the same identifier in headers included later (eg. `graph` in libc++'s `<__locale>`). No problem has been seen; worth remembering if a harfbuzz update adds an outer name the standard library also uses.
- **HarfBuzzSharp's public-but-unused API is renamed, not hidden.** Harmless, only affects binary size.
