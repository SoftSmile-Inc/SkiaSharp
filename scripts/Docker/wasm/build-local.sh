#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Usage: build-local.sh [emscripten-version] [features] [--cake-arg=value ...]
# Arguments starting with -- are forwarded to `dotnet cake` inside the container
# (eg. --wasmRenameThirdPartySymbols=true); an --emscriptenFeatures=... among them
# replaces the positional/default features.
EMSCRIPTEN_VERSION="3.1.56"
FEATURES="_wasmeh,st"
case "$1" in --*|"") ;; *) EMSCRIPTEN_VERSION="$1"; shift ;; esac
case "$1" in --*|"") ;; *) FEATURES="$1"; shift ;; esac
EXTRA_CAKE_ARGS="$*"
case " $EXTRA_CAKE_ARGS" in *" --emscriptenFeatures="*) FEATURES="" ;; esac

# Use linux/amd64 platform for Docker — older emscripten versions don't publish arm64 binaries
PLATFORM_ARGS=""
if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
    PLATFORM_ARGS="--platform linux/amd64"
fi

(cd "$DIR" && docker build $PLATFORM_ARGS --tag skiasharp-wasm:$EMSCRIPTEN_VERSION --build-arg EMSCRIPTEN_VERSION=$EMSCRIPTEN_VERSION .)

FEATURES_ARG=""
if [ -n "$FEATURES" ]; then
    FEATURES_ARG="--emscriptenFeatures='$FEATURES'"
fi

(cd "$DIR/../../../" && \
    docker run --rm $PLATFORM_ARGS --name skiasharp-wasm-$EMSCRIPTEN_VERSION --volume "$(pwd)":/work skiasharp-wasm:$EMSCRIPTEN_VERSION /bin/bash -c "\
        dotnet tool restore ; \
        dotnet cake --target=externals-wasm --emscriptenVersion=$EMSCRIPTEN_VERSION $FEATURES_ARG $EXTRA_CAKE_ARGS")
