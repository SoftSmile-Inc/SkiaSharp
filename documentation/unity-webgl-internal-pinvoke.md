# Unity WebGL: building SkiaSharp.dll / HarfBuzzSharp.dll with `__Internal` P/Invokes

## Problem

Unity's IL2CPP/Mono WebGL backend statically links all native code, including
`libSkiaSharp`/`libHarfBuzzSharp`, into a single wasm module. In that
environment, a P/Invoke's `DllImport`/`LibraryImport` module name must be the
literal `"__Internal"` — Unity's P/Invoke resolution treats any other module
name as a request to dynamically load a separate native module, which doesn't
exist in the browser. Using the standard `SkiaSharp.dll`/`HarfBuzzSharp.dll`
(built with the module name `libSkiaSharp`/`libHarfBuzzSharp`) unmodified in a
Unity WebGL build fails at runtime with:

```
DllNotFoundException: Unable to load DLL 'libSkiaSharp'. Tried the load the following dynamic libraries:
```

This is unrelated to the WASM support already in this repo
(`SkiaSharp.NativeAssets.WebAssembly`, `native/wasm/build.cake`,
[wasm-symbol-renaming.md](wasm-symbol-renaming.md)), which targets the .NET
WebAssembly SDK's own static-linking pipeline (Blazor-style). That pipeline
resolves P/Invokes by entry-point name regardless of the declared module
string, so it never needed `__Internal`.

## Fix: `SkiaSharpUnityWebGLInternal` build property

`binding/SkiaSharp/SkiaApi.cs` and `binding/HarfBuzzSharp/HarfBuzzApi.cs` each
declare the P/Invoke module-name constant (`SKIA` / `HARFBUZZ`) used by every
generated P/Invoke in `SkiaApi.generated.cs` / `HarfBuzzApi.generated.cs`.
`SkiaSharp.csproj` and `HarfBuzzSharp.csproj` each add a `PropertyGroup`
that, when the MSBuild property `SkiaSharpUnityWebGLInternal` is `true`,
appends the `SKIASHARP_UNITY_WEBGL_INTERNAL` preprocessor define, which
switches that constant to `"__Internal"` — mirroring the existing
`__IOS__`/`__TVOS__` branch used for embedded Apple frameworks. No other
source changes are needed — `USE_LIBRARY_IMPORT` (which picks `LibraryImport`
vs. `DllImport` syntax) is unaffected and already applies for any net7.0+
TFM.

This is a dedicated MSBuild property rather than passing `DefineConstants`
directly on the command line: `-p:DefineConstants=...` sets a *global*
property that the project's own `<DefineConstants>$(DefineConstants);...`
assignments (including the one that sets `USE_LIBRARY_IMPORT`) can no longer
append to, silently dropping them and breaking the build.

Build the Unity-WebGL variant of each assembly directly from this repo:

```sh
dotnet build binding/SkiaSharp/SkiaSharp.csproj \
  -f net8.0 -c Release \
  -p:SkiaSharpUnityWebGLInternal=true \
  -o artifacts/unity-webgl/SkiaSharp

dotnet build binding/HarfBuzzSharp/HarfBuzzSharp.csproj \
  -f net8.0 -c Release \
  -p:SkiaSharpUnityWebGLInternal=true \
  -o artifacts/unity-webgl/HarfBuzzSharp
```

Adjust `-f` to whichever `TargetFramework` you currently ship into Unity
(e.g. `netstandard2.1`) if it differs from `net8.0`.

## Installing into a Unity project

Import the resulting `SkiaSharp.dll` and `HarfBuzzSharp.dll` as
**WebGL-only platform plugins**: select each DLL in the Unity Editor,
uncheck "Any Platform" in the Inspector's Plugin settings, and check only
"WebGL". Keep the normal (non-`__Internal`) build of each DLL assigned to
all other platforms.

With this in place, the post-build IL patch (`DLLPInvokeRewriter.RewritePInvoke`
using Mono.Cecil) is no longer needed for WebGL builds — the module name is
already correct in the assembly.

## Scope

Only `binding/SkiaSharp/SkiaApi.cs` and `binding/HarfBuzzSharp/HarfBuzzApi.cs`
were changed. The sibling assemblies `SkiaSharp.Skottie`, `SkiaSharp.SceneGraph`,
and `SkiaSharp.Resources` have the identical `SKIA`-style constant pattern in
their own `*Api.cs` files; the same one-line change extends to them if a
project needs those assemblies in Unity WebGL too.
