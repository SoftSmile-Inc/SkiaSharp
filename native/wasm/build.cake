DirectoryPath ROOT_PATH = MakeAbsolute(Directory("../.."));
DirectoryPath OUTPUT_PATH = MakeAbsolute(ROOT_PATH.Combine("output/native"));

#load "../../scripts/cake/native-shared.cake"

string SUPPORT_GPU_VAR = Argument("supportGpu", EnvironmentVariable("SUPPORT_GPU") ?? "true").ToLower();
string EMSCRIPTEN_ROOT = Argument("emscripten", EnvironmentVariable("EMSCRIPTEN_SDK_ROOT") ?? EnvironmentVariable("EMSDK") ?? "");
string EMSCRIPTEN_VERSION = Argument("emscriptenVersion", EnvironmentVariable("EMSCRIPTEN_VERSION") ?? "").ToLower();
string[] EMSCRIPTEN_FEATURES = Argument("emscriptenFeatures", EnvironmentVariable("EMSCRIPTEN_FEATURES") ?? "").ToLower()
    .Split(",").Where(f => f != "none").ToArray();
bool SUPPORT_GPU = SUPPORT_GPU_VAR == "1" || SUPPORT_GPU_VAR == "true";

// Off by default: renaming is only useful (and only verified) when this static library ends up
// statically linked alongside a host application's own copies of freetype2/libjpeg-turbo/zlib/
// libpng (eg. a Unity build). Leaving this off keeps the default wasm build exactly as it was
// before.
string SYMBOL_RENAMES_VAR = Argument("wasmRenameThirdPartySymbols", EnvironmentVariable("WASM_RENAME_THIRDPARTY_SYMBOLS") ?? "false").ToLower();
bool ENABLE_SYMBOL_RENAMES = SYMBOL_RENAMES_VAR == "1" || SYMBOL_RENAMES_VAR == "true";

string CC = Argument("cc", "emcc");
string CXX = Argument("cxx", "em++");
string AR = Argument("ar", "emar");
string NM = Argument("nm", "emnm");
string COMPILERS = $"cc='{CC}' cxx='{CXX}' ar='{AR}' ";

// Symbols that freetype2/libjpeg-turbo/zlib/libpng would otherwise export as globals (eg. FT_*,
// jpeg_*, deflate*/inflate*, png_*, and their non-static internal helpers) get renamed with this
// prefix when ENABLE_SYMBOL_RENAMES is on, so this static library cannot collide with a host
// application's own copies of the same libraries when both are statically linked together.
// Regenerate with the 'generate-wasm-symbol-renames' target after any of those checkouts change
// (ie. after a Skia DEPS bump) and commit the result.
string SYMBOL_RENAME_PREFIX = "sksharp_";
FilePath SYMBOL_RENAMES_HEADER = MakeAbsolute(ROOT_PATH.CombineWithFilePath("native/wasm/libSkiaSharp/wasm_symbol_renames.h"));

