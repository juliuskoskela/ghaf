# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  pkgs,
  lib,
}:
pkgs.stdenv.mkDerivation rec {
  pname = "ollama-jetson";
  version = "0.5.11";

  src = pkgs.fetchurl {
    url = "https://github.com/ollama/ollama/releases/download/v${version}/ollama-linux-arm64.tgz";
    sha256 = "sha256-5NhY0q6gCPRfyaZvYkgNr7Mi/NtwfI/PM2Gg7irzfko=";
  };

  jetpackSrc = pkgs.fetchurl {
    url = "https://github.com/ollama/ollama/releases/download/v${version}/ollama-linux-arm64-jetpack6.tgz";
    sha256 = "sha256-f5UhEYEAn0cKgAv0jOC7JbplSDEygxGS/gun/AphTq0=";
  };

  nativeBuildInputs = with pkgs; [
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = with pkgs; [
    stdenv.cc.cc.lib
    nvidia-jetpack.l4t-cuda
  ];

  dontStrip = true;
  autoPatchelfIgnoreMissingDeps = [ "libcuda.so.1" ];

  sourceRoot = ".";

  unpackPhase = ''
    tar xzf $src
    tar xzf $jetpackSrc
  '';

  installPhase = ''
    # Create directories
    mkdir -p $out/bin
    mkdir -p $out/lib/ollama/cuda_jetpack6

    # Install main binary
    install -Dm755 bin/ollama $out/bin/ollama

    # Install base libraries
    cp -P lib/ollama/libggml-base.so $out/lib/ollama/
    cp -P lib/ollama/libggml-cpu-*.so $out/lib/ollama/

    # Install JetPack libraries
    cp -P lib/ollama/cuda_jetpack6/* $out/lib/ollama/cuda_jetpack6/

    # Wrap the binary with LD_LIBRARY_PATH
    wrapProgram $out/bin/ollama \
      --set LD_LIBRARY_PATH "${pkgs.nvidia-jetpack.l4t-cuda}/lib"
  '';

  meta = with lib; {
    description = "Ollama for Jetson devices";
    homepage = "https://github.com/ollama/ollama";
    license = licenses.mit;
    platforms = [ "aarch64-linux" ];
    maintainers = with maintainers; [ ];
  };
}
