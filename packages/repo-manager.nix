{ system }:

(builtins.getFlake "git+https://github.com/johnrichardrinehart/repo-manager?rev=4660c4327b830d50681b70ba6ba8e027ac56769c")
.packages.${system}.repo-manager
