{
  fetchurl,
  lib,
  stdenvNoCC,
}:
let
  # Hugging Face has the gated PyTorch/NPZ Community-1 release, not the ONNX
  # exports cpp-annote consumes. Pin cpp-annote's public, ordinary model files
  # as FODs until upstream publishes those exports on Hugging Face.
  revision = "50b39685e8ea1f651752aa5a196783fb0a3fe0d9";
  baseUrl = "https://raw.githubusercontent.com/moonshine-ai/cpp-annote/${revision}/artifacts";
  components = {
    "community1-segmentation.onnx" = fetchurl {
      url = "${baseUrl}/community1-segmentation.onnx";
      hash = "sha256-Nv28UI6L9gaM6OPaNVyuJJhi6YxvXbgMcW0zcA0Wbg4=";
    };
    "community1-embedding.onnx" = fetchurl {
      url = "${baseUrl}/community1-embedding.onnx";
      hash = "sha256-/Z4tl3hwSX0tiy4wunF+HBoeHuWkenH4Sx9OdmYK7C8=";
    };
    "community1-segmentation.json" = fetchurl {
      url = "${baseUrl}/community1-segmentation.json";
      hash = "sha256-clM513oUc0EZXI/o50bm4TpJo81Wk7VuUncWqfS4xKI=";
    };
    "community1-embedding.json" = fetchurl {
      url = "${baseUrl}/community1-embedding.json";
      hash = "sha256-px1VEhBL95/kdeY5c8MKB2a02L09PRm+pacNWIwXBkw=";
    };
  };
in
stdenvNoCC.mkDerivation {
  pname = "moonshine-diarization-models";
  version = "community-1-${builtins.substring 0 7 revision}";

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: component: ''cp ${component} "$out/${name}"'') components
    )}
    runHook postInstall
  '';

  meta = {
    description = "ONNX models and metadata for Moonshine speaker diarization";
    homepage = "https://github.com/moonshine-ai/cpp-annote";
    license = lib.licenses.cc-by-40;
    platforms = lib.platforms.all;
  };
}
