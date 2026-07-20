# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation (_finalAttrs: {
  pname = "sensing-demo";
  version = "0.3.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ python3 ];

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    ${python3}/bin/python -m unittest discover -s tests -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 sensing_demo.py $out/lib/sensing-demo/sensing_demo.py
    makeWrapper ${python3}/bin/python $out/bin/sensing-demo \
      --add-flags "$out/lib/sensing-demo/sensing_demo.py"
    runHook postInstall
  '';

  meta = {
    description = "Animated RGB producer and semantic receiver for the Ghaf sensing VM demo";
    license = lib.licenses.asl20;
    mainProgram = "sensing-demo";
    platforms = lib.platforms.linux;
  };
})
