# WASM Third-Party Symbol Renaming

An opt-in build-time mechanism that avoids duplicate-symbol linker errors when the wasm `libSkiaSharp.a`/`libHarfBuzzSharp.a` static libraries are linked into a host application that statically links its own copies of freetype2, libjpeg-turbo, libpng, or harfbuzz.

## TL;DR

- **Problem:** `libSkiaSharp.a`/`libHarfBuzzSharp.a` (wasm) and a host app's own freetype2/libjpeg-turbo/libpng/harfbuzz export the same global C symbols. Statically linking both into one binary fails (or silently picks the wrong copy).
- **Solution:** an opt-in flag (`wasmRenameThirdPartySymbols`) renames every global symbol these libraries export, via a generated `#define` header force-included into the whole wasm build. The header is regenerated automatically as part of the same build invocation that uses it, so it cannot go stale relative to the checkout, the feature flags, or the emscripten toolchain being built.
  - harfbuzz needs a second mechanism on top of this, because it's C++ (mostly unreachable by textual renaming) and because its public API — unlike freetype2/libjpeg-turbo/libpng — is also what the managed `HarfBuzzSharp` binding P/Invokes directly. See [§5](#5-harfbuzz-hiding--aliasing-instead-of-a-plain-rename).
  - **Known gap, confirmed in production:** harfbuzz's C++ internals (template instantiations, constructors/destructors, other vague-linkage symbols) are *not* actually renamed or hidden by this mechanism, despite §5's original claim to the contrary. This has been reproduced against a real Unity WebGL host and traced to a root cause with no clean fix found yet. See [§6](#6-known-gap-harfbuzzs-c-internals-are-not-actually-protected).
- **Off by default** — standard SkiaSharp wasm builds (and every wasm job in the current CI matrix) are unaffected.
- Relevant files: `native/wasm/build.cake`, `native/wasm/libSkiaSharp/wasm_symbol_renames.h` (generated), `native/wasm/libHarfBuzzSharp/wasm_symbol_renames.h` (generated), `native/wasm/libHarfBuzzSharp/wasm_hb_extern_visibility.h`, `native/wasm/libHarfBuzzSharp/wasm_symbol_aliases.h` (generated), `scripts/Docker/wasm/build-local.sh`.

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
- **Discovering "every global symbol"** is automated rather than hand-maintained: the `generate-wasm-symbol-renames` Cake task builds freetype2/libjpeg-turbo/libpng in isolation, into a dedicated `out/wasm-symgen` directory so the normal build output is untouched, then runs `nm --defined-only --extern-only` on the resulting `.a` archives to enumerate every symbol that would actually participate in a link-time collision. Each library's archive is located by searching for a symbol unique to it (`FT_Init_FreeType`, `jpeg_CreateDecompress`, `png_read_info`), since GN's `third_party()` template doesn't guarantee output archive filenames.
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

already regenerates both `native/wasm/libSkiaSharp/wasm_symbol_renames.h` and
`native/wasm/libHarfBuzzSharp/wasm_symbol_renames.h` / `wasm_symbol_aliases.h` (the
`libHarfBuzzSharp` task depends on `generate-wasm-harfbuzz-symbol-renames` the same way
`libSkiaSharp` depends on `generate-wasm-symbol-renames`). To inspect just the harfbuzz output,
without running the full `libHarfBuzzSharp` build:

```bash
./scripts/Docker/wasm/build-local.sh 3.1.34 --wasmRenameThirdPartySymbols=true --target=generate-wasm-harfbuzz-symbol-renames
```

## 5. harfbuzz: hiding + aliasing instead of a plain rename

harfbuzz needs a different (heavier) mechanism than freetype2/libjpeg-turbo/libpng, for two
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

- **Hide internal symbols instead of renaming them (partially works — see [§6](#6-known-gap-harfbuzzs-c-internals-are-not-actually-protected)).**
  `visibility_hidden` (a `skia.gni` arg, overridden to `false` here previously) is left at Skia's
  own default (`true`) when renaming is enabled, adding `-fvisibility=hidden
  -fvisibility-inlines-hidden`. The original intent was for this to remove harfbuzz's (mostly
  mangled) internals from the archive's global symbol table entirely, without needing to identify
  or rename a single one of them individually. **This has been verified, empirically, to only be
  true for plain C-linkage internal symbols** (e.g. `_hb_options`, `_hb_ot_shaper_arabic` — these
  do get hidden/renamed correctly). **It is not true for C++ vague-linkage symbols** — template
  instantiations, constructors/destructors, and similar (e.g. `hb_vector_t<...>::resize`,
  `AAT::hb_aat_apply_context_t::~hb_aat_apply_context_t()`) remain defined and externally visible
  in the compiled archive with their original, un-renamed mangled names, `-fvisibility=hidden`
  notwithstanding. See [§6](#6-known-gap-harfbuzzs-c-internals-are-not-actually-protected) for the
  evidence and why this happens.
- **`wasm_hb_extern_visibility.h`** (static, hand-written, always force-included when renaming is
  enabled): harfbuzz's own public headers define `HB_EXTERN` as a plain `extern`
  (`hb-common.h`), so `-fvisibility=hidden` would hide harfbuzz's genuine public API right along
  with the internals. This overrides `HB_EXTERN` to `extern __attribute__((visibility("default")))`
  before any harfbuzz header is processed, keeping the public API exported.
- **`wasm_symbol_renames.h` + `wasm_symbol_aliases.h`** (both generated by
  `generate-wasm-harfbuzz-symbol-renames`, the same way as `libSkiaSharp`'s discovery task):
  the original intent was that, with internals hidden, `nm` on a discovery build of the real
  `HarfBuzzSharp` target would report *only* harfbuzz's genuine public API (plain, unmangled
  `hb_*` names) — exactly the symbols the textual rename mechanism can (and needs to) reach. **In
  practice the generated header (2738 `#define`s as of this writing) also contains ~2194 mangled
  C++ (`_Z...`) entries** — these are dead weight: a `#define` can never match a mangled token in
  source text (see point 1 above), so these lines have no effect on the compiled output, they
  just make the header larger. The ~505 plain-name entries (the genuine public API, plus
  non-mangled internal helpers like `_hb_NullPool`) are the ones the mechanism actually renames.
  Every one of the genuine public API names is renamed to
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

Net effect (**revised — see [§6](#6-known-gap-harfbuzzs-c-internals-are-not-actually-protected)
for what changed**): harfbuzz's plain-C-linkage internal implementation is invisible to the
linker (can't collide with anything); harfbuzz's public API that the managed binding doesn't use
is renamed and *not* aliased back (still can't collide, and isn't needed under its original
name); the specific subset the managed binding does call is renamed *and* aliased back to its
original name (can't collide with a host's own harfbuzz internally, still resolves correctly from
C#). **Harfbuzz's C++ internals (templates, constructors/destructors, and similar vague-linkage
symbols) are the exception to all of this — they remain under their original mangled names,
unrenamed and unhidden, and are a confirmed, reproducible collision surface against a real host
harfbuzz.** This is not a corner case affecting "a handful" of symbols the way the
macro-shadowed-functions bullet above is — it affects on the order of a thousand internal C++
symbols per build (see §6).

**This has been verified to build `libHarfBuzzSharp.a` successfully** (against an actual emsdk/
GN/ninja toolchain, including the `-Wmissing-prototypes` fix in the previous bullet and the
same-translation-unit alias fix above — both were discovered and fixed against real build
failures, not anticipated in advance). **Unity/IL2CPP integration has since been verified beyond
that, with a materially different result than hoped:** the aliased `hb_*` P/Invoke surface does
resolve correctly from C# end-to-end. But the C++-internals gap above was reproduced against a
real Unity 6000.3.8f1 WebGL project — see §6 for the full evidence trail, including an exact
symbol-name match against a real prior `wasm-ld: error: duplicate symbol` failure log from that
project.

## 6. Known gap: harfbuzz's C++ internals are not actually protected

This section documents a confirmed, reproduced-in-production gap in the harfbuzz mechanism from
[§5](#5-harfbuzz-hiding--aliasing-instead-of-a-plain-rename), the evidence behind it, three
approaches that were investigated to close it, and three candidate paths forward. None of the
investigated approaches produced a clean fix; this is left as the primary open problem for future
work on this feature.

### 6.1 The evidence

- **Toy reproduction.** Compiling a plain C function with `-fvisibility=hidden` and inspecting it
  with `nm --defined-only --extern-only` shows it still listed as a global (`T`) symbol — hidden
  visibility, in this LLVM/wasm target, does not remove the symbol from what `nm` reports the way
  it's assumed to in §5. A forced-collision test (two static archives defining the same symbol,
  one built with `-fvisibility=hidden`, linked together via `-Wl,--whole-archive` so both
  definitions are pulled in regardless of link order) produces `wasm-ld: error: duplicate symbol`
  *regardless* of the hidden-visibility flag.
- **The generated header itself.** `native/wasm/libHarfBuzzSharp/wasm_symbol_renames.h` (committed
  in this checkout) contains 2738 `#define`s, of which ~2194 are mangled C++ names (`_Z...`).
  These are inert (see the `wasm_symbol_renames.h` bullet in §5) — the "hidden, so only public API
  needs renaming" assumption they were generated under does not hold.
- **A real, deployed Unity project.** Cross-referencing the actual `WebGLSupport_UnityPlayer.
  TextRenderingModule_Dynamic.a` shipped in a Unity 6000.3.8f1 Editor install (a *core engine
  module*, unrelated to TextMesh Pro or UI Toolkit — it bundles its own freetype2, ICU, and
  harfbuzz, via `harfbuzz_5sk4y.o` / `hb-icu_5sk4y.o`) against the *original* (unrenamed) symbol
  names in the generated header found **1532 exact name matches**, of which **1027 are mangled
  C++ names** (the unprotected class) and 505 are plain names (correctly protected by the
  existing rename mechanism). One of those 1027 —
  `_ZN3AAT22hb_aat_apply_context_t14set_ankr_tableEPKNS_4ankrE` — was confirmed present, byte for
  byte identical, in *both* Unity's archive and a real, current, renaming-enabled
  `libHarfBuzzSharp.a`, and matches a real `wasm-ld: error: duplicate symbol` this project hit
  before enabling renaming (that failure log also named
  `AAT::hb_aat_apply_context_t::~hb_aat_apply_context_t()` and `_hb_NullPool`, the latter a
  plain-name symbol that the existing mechanism does correctly rename).
- **Why the linker isn't currently erroring on this in that project's builds.** A rebuild after
  enabling renaming produced no duplicate-symbol errors — but inspecting the resulting `.wasm`
  (`llvm-objdump -h` shows its `name` custom section; Unity's `Debug Symbols: external` build
  setting did not, in practice, strip it out) shows: (a) Unity's TextRenderingModule/ICU/harfbuzz
  *is* linked in (proven by ICU-specific and `hb-icu`-bridge-specific symbol names that only exist
  in Unity's archive), (b) hundreds of harfbuzz-internal C++ symbols from `libHarfBuzzSharp.a`
  *are* present, unrenamed, exactly as the gap above predicts, but (c) the *specific* colliding
  names from the original failure (`_hb_NullPool`, `set_ankr_table`) are absent from the final
  binary in any form. The most likely explanation is ordinary dead-code elimination
  (`--gc-sections` / binaryen DCE): AAT (`Apple Advanced Typography`, a legacy Apple font-format
  code path) is reachable from neither side's actually-used code in that project, so it gets
  pruned before the duplicate-symbol check ever sees it — **not** because the rename/hide
  mechanism protects it. This is fragile, not fixed: a font that exercises AAT, a harfbuzz version
  bump that changes what's reachable, or a build with less aggressive dead-code elimination could
  make the exact same link error reappear with no code change on the consuming project's side.

### 6.2 Approaches investigated and rejected

1. **Post-compile binary renaming (`llvm-objcopy --redefine-sym` / `--prefix-symbols`).** Would
   avoid the textual-rename/mangling problem entirely by renaming already-compiled `.o` symbols.
   Tested directly against the wasm backend of `llvm-objcopy` shipped in both the `3.1.34` and
   `3.1.39` emsdk images (both `LLVM version 17.0.0git`): fails with `error: only flags for
   section dumping, removal, and addition are supported` — this LLVM version's wasm object-copy
   support does not implement symbol-table edits at all, only section-level operations. Rejected —
   not available in the current toolchain, and upgrading the pinned emsdk version didn't change
   the LLVM version bundled with it.
2. **Drop textual renaming for the four C libraries, rely on `-fvisibility=hidden` alone.** Would
   simplify the mechanism considerably if it worked. Rejected by the same forced-collision test as
   in §6.1: hidden visibility does not stop `wasm-ld` from hard-erroring on a genuine duplicate
   definition in this toolchain, so this is not a viable replacement for the four C libraries
   either — the textual rename remains necessary for them.
3. **Wrap harfbuzz's translation unit in a uniquely-named C++ namespace**
   (`namespace sksharp_hb { #include "harfbuzz-subset.cc" }`), instead of renaming/hiding
   individual symbols. In theory this is a clean fix: a C++ namespace is part of a symbol's
   mangled name, so it would uniquely re-mangle every C++ internal (templates,
   constructors/destructors included) in one step, while `extern "C"` functions (harfbuzz's public
   `hb_*` API, via `HB_EXTERN`) are unaffected by enclosing namespaces by design — so the existing
   alias mechanism for the P/Invoke'd subset would keep working unchanged, and
   `-fvisibility=hidden`/`wasm_hb_extern_visibility.h` could potentially be dropped entirely for
   harfbuzz. **Tested against the real GN/ninja build** (`out/wasm-symgen-harfbuzz`, the same
   directory the real discovery build uses) and it does not work cleanly:
   - First failure: `config-override.h`'s `#include <mutex>`, first processed *inside* the wrapper
     namespace, causes libc++'s `using ::size_t _LIBCPP_USING_IF_EXISTS;` (`<cstddef>`) to be
     declared inside the wrapper namespace instead of at global scope, breaking later standard
     headers that expect `::size_t` to already be visible. Worked around by pre-including a
     handful of standard headers (`<mutex>`, `<atomic>`, `<cstddef>`, `<type_traits>`, etc.)
     *before* opening the namespace.
   - Second, harder failure: `hb-cplusplus.hh` (transitively included; not a direct include of
     `harfbuzz-subset.cc`, so an earlier check of direct includes missed it) reopens
     `namespace std { template<> struct hash<hb::shared_ptr<T>> { ... }; }` to specialize
     `std::hash`. C++ requires a specialization of a `std` template to be declared in a scope that
     *is* `::std` — nested inside another namespace, this instead declares a new, unrelated
     `sksharp_hb::std` namespace, which then shadows the real `::std` for every subsequent
     unqualified `std::` reference in the same translation unit (`hb-meta.hh`'s `std::decay`,
     `std::is_const`, `std::forward`, etc. all fail to resolve). No amount of pre-including
     headers fixes this — it is a structural conflict between "wrap the whole translation unit"
     and harfbuzz's own use of the real `::std` namespace. Making it work would require patching
     `hb-cplusplus.hh` itself (e.g. gating that specialization behind a macro), which is exactly
     the kind of hand-maintained, DEPS-bump-fragile patch the rest of this mechanism was designed
     to avoid (see [§1](#1-the-problem-being-solved)).

### 6.3 Candidate paths forward

None of these have been implemented; each is a legitimate direction depending on priorities:

1. **Patch `hb-cplusplus.hh` to make the `std::hash` specialization conditional**, e.g. behind a
   new macro (only defined for the normal, non-wasm-renaming build), then retry the namespace-wrap
   approach from §6.2. Closes the gap completely and would let `-fvisibility=hidden` /
   `wasm_hb_extern_visibility.h` be removed for harfbuzz, net-simplifying the mechanism — but adds
   a small upstream-diverging patch to vendored harfbuzz source that has to be re-verified (and
   possibly re-adjusted) after every harfbuzz DEPS bump.
2. **Accept the residual risk and document it accurately** (this section is a first step in that
   direction). Costs nothing to implement, but leaves the gap live — collisions remain possible
   and, per §6.1, are currently avoided by dead-code elimination rather than by design, which is a
   fragile, unverified safety net that could silently stop applying after an unrelated change.
3. **Add a build-time sanity check.** After `generate-wasm-harfbuzz-symbol-renames` (or after the
   real `libHarfBuzzSharp` build) runs `nm --defined-only --extern-only` on the resulting archive,
   fail loudly (or at least warn) if any mangled (`_Z...`) symbol is found without a `sksharp_`
   prefix. This doesn't fix the underlying gap, but turns a silent, DEPS-bump-fragile risk into a
   build-time signal instead of a surprise `duplicate symbol` error at a consuming project's own
   link time — cheap to add, and complements either of the other two paths.

## 7. Known limitations / open follow-ups

- **zlib has been removed from this mechanism.** It was previously included alongside freetype2/libjpeg-turbo/libpng ("kept for completeness/uniformity, not because a real gap was found"), but the vendored zlib fork already renames essentially everything (151 `#define`s in `chromeconf.h`, including internal helpers) to `Cr_z_*`, which prevents collisions with a host app's own *plain* zlib on its own — the extra `sksharp_Cr_z_*` layer would only have helped in the narrow case where the host also bundles a Chromium-forked zlib. That was confirmed empirically to be inert against the motivating production build (a real Unity WebGL project bundles plain `zlib`/`inflate`, not a Chromium fork — zero `Cr_z_*` names found), so it was dropped: `generate-wasm-symbol-renames` (`native/wasm/build.cake`) no longer builds or discovers zlib symbols, and `wasm_symbol_renames.h` no longer contains `Cr_z_*` renames. See [§1](#1-the-problem-being-solved).
- **Discovery-build efficiency.** `generate-wasm-symbol-renames` runs a full `gn gen` once per library (4×, with identical args) instead of once for all four, and re-runs `nm` on every archive in the output directory multiple times (once per library while searching, then again to collect its final symbol set) instead of caching per-archive results. Correct, but does more work than necessary — not addressed as part of this change since it only affects the (opt-in, infrequent) build time, not correctness.
- **`out/wasm-symgen` is never cleaned** between runs, unlike the main `libSkiaSharp` task's merge directory. Unlikely to matter for a single clean checkout, but stale artifacts from a previous local run could in principle affect archive discovery.
- **The harfbuzz alias mechanism's P/Invoke surface has since been verified against a real Unity project.** `libHarfBuzzSharp.a` compiles and links cleanly with a real emsdk/GN/ninja toolchain (see §5), and the aliased `hb_*` exports do resolve correctly through Unity's IL2CPP WebGL build and get called successfully from C#. **What remains unverified/broken is the C++-internals gap** — see [§6](#6-known-gap-harfbuzzs-c-internals-are-not-actually-protected) for the full, since-confirmed picture; it is materially worse than "unverified," it's a confirmed live collision surface currently masked by dead-code elimination rather than closed.
- **`wasm_symbol_aliases.h` depends on `HarfBuzzSharp` staying a single translation unit.** It works today because `harfbuzz-subset.cc` is the only source file in that GN target (`__attribute__((alias(...)))` requires same-TU resolution — see §5). If a future harfbuzz version splits that amalgamation across multiple `.cc` files, this would need reworking; it would fail loudly (a compile error) rather than silently produce a broken archive.
- **`-fvisibility=hidden` doesn't reach every kind of symbol — see [§6](#6-known-gap-harfbuzzs-c-internals-are-not-actually-protected).** This was originally logged here as an unaudited, "lower-risk" theoretical gap limited to RTTI/vtable weak symbols. It has since been audited: the gap is broader (ordinary template instantiations and constructors/destructors, not just RTTI/vtables), includes *strong*-linkage symbols that do produce hard duplicate-symbol errors (not just weak ones the linker silently resolves), and has been reproduced against a real host project.
- **HarfBuzzSharp's public-but-unused API is renamed, not hidden.** Public `hb_*` functions the managed binding doesn't call still end up as `sksharp_hb_*` in the final archive (renamed but not aliased back) rather than also being hidden — they're harmless where they are, just slightly wasteful to keep around; not addressed since it only affects binary size, not correctness.
