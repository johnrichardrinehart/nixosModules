{ system }:

(builtins.getFlake "git+https://github.com/johnrichardrinehart/repo-manager?rev=a16d29d5dbb20a172c63a38065d7fecba16f4684")
.packages.${system}.repo-manager