string WasmSkiaGnArgs(bool hasSimdEnabled, bool hasThreadingEnabled, bool hasWasmEH, bool includeSymbolRenames)
{
    return
        $"target_os='linux' " +
        $"target_cpu='wasm' " +
        $"is_static_skiasharp=true " +
        $"skia_enable_fontmgr_custom_directory=false " +
        $"skia_enable_fontmgr_custom_empty=false " +
        $"skia_enable_fontmgr_custom_embedded=true " +
        $"skia_enable_fontmgr_empty=false " +
        $"skia_enable_ganesh={(SUPPORT_GPU ? "true" : "false")} " +
        (SUPPORT_GPU ? "skia_gl_standard='webgl'" : "") +
        $"skia_enable_pdf=true " +
        $"skia_use_dng_sdk=false " +
        $"skia_use_webgl=true " +
        $"skia_use_fontconfig=false " +
        $"skia_use_freetype=true " +
        $"skia_use_harfbuzz=false " +
        $"skia_use_icu=false " +
        $"skia_use_piex=false " +
        $"skia_use_sfntly=false " +
        $"skia_use_expat=true " +
        $"skia_use_libwebp_encode=true " +
        $"skia_use_system_expat=false " +
        $"skia_use_system_freetype2=false " +
        $"skia_use_system_libjpeg_turbo=false " +
        $"skia_use_system_libpng=false " +
        $"skia_use_system_libwebp=false " +
        $"skia_use_system_zlib=false " +
        $"skia_use_vulkan=false " +
        $"skia_use_wuffs=true " +
        $"skia_enable_skottie=true " +
        $"use_PIC=false " +
        $"extra_cflags=[ " +
        $"  '-DSKIA_C_DLL', '-DXML_POOR_ENTROPY', " +
        $" {(!hasSimdEnabled ? "'-DSKNX_NO_SIMD', " : "")} '-DSK_DISABLE_AAA', '-DGR_GL_CHECK_ALLOC_WITH_GET_ERROR=0', " +
        $"  '-s', 'WARN_UNALIGNED=1' " + // '-s', 'USE_WEBGL2=1' (experimental)
        $"  { (hasSimdEnabled ? ", '-msimd128'" : "") } " +
        $"  { (hasThreadingEnabled ? ", '-pthread'" : "") } " +
        $"  { (hasWasmEH ? ", '-fwasm-exceptions'" : "") } " +
        $"  { (includeSymbolRenames ? $", '-include', '{SYMBOL_RENAMES_HEADER.FullPath}'" : "") } " +
        $"] " +
        // SIMD support is based on https://github.com/google/skia/blob/1f193df9b393d50da39570dab77a0bb5d28ec8ef/modules/canvaskit/compile.sh#L57
        $"extra_cflags_cc=[ '-frtti' { (hasSimdEnabled ? ", '-msimd128'" : "") } { (hasThreadingEnabled ? ", '-pthread'" : "") } { (hasWasmEH ? ", '-fwasm-exceptions'" : "") } ] " +
        $"skia_emsdk_dir='{EMSCRIPTEN_ROOT}'" +
        COMPILERS +
        ADDITIONAL_GN_ARGS;
}

// Reads an archive's global, defined symbols -- ie. the ones that would participate in a
// "duplicate symbol" collision if a host application statically links its own copy of the same
// library alongside this one.
HashSet<string> GetDefinedGlobalSymbols(FilePath archive)
{
    RunProcess(NM, $"--defined-only --extern-only \"{archive.FullPath}\"", out IEnumerable<string> stdout);

    var symbols = new HashSet<string>();
    foreach (var line in stdout) {
        // eg. "0000000000000010 T FT_Init_FreeType" -- archive member header lines don't match.
        var parts = line.Trim().Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 3 && parts[1].Length == 1 && System.Text.RegularExpressions.Regex.IsMatch(parts[0], "^[0-9a-fA-F]+$"))
            symbols.Add(parts[2]);
    }
    return symbols;
}

// Finds which .a in outDir defines anchorSymbol, without assuming what GN names the output file
// for a given target (the third_party() GN template doesn't guarantee it).
FilePath FindArchiveContaining(DirectoryPath outDir, string anchorSymbol)
{
    FilePath found = null;
    foreach (var file in GetFiles($"{outDir}/*.a")) {
        if (GetDefinedGlobalSymbols(file).Contains(anchorSymbol)) {
            if (found != null)
                throw new Exception($"Symbol '{anchorSymbol}' was found in both '{found}' and '{file}' -- cannot uniquely identify the archive.");
            found = file;
        }
    }
    if (found == null)
        throw new Exception($"Could not find an archive defining '{anchorSymbol}' under '{outDir}' -- did the discovery build succeed?");
    return found;
}

