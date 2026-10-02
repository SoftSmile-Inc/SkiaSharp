#nullable disable

using System;

namespace HarfBuzzSharp
{
	internal unsafe partial class HarfBuzzApi
	{
#if __IOS__ || __TVOS__
		private const string HARFBUZZ = "@rpath/libHarfBuzzSharp.framework/libHarfBuzzSharp";
#elif SKIASHARP_UNITY_WEBGL_INTERNAL
		private const string HARFBUZZ = "__Internal";
#else
		private const string HARFBUZZ = "libHarfBuzzSharp";
#endif

		// Unity WebGL links its own harfbuzz into the player, so the wasm
		// libHarfBuzzSharp.a exports harfbuzz only under renamed sksharp_* names
		// and the __Internal variant binds to those. Everywhere else the native
		// names are the plain hb_* ones.
		// See documentation/adr/0005-webgl-harfbuzz-isolation.md.
#if SKIASHARP_UNITY_WEBGL_INTERNAL
		private const string HARFBUZZ_ENTRY_POINT_PREFIX = "sksharp_";
#else
		private const string HARFBUZZ_ENTRY_POINT_PREFIX = "";
#endif

#if USE_DELEGATES
		private static readonly Lazy<IntPtr> libHarfBuzzSharpHandle =
			new Lazy<IntPtr> (() => LibraryLoader.LoadLocalLibrary<HarfBuzzApi> (HARFBUZZ));

		private static T GetSymbol<T> (string name) where T : Delegate =>
			LibraryLoader.GetSymbolDelegate<T> (libHarfBuzzSharpHandle.Value, name);
#endif
	}
}
