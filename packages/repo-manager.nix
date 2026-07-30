{ system }:

(builtins.getFlake "git+https://github.com/johnrichardrinehart/repo-manager?rev=950e0565bf5b8158e85346a7df8aeaf0a4723361")
.packages.${system}.repo-manager