// Builds freetype2, libjpeg-turbo, zlib and libpng in isolation (a dedicated out dir, so the
// normal 'libSkiaSharp' build/output is untouched) and records every global symbol they define,
// so 'libSkiaSharp' can rename all of them and avoid colliding with a host application's own
// copies of the same libraries. Re-run this -- and commit its output -- after any of those
// checkouts change (ie. after a Skia DEPS bump); otherwise new symbols they introduce would be
// missed by the rename and could still collide.
Task("generate-wasm-symbol-renames")
    .IsDependentOn("git-sync-deps")
    .WithCriteria(IsRunningOnLinux())
    .Does(() =>
{
    var args = WasmSkiaGnArgs(hasSimdEnabled: false, hasThreadingEnabled: false, hasWasmEH: false, includeSymbolRenames: false);

    GnNinja("wasm-symgen", "third_party/freetype2:freetype2", args);
    GnNinja("wasm-symgen", "third_party/libjpeg-turbo:libjpeg", args);
    GnNinja("wasm-symgen", "third_party/zlib:zlib", args);
    GnNinja("wasm-symgen", "third_party/libpng:libpng", args);

    var symgenOut = SKIA_PATH.Combine("out/wasm-symgen");

    // Anchors are real functions (not macros) that are unique to each library, used to find its
    // archive without assuming what GN names the output file for a given target.
    var freetypeArchive = FindArchiveContaining(symgenOut, "FT_Init_FreeType");
    var libjpegArchive = FindArchiveContaining(symgenOut, "jpeg_CreateDecompress");
    var zlibArchive = FindArchiveContaining(symgenOut, "Cr_z_deflate");
    var libpngArchive = FindArchiveContaining(symgenOut, "png_read_info");

    // Note: zlib/libpng do have their own built-in symbol-prefixing mechanisms (Z_PREFIX,
    // PNG_PREFIX), but they are deliberately not used here: Z_PREFIX only covers zlib's ~90
    // documented public functions (internal helpers like the SIMD-specific ones are missed), and
    // PNG_PREFIX requires hand-authoring a separate pngprefix.h with the same kind of mapping this
    // script already generates. Renaming everything that is actually global at link time (as
    // discovered via nm) is more complete than either, and keeps all four libraries on one
    // uniform mechanism.
    var symbols = new SortedSet<string>();
    symbols.UnionWith(GetDefinedGlobalSymbols(freetypeArchive));
    symbols.UnionWith(GetDefinedGlobalSymbols(libjpegArchive));
    symbols.UnionWith(GetDefinedGlobalSymbols(zlibArchive));
    symbols.UnionWith(GetDefinedGlobalSymbols(libpngArchive));

    if (symbols.Count == 0)
        throw new Exception("No symbols were discovered for freetype2/libjpeg-turbo/zlib/libpng -- something is wrong with the discovery build.");

    var lines = new List<string> {
        "// Generated by the 'generate-wasm-symbol-renames' cake target. DO NOT EDIT BY HAND.",
        "// Renames every global symbol freetype2/libjpeg-turbo/zlib/libpng would otherwise export,",
        "// so this static library cannot collide with a host application's own copies of the same",
        "// libraries (eg. Unity's bundled libfreetype2/libjpeg/zlib/libpng) when both get statically",
        "// linked together. Regenerate via the 'generate-wasm-symbol-renames' cake target after the",
        "// freetype2/libjpeg-turbo/zlib/libpng checkout changes.",
        "#ifndef SKIASHARP_WASM_SYMBOL_RENAMES_H",
        "#define SKIASHARP_WASM_SYMBOL_RENAMES_H",
    };
    foreach (var symbol in symbols)
        lines.Add($"#define {symbol} {SYMBOL_RENAME_PREFIX}{symbol}");
    lines.Add("#endif");

    EnsureDirectoryExists(SYMBOL_RENAMES_HEADER.GetDirectory());
    System.IO.File.WriteAllLines(SYMBOL_RENAMES_HEADER.FullPath, lines);

    Information($"Wrote {symbols.Count} symbol renames to '{SYMBOL_RENAMES_HEADER}'.");
});

