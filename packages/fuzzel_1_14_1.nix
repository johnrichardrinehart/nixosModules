{ fuzzel, fetchurl }:

fuzzel.overrideAttrs (_old: rec {
  version = "1.14.1";
  src = fetchurl {
    url = "https://codeberg.org/dnkl/fuzzel/archive/${version}.tar.gz";
    hash = "sha256-S4qRTXoGXjTafbTMauTwLHc0ReQbcksouLc4Vja0Se4=";
  };
})
