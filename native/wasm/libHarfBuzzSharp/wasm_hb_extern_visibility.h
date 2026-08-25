#ifndef SKIASHARP_WASM_HB_EXTERN_VISIBILITY_H
#define SKIASHARP_WASM_HB_EXTERN_VISIBILITY_H

// harfbuzz's own public headers define HB_EXTERN as a plain 'extern' (hb-common.h), relying on
// the compiler's default (visible) symbol visibility. When '-fvisibility=hidden' is enabled
// (visibility_hidden=true in native/wasm/build.cake, gated by --wasmRenameThirdPartySymbols) to
// keep harfbuzz's internal, mostly C++-mangled implementation symbols out of the archive's
// global symbol table, this override keeps harfbuzz's genuine public API exported -- otherwise
// it would be hidden right along with the internals, breaking every hb_* P/Invoke call the
// managed HarfBuzzSharp binding makes.
#define HB_EXTERN extern __attribute__((visibility("default")))

#endif
