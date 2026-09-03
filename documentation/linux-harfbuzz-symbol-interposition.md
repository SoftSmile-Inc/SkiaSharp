# Linux: HarfBuzz Symbol Interposition

Why a host process with its own bundled harfbuzz (e.g. Unity Standalone Linux Player, which
ships its own `libharfbuzz.so` for its text engine) can crash when it also loads
`libHarfBuzzSharp.so`, and the linker flag that fixes it.

## TL;DR

- **Problem:** `libHarfBuzzSharp.so` compiles all of harfbuzz in statically and exports every
  `hb_*` symbol as a normal, globally-bound dynamic symbol (required for P/Invoke). If a host
  process has *another* library exporting the same `hb_*` names already loaded (any load order),
  the dynamic linker can resolve `libHarfBuzzSharp.so`'s own internal `hb_*` → `hb_*` calls to
  that other library's (ABI-incompatible) definitions instead of its own — corrupting internal
  state or segfaulting.
- **Fix:** link `libHarfBuzzSharp.so` with `-Wl,-Bsymbolic-functions` (`native/linux/build.cake`,
  `libHarfBuzzSharp` task). This is the same flag harfbuzz's own upstream CMake/meson builds
  apply by default on every Unix target — SkiaSharp loses it because it compiles harfbuzz
  directly via GN instead of going through harfbuzz's own build system. The flag makes the
  linker bind the library's *own* internal function calls directly to its own definitions,
  regardless of what else is loaded or in what order. It doesn't change the exported symbol set,
  so P/Invoke (which resolves `libHarfBuzzSharp.so`'s handle-specific symbols via `dlsym`, not
  through the global scope) is unaffected.
