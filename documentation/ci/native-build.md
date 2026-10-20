# Native build for the Unity project

`.github/workflows/native-build.yml` builds the bundle of libraries the Unity project keeps in
`Assets/ExternalPlugins/`: what has to come from this fork is built here, the rest is taken
unchanged from the nuget.org packages.

## Bundle

| Slot | Source |
|---|---|
| `WebGL/libSkiaSharp.a` | fork: freetype2/libjpeg-turbo/libpng renamed to `sksharp_*` ([wasm-symbol-renaming.md](../wasm-symbol-renaming.md)) |
| `WebGL/SkiaSharp.dll`, `WebGL/HarfBuzzSharp.dll` | fork: `__Internal` P/Invokes ([unity-webgl-internal-pinvoke.md](../unity-webgl-internal-pinvoke.md)) |
| `x86_64/libHarfBuzzSharp.so` | fork: `-Wl,-Bsymbolic-functions` ([linux-harfbuzz-symbol-interposition.md](../linux-harfbuzz-symbol-interposition.md)) |
| `x86_64/libSkiaSharp.so`, `x86_64/libSkiaSharp.dll`, `x86_64/libHarfBuzzSharp.dll`, `MacOS/*.dylib` | stock natives |
| `SkiaSharp.dll`, `SkiaSharp.HarfBuzz.dll`, `HarfBuzzSharp.dll` | stock, `lib/netstandard2.1` |

There is no `WebGL/libHarfBuzzSharp.a`: in WebGL, HarfBuzzSharp calls the harfbuzz built into
Unity. Stock versions are read from `scripts/VERSIONS.txt` of the built commit.

## Building

The fork's changes live on `patches/<SkiaSharp version>` branches. To build one:

```bash
gh workflow run native-build.yml -R SoftSmile-Inc/SkiaSharp --ref ci/native-build -f ref=patches/3.119.2
```

or Actions → Native build → Run workflow, with `ref` set to the branch. `--ref` is where the
workflow comes from, `ref` is what gets built. A build takes 10-15 minutes; if it fails while
fetching Skia dependencies from Google's servers, re-run the failed jobs.

The result is the run artifact `bundle-<SkiaSharp version>-dev.<sha>`, kept for 14 days:

```bash
gh run download <run id> -R SoftSmile-Inc/SkiaSharp -n bundle-3.119.2-dev.<sha>
```

Copy all files from the zip into `Assets/ExternalPlugins/` over the existing ones, keeping their
`.meta` files. `versions.json` in the zip records the built commit and the sha256 of every file.

Optional inputs: `emscripten_version` (the one Unity ships: 3.1.39 for 6000.3.8f1),
`emscripten_features` (`_wasmeh,st,simd`, from the Unity project's WebGL settings), `unity_version`.

## Moving to a new SkiaSharp version

Carry the fork's commits over to the new upstream tag, eg. from 3.119.2 to 3.119.4:

```bash
git fetch https://github.com/mono/SkiaSharp tag v3.119.2 tag v3.119.4 --no-tags
git branch patches/3.119.4 patches/3.119.2
git rebase --onto v3.119.4 v3.119.2 patches/3.119.4
git push origin patches/3.119.4
```

On a conflict in `documentation/README.md` keep upstream's file. Then build `patches/3.119.4` as
above. If upstream changed the build setup (Docker images, SDK, target frameworks), the workflow
may need a fix on `ci/native-build`.

## Checks

The build fails when:

- `libSkiaSharp.a` exports `FT_*`, `png_*` or `jpeg_*` under the original name, or has no `sksharp_*`
  or `sk_*` symbols;
- `libHarfBuzzSharp.so` has `hb_*` PLT entries;
- the WebGL dlls do not use `__Internal`, or `HarfBuzzSharp.dll` calls anything but plain `hb_*`.

CI cannot check the Unity side: after a SkiaSharp or Unity upgrade, build the Unity project for
WebGL and check text rendering in a browser.