Task("libSkiaSharp")
    .IsDependentOn("git-sync-deps")
    .WithCriteria(IsRunningOnLinux())
    .Does(() =>
{
    if (ENABLE_SYMBOL_RENAMES && !FileExists(SYMBOL_RENAMES_HEADER))
        throw new Exception($"Missing '{SYMBOL_RENAMES_HEADER}'. Run the 'generate-wasm-symbol-renames' cake target once and commit its output before building with --wasmRenameThirdPartySymbols=true.");

    bool hasSimdEnabled = EMSCRIPTEN_FEATURES.Contains("simd") || EMSCRIPTEN_FEATURES.Contains("_simd");
    bool hasThreadingEnabled = EMSCRIPTEN_FEATURES.Contains("mt");
    bool hasWasmEH = EMSCRIPTEN_FEATURES.Contains("_wasmeh");

    var emscriptenFeaturesModifiers =
        EMSCRIPTEN_FEATURES
        .Where(f => !f.StartsWith("_"))
        .ToArray();

    GnNinja($"wasm", "SkiaSharp", WasmSkiaGnArgs(hasSimdEnabled, hasThreadingEnabled, hasWasmEH, includeSymbolRenames: ENABLE_SYMBOL_RENAMES));

    var a = SKIA_PATH.CombineWithFilePath($"out/wasm/libSkiaSharp.a");

    // separate all the .a files into .o files
    var skiaOut = SKIA_PATH.Combine("out/wasm");
    var mergeDir = skiaOut.Combine("obj/merge");
    EnsureDirectoryExists(mergeDir);
    CleanDirectories(mergeDir.FullPath);
    foreach (var file in GetFiles($"{skiaOut}/*.a")) {
        RunProcess(AR, new ProcessSettings {
            Arguments = $"x \"{file}\"",
            WorkingDirectory = mergeDir.FullPath,
        });
    }

    // add the default font
    var input = SKIA_PATH.CombineWithFilePath("modules/canvaskit/fonts/NotoMono-Regular.ttf");
    var embed_resources = SKIA_PATH.CombineWithFilePath("tools/embed_resources.py");
    RunProcess(PYTHON_EXE, new ProcessSettings {
        Arguments = $"{embed_resources} --name SK_EMBEDDED_FONTS --input {input} --output {input}.cpp --align 4",
        WorkingDirectory = SKIA_PATH.FullPath,
    });
    RunProcess(CC, $"-std=c++17 -I. {input}.cpp -r -o {mergeDir}/NotoMonoRegularttf.o");

    // merge all the .o files into the final .a file
    var oFiles = GetFiles($"{mergeDir}/*.o");
    RunProcess(AR, $"-crs {a} {string.Join(" ", oFiles)}");

    var outDir = OUTPUT_PATH.Combine($"wasm");
    if (!string.IsNullOrEmpty(EMSCRIPTEN_VERSION))
        outDir = outDir.Combine("libSkiaSharp.a").Combine(EMSCRIPTEN_VERSION);
    if (emscriptenFeaturesModifiers.Length != 0)
        outDir = outDir.Combine(string.Join(",", emscriptenFeaturesModifiers));
    EnsureDirectoryExists(outDir);
    CopyFileToDirectory(a, outDir);
});

Task("libHarfBuzzSharp")
    .WithCriteria(IsRunningOnLinux())
    .Does(() =>
{
    bool hasSimdEnabled = EMSCRIPTEN_FEATURES.Contains("simd") || EMSCRIPTEN_FEATURES.Contains("_simd");
    bool hasThreadingEnabled = EMSCRIPTEN_FEATURES.Contains("mt");
    bool hasWasmEH = EMSCRIPTEN_FEATURES.Contains("_wasmeh");

    var emscriptenFeaturesModifiers = 
        EMSCRIPTEN_FEATURES
        .Where(f => !f.StartsWith("_"))
        .ToArray();

    GnNinja($"wasm", "HarfBuzzSharp",
        $"target_os='linux' " +
        $"target_cpu='wasm' " +
        $"is_static_skiasharp=true " +
        $"visibility_hidden=false " +
        $"extra_cflags=[ '-s', 'WARN_UNALIGNED=1' { (hasSimdEnabled ? ", '-msimd128'" : "") } { (hasThreadingEnabled ? ", '-pthread'" : "") } { (hasWasmEH ? ", '-fwasm-exceptions'" : "") } ] " +
        $"extra_cflags_cc=[ '-frtti' { (hasSimdEnabled ? ", '-msimd128'" : "") } { (hasThreadingEnabled ? ", '-pthread'" : "") } { (hasWasmEH ? ", '-fwasm-exceptions'" : "") } ] " +
        $"skia_emsdk_dir='{EMSCRIPTEN_ROOT}'" +
        COMPILERS +
        ADDITIONAL_GN_ARGS);

    var outDir = OUTPUT_PATH.Combine($"wasm");
    if (!string.IsNullOrEmpty(EMSCRIPTEN_VERSION))
        outDir = outDir.Combine("libHarfBuzzSharp.a").Combine(EMSCRIPTEN_VERSION);
    if (emscriptenFeaturesModifiers.Length != 0)
        outDir = outDir.Combine(string.Join(",", emscriptenFeaturesModifiers));
    EnsureDirectoryExists(outDir);
    var so = SKIA_PATH.CombineWithFilePath($"out/wasm/libHarfBuzzSharp.a");
    CopyFileToDirectory(so, outDir);
    CopyFile(so, outDir.CombineWithFilePath("libHarfBuzzSharp.a"));
});

Task("Default")
    .IsDependentOn("libSkiaSharp")
    .IsDependentOn("libHarfBuzzSharp");

RunTarget(TARGET);