- **Not needed on macOS.** `-Bsymbolic-functions` is a GNU ld/gold flag with no `ld64`
  equivalent; macOS's two-level namespace already binds a dylib's intra-image calls at
  static-link time, so this specific interposition mechanism doesn't arise there. See
  [§4](#4-macos-not-affected).
- Relevant files: `native/linux/build.cake`, `native/linux/libHarfBuzzSharp/libHarfBuzzSharp.map`.

## 1. The problem being solved

On Linux, `libHarfBuzzSharp.so` is built by compiling harfbuzz's amalgamated source
(`third_party/externals/harfbuzz/src/harfbuzz-subset.cc`) directly into the `HarfBuzzSharp` GN
target (`externals/skia/BUILD.gn`) — there's no separate `libharfbuzz.so` dependency. The only
symbol-scoping mechanism is a linker version script,
`native/linux/libHarfBuzzSharp/libHarfBuzzSharp.map`:

```
libHarfBuzzSharp {
    global:
        hb_*;
    local:
        *;
};
```

This correctly hides internal helpers, but every `hb_*` symbol — including ones only ever called
*internally*, not P/Invoked — stays exported with normal, preemptible binding. In a process that
also has some other library exporting the same `hb_*` names in its global symbol scope (for
example, Unity bundles its own `libharfbuzz.so` for its own text rendering on Linux Standalone
builds), the dynamic linker's lazy PLT/GOT resolution can bind `libHarfBuzzSharp.so`'s own
internal calls to that other library's definitions — whichever library happened to be loaded
first "wins" for every caller, including the wrong one. Since the two copies of harfbuzz are
rarely ABI-compatible (different versions, different build configs), this leads to memory
corruption or a segfault, and the symptom is intermittent / load-order-dependent, which makes it
easy to mistake for something else.

A previous workaround for this was to `dlopen()` `libHarfBuzzSharp.so` from application code
with `RTLD_DEEPBIND`, forcing that one library's own symbol lookups to prefer its own definitions
over the global scope. It works, but it's an app-side hack: glibc-specific, must run before
anything touches HarfBuzz, and only protects the specific `dlopen()` call site it's added to.

## 2. The fix

`native/linux/build.cake`, `libHarfBuzzSharp` task, `extra_ldflags`:

```diff
-extra_ldflags=[ '-static-libstdc++', '-static-libgcc', '-Wl,--version-script={map}' ]
+extra_ldflags=[ '-static-libstdc++', '-static-libgcc', '-Wl,--version-script={map}', '-Wl,-Bsymbolic-functions' ]
```

`-Bsymbolic-functions` tells the linker to resolve calls to a shared object's *own* global
function symbols directly, at link time, instead of leaving them for the dynamic linker to
resolve lazily against the process-wide global scope at load time. It only affects function
symbols (not data), and it's exactly what harfbuzz's own upstream build applies by default for
this reason:

```cmake
# externals/skia/third_party/externals/harfbuzz/CMakeLists.txt
if (UNIX OR MINGW OR VITA)
  CHECK_CXX_COMPILER_FLAG(-Bsymbolic-functions CXX_SUPPORTS_FLAG_BSYMB_FUNCS)
  if (CXX_SUPPORTS_FLAG_BSYMB_FUNCS)
    link_libraries(-Bsymbolic-functions)
  endif ()
```

SkiaSharp never picks this up because it bypasses harfbuzz's own CMake/meson build entirely and
compiles `harfbuzz-subset.cc` straight into the `HarfBuzzSharp` GN target — this is a gap from
that, not a deliberate choice to omit it.

The exported symbol set is untouched: `hb_*` stays global (per the `.map` file) so P/Invoke keeps
working exactly as before. The flag only affects how the library resolves *its own* references to
those symbols internally.

## 3. Verification

Confirmed both statically and with a live reproduction.

**PLT relocation count**, comparing the previously shipped `.so` against one rebuilt with the
flag:

```bash
readelf -r --wide libHarfBuzzSharp.so | grep JUMP_SLOT | grep -o 'hb_[a-zA-Z0-9_]*' | sort -u | wc -l
```

| | `hb_*` PLT entries |
|---|---|
| before (no `-Bsymbolic-functions`) | 59 |
| after | 0 |

The 49 PLT entries that remain in the patched build are all genuine external libc/libm symbols
(`malloc`, `memcpy`, `pthread_mutex_lock`, …) — none are `hb_*`. Every internal `hb_*` → `hb_*`
call that used to require dynamic (and therefore interposable) resolution is now resolved
directly at link time.

**Live reproduction** — a decoy library exporting `hb_shape_plan_create2` (a function
`hb_shape_plan_create_cached2` calls internally) is loaded globally first, simulating a host's
own bundled harfbuzz; then `libHarfBuzzSharp.so` is loaded normally (no `RTLD_DEEPBIND`) and its
`hb_shape_plan_create_cached2` is called via `dlsym`, matching how .NET's P/Invoke resolves it:

- Against the unpatched `.so`: the decoy's `hb_shape_plan_create2` runs instead of
  `libHarfBuzzSharp.so`'s own — confirmed the interposition is real.
- Against the patched `.so`: the decoy is never called; execution stays inside
  `libHarfBuzzSharp.so`'s own `hb_shape_plan_create2` (confirmed via `gdb` backtrace).

## 4. macOS: not affected

The equivalent macOS build (`native/macos/build.cake`, plain Xcode project, no GN) has no
analogous flag to add:

- `-Bsymbolic-functions` is GNU ld/gold-specific; Apple's `ld64` doesn't support it (harfbuzz's
  own CMake/meson probe for support and silently skip it on macOS for exactly this reason).
- macOS's default two-level namespace binds a dylib's intra-image calls directly at static-link
  time — `harfbuzz-subset.cc` is compiled straight into the one dylib, not linked against a
  separate `libharfbuzz.dylib` — so the flat-namespace/first-loaded-wins mechanism behind the
  Linux bug largely doesn't apply on Mach-O for this build shape.

## 5. Building

Rebuild just this target (fast — a single amalgamated `.cc` file, not the full Skia build):

```bash
dotnet tool restore
CC=clang-13 CXX=clang++-13 dotnet cake native/linux/build.cake --target=libHarfBuzzSharp --buildarch=x64
```

Or via the Linux Docker image used by CI (`scripts/Docker/debian/amd64`):

```bash
cd scripts/Docker/debian/amd64
docker build --tag skiasharp-linux-x64 .
cd ../../..
docker run --rm --volume $(pwd):/work skiasharp-linux-x64 \
  /bin/bash -c "dotnet tool restore && dotnet cake native/linux/build.cake --target=libHarfBuzzSharp --buildarch=x64"
```

Output: `output/native/linux/x64/libHarfBuzzSharp.so` (and the versioned
`libHarfBuzzSharp.so.<soname>`).
