{ git, fetchpatch2 }:
git.overrideAttrs (old: {
  pname = "git-local-namespace";
  version = "${old.version}-local-namespace";
  __intentionallyOverridingVersion = true;
  patches = (old.patches or [ ]) ++ [
    (fetchpatch2 {
      name = "git-local-namespace.patch";
      url = "https://github.com/johnrichardrinehart/git/compare/master...48926315e0f449dc48f8e515cc3043712e2f87f5.patch?full_index=1";
      hash = "sha256-zcmTjyGsuc51zbOvgLWTQx33fGayLmTapTnIUVaWOQg=";
    })
  ];
})
