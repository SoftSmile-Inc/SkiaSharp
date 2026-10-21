# Native build for the Unity project

The Unity project keeps SkiaSharp's libraries in `Assets/ExternalPlugins/`. A few of them need
this fork's changes, so they are built here. The rest are copied unchanged from the nuget.org
packages. `.github/workflows/native-build.yml` does both and packs everything into one zip.

## How it works

The fork's changes are four commits on top of an upstream release, kept on a
`patches/<SkiaSharp version>` branch, eg. `patches/3.119.2`. The workflow lives only on
`ci/native-build`: you run it from there and tell it which `patches/*` branch to build.

A run has four jobs, and then packs their results:

- **wasm** builds `WebGL/libSkiaSharp.a`;
- **linux** builds `x86_64/libHarfBuzzSharp.so`;
- **managed** builds `WebGL/SkiaSharp.dll` and `WebGL/HarfBuzzSharp.dll`;
- **stock** downloads the other files from nuget.org, in the versions listed in
  `scripts/VERSIONS.txt` of the built branch.

Each build job checks that the fork's change really got into its file, and fails if it didn't.

| File | Where it comes from |
|---|---|
| `WebGL/libSkiaSharp.a` | built: freetype, libpng and libjpeg renamed so they don't clash with Unity's own copies ([wasm-symbol-renaming.md](../wasm-symbol-renaming.md)) |
| `WebGL/SkiaSharp.dll`, `WebGL/HarfBuzzSharp.dll` | built: native calls go to `__Internal`, as Unity WebGL requires ([unity-webgl-internal-pinvoke.md](../unity-webgl-internal-pinvoke.md)) |
| `x86_64/libHarfBuzzSharp.so` | built: calls its own harfbuzz, not the one in the Unity Linux player ([linux-harfbuzz-symbol-interposition.md](../linux-harfbuzz-symbol-interposition.md)) |
| `x86_64/libSkiaSharp.so`, `x86_64/*.dll`, `MacOS/*.dylib`, `SkiaSharp.dll`, `SkiaSharp.HarfBuzz.dll`, `HarfBuzzSharp.dll` | nuget.org, unchanged |

There is no `WebGL/libHarfBuzzSharp.a`: in WebGL, HarfBuzzSharp uses the harfbuzz built into Unity.

## Building

```bash
gh workflow run native-build.yml -R SoftSmile-Inc/SkiaSharp --ref ci/native-build -f ref=patches/3.119.2
```

Or on GitHub: Actions → Native build → Run workflow, with `ref` set to the branch. Leave the other
inputs as they are: they match the Unity version the project uses.

A run takes about 10 minutes. If the wasm or linux job fails while downloading Skia's
dependencies (a network error from Google's servers), re-run the failed jobs.

The zip is attached to the run as the artifact `bundle-<version>-dev.<commit>` and is kept for 14
days. Download it from the run page, or:

```bash
gh run download <run id> -R SoftSmile-Inc/SkiaSharp -n bundle-3.119.2-dev.<commit>
```

Copy the files from the zip into `Assets/ExternalPlugins/` over the old ones, keeping their
`.meta` files. Skip `versions.json`: it only records what was built (the commit and the sha256 of
each file).

## Moving to a new SkiaSharp version

Eg. from 3.119.2 to 3.119.4:

1. Put the fork's commits on top of the new upstream release:

   ```bash
   git fetch origin
   git fetch https://github.com/mono/SkiaSharp tag v3.119.2 tag v3.119.4 --no-tags
   git branch patches/3.119.4 origin/patches/3.119.2
   git rebase --onto v3.119.4 v3.119.2 patches/3.119.4
   git push -u origin patches/3.119.4
   ```

   A conflict means upstream changed the same lines as one of the fork's commits: take upstream's
   code and add the fork's change back into it. For `documentation/README.md`, just keep
   upstream's file. `patches/3.119.4` shows how this was done for 3.119.2 → 3.119.4.
2. Build `patches/3.119.4` as above. If a job fails because upstream changed how things are built
   (Docker images, .NET SDK, target frameworks), the workflow on `ci/native-build` needs a fix.
3. Put the new files into the Unity project, make a WebGL build and check text rendering in a
   browser. CI can't check the Unity side.
