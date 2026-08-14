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
        dotnet cake native/wasm/build.cake --target=generate-wasm-symbol-renames --wasmRenameThirdPartySymbols=true")

# 'libSkiaSharp' now regenerates native/wasm/libSkiaSharp/wasm_symbol_renames.h automatically
# whenever --wasmRenameThirdPartySymbols=true is passed to build-local.sh, so this script is not a
# required step before building -- it only exists to preview/inspect the header on its own,
# without also running the full libSkiaSharp build. There is no need to commit its output.
