{ openvino, fetchFromGitHub }:

openvino.overrideAttrs (
  finalAttrs: _old: {
    version = "2026.4.0";

    src = fetchFromGitHub {
      owner = "openvinotoolkit";
      repo = "openvino";
      tag = finalAttrs.version;
      fetchSubmodules = true;
      hash = "sha256-WIFbm2/lptoJGBVqpYM/qD9MHOTpayMT95fXOLmlfP4=";
    };
  }
)
