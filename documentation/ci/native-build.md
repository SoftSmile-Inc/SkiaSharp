# Native build for the Unity project

`.github/workflows/native-build.yml` builds the bundle of libraries the Unity project keeps in
`Assets/ExternalPlugins/`: what has to come from this fork is built here, the rest is taken
unchanged from the nuget.org packages.

## Bundle

| Slot | Source |
|---|---|
| `WebGL/libSkiaSharp.a` | fork: freetype2/libjpeg-turbo/libpng renamed to `sksharp_*` ([wasm-symbol-renaming.md](../wasm-symbol-renaming.md)) |
| `WebGL/libHarfBuzzSharp.a` | fork: all of harfbuzz renamed to `sksharp_*` |
| `WebGL/SkiaSharp.dll`, `WebGL/HarfBuzzSharp.dll` | fork: `__Internal` P/Invokes, HarfBuzzSharp calls `sksharp_hb_*` ([unity-webgl-internal-pinvoke.md](../unity-webgl-internal-pinvoke.md)) |
| `x86_64/libHarfBuzzSharp.so` | fork: `-Wl,-Bsymbolic-functions` ([linux-harfbuzz-symbol-interposition.md](../linux-harfbuzz-symbol-interposition.md)) |
| `x86_64/libSkiaSharp.so`, `x86_64/libSkiaSharp.dll`, `x86_64/libHarfBuzzSharp.dll`, `MacOS/*.dylib` | stock natives |
| `SkiaSharp.dll`, `SkiaSharp.HarfBuzz.dll`, `HarfBuzzSharp.dll` | stock, `lib/netstandard2.1` |

Stock versions are read from `scripts/VERSIONS.txt` of the built commit. `versions.json` in the bundle
records the built commit and the source and sha256 of every file.

Replace all slots at once and keep the `.meta` files already committed in the Unity project.
`WebGL/libHarfBuzzSharp.a` and `WebGL/HarfBuzzSharp.dll` in particular only work together: the new
dll does not link with an old archive, and an old dll links with the new archive but silently uses
Unity's own harfbuzz.

## Running

A dev build of any branch or tag of this repository:

```bash
gh workflow run native-build.yml -R SoftSmile-Inc/SkiaSharp --ref ci/native-build -f ref=<branch-or-tag>
```

`--ref` is where the workflow and `.github/scripts` come from, `ref` is what gets built, so the built
branch does not need to carry the CI. It does need the fork's product changes, the harfbuzz renaming
in `native/wasm/build.cake` and the HarfBuzzSharp entry-point prefix, or the checks fail. The result
is the run artifact `bundle-<SkiaSharp version>-dev.<sha>`, kept for 14 days.

Optional inputs: `emscripten_version` (the one Unity ships: 3.1.39 for 6000.3.8f1),
`emscripten_features` (`_wasmeh,st,simd`, from the Unity project's WebGL settings), `unity_version`.

A release is a pushed tag `v<SkiaSharp version>-ss.<N>`, eg. `v3.119.2-ss.1`, on a commit that
contains the workflow. The bundle is attached to the GitHub Release of that tag and is never
replaced: a rebuild needs a new `N`.

## Checks

The build fails when:

- `libSkiaSharp.a` exports `FT_*`, `png_*` or `jpeg_*` under the original name, or has no `sksharp_*`
  or `sk_*` symbols;
- `libHarfBuzzSharp.a` has no `sksharp_<name>` for a function the binding calls, defines a symbol
  without `sksharp_`, or references a harfbuzz name it does not define;
- `libHarfBuzzSharp.so` has `hb_*` PLT entries;
- the WebGL dlls do not use `__Internal`, or `HarfBuzzSharp.dll` lacks a `sksharp_hb_*` entry point.

A bundle is accepted after a WebGL build of the Unity project with it has been checked in a browser.

The fork is public, so there is no `pull_request` trigger, and the only job with a write token,
`publish`, runs no repository code.
