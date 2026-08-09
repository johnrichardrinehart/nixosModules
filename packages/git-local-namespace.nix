{ git, fetchpatch2 }:
git.overrideAttrs (old: {
  pname = "git-local-namespace";
  version = "${old.version}-local-namespace";
  __intentionallyOverridingVersion = true;
  patches = (old.patches or [ ]) ++ [
    (fetchpatch2 {
      name = "git-local-namespace.patch";
      url = "https://github.com/johnrichardrinehart/git/compare/master...08fb0de2c83ab27c651312c3a87e4ef7c2c62c00.patch?full_index=1";
      hash = "sha256-C5PCdH046LdNgsKccblHrvXDy/BczWB3JyTQ5nGMDDI=";
    })
  ];
})
