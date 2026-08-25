#ifndef SKIASHARP_WASM_HB_EXTERN_VISIBILITY_H
#define SKIASHARP_WASM_HB_EXTERN_VISIBILITY_H

// harfbuzz defines HB_EXTERN as plain 'extern' (hb-common.h). When --wasmRenameThirdPartySymbols
// enables '-fvisibility=hidden' (native/wasm/build.cake) to hide harfbuzz's internals, this
// override keeps its genuine public hb_* API exported. See documentation/wasm-symbol-renaming.md.
#define HB_EXTERN extern __attribute__((visibility("default")))

#endif
