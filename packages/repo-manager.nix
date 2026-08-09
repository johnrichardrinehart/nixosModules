{ system }:

(builtins.getFlake "git+https://github.com/johnrichardrinehart/repo-manager?rev=d4dac1cd0a784ddc58ce28ed5f4babb03eceedef")
.packages.${system}.repo-manager
