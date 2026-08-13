#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

VERSION_ARGS=""
EMSCRIPTEN_VERSION=3.1.34
if [ "$1" ]; then
    VERSION_ARGS="--build-arg EMSCRIPTEN_VERSION=$1"
    EMSCRIPTEN_VERSION=$1
fi

(cd $DIR && docker build --tag skiasharp-wasm:$EMSCRIPTEN_VERSION $VERSION_ARGS .)
(cd $DIR/../../../ && \
    docker run --rm --name skiasharp-wasm-symgen-$EMSCRIPTEN_VERSION --volume $(pwd):/work skiasharp-wasm:$EMSCRIPTEN_VERSION /bin/bash -c "\
        dotnet tool restore ; \
        dotnet cake native/wasm/build.cake --target=generate-wasm-symbol-renames")

# review and commit native/wasm/libSkiaSharp/wasm_symbol_renames.h, then build with:
#   ./scripts/Docker/wasm/build-local.sh $EMSCRIPTEN_VERSION
# (add --wasmRenameThirdPartySymbols=true to the "dotnet cake" line in build-local.sh, or
#  run the equivalent externals-wasm command by hand with that flag appended)
