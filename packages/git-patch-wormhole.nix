{
  coreutils,
  git,
  magic-wormhole-rs,
  unzip,
  writeShellApplication,
  zip,
}:

writeShellApplication {
  name = "git-patch-wormhole";

  runtimeInputs = [
    coreutils
    git
    magic-wormhole-rs
    unzip
    zip
  ];

  text = ''
    set -euo pipefail

    temporary_directory=""

    cleanup() {
      if [[ -n "$temporary_directory" ]]; then
        rm -rf -- "$temporary_directory"
      fi
    }
    trap cleanup EXIT

    usage() {
      cat <<'EOF'
    Usage:
      git patch-wormhole send [<git-format-patch argument>...]
      git patch-wormhole receive <code> [--branch <name>] [--base <revision>]

    send passes its arguments directly to git format-patch, archives every generated
    .patch file, and sends the archive with Magic Wormhole.

    receive downloads and applies the patches to a clean Git worktree. --branch
    creates and checks out a new branch. --base starts from the given commit; without
    --branch it uses git checkout, preserving an existing branch when possible.

    Examples:
      git patch-wormhole send main..feature
      git patch-wormhole send main
      git patch-wormhole receive 7-example-code
      git patch-wormhole receive 7-example-code --branch feature --base main
    EOF
    }

    die() {
      printf 'git-patch-wormhole: %s\n' "$*" >&2
      exit 1
    }

    require_repository() {
      git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "the current directory is not inside a Git worktree"
    }

    send_bundle() {
      (( $# > 0 )) || die "send requires a branch, revision, or revision range"
      require_repository

      temporary_directory="$(mktemp -d -t git-patch-wormhole.XXXXXX)"
      patch_directory="$temporary_directory/patches"
      archive="$temporary_directory/git-patches.zip"
      mkdir -p -- "$patch_directory"

      git format-patch --output-directory "$patch_directory" "$@" >/dev/null

      patches=("$patch_directory"/*.patch)
      [[ -e "''${patches[0]}" ]] || die "the revision selection produced no patches"

      (
        cd "$patch_directory"
        zip -q "$archive" -- ./*.patch
      )

      printf 'Sending %d patch(es). The recipient code follows.\n' "''${#patches[@]}"
      wormhole-rs --no-color send --no-qr --rename git-patches.zip "$archive"
    }

    receive_bundle() {
      code=""
      branch=""
      base=""

      while (( $# > 0 )); do
        case "$1" in
          --branch)
            (( $# >= 2 )) || die "--branch requires a name"
            branch="$2"
            shift 2
            ;;
          --branch=*)
            branch="''${1#*=}"
            shift
            ;;
          --base)
            (( $# >= 2 )) || die "--base requires a revision"
            base="$2"
            shift 2
            ;;
          --base=*)
            base="''${1#*=}"
            shift
            ;;
          --help|-h)
            usage
            exit 0
            ;;
          --)
            shift
            (( $# == 1 )) || die "receive accepts exactly one wormhole code"
            code="$1"
            shift
            ;;
          -*)
            die "unknown receive option: $1"
            ;;
          *)
            [[ -z "$code" ]] || die "receive accepts exactly one wormhole code"
            code="$1"
            shift
            ;;
        esac
      done

      [[ -n "$code" ]] || die "receive requires a wormhole code"
      require_repository

      if [[ -n "$branch" ]]; then
        git check-ref-format --branch "$branch" >/dev/null 2>&1 \
          || die "invalid branch name: $branch"
        if git show-ref --verify --quiet "refs/heads/$branch"; then
          die "branch already exists: $branch"
        fi
      fi

      if [[ -n "$base" ]]; then
        git rev-parse --verify --quiet "$base^{commit}" >/dev/null \
          || die "base does not resolve to a commit: $base"
      fi

      [[ -z "$(git status --porcelain --untracked-files=normal)" ]] \
        || die "the worktree must be clean before receiving patches"

      temporary_directory="$(mktemp -d -t git-patch-wormhole.XXXXXX)"
      download_directory="$temporary_directory/download"
      patch_directory="$temporary_directory/patches"
      mkdir -p -- "$download_directory" "$patch_directory"

      wormhole-rs --no-color receive --noconfirm --out-dir "$download_directory" "$code"

      downloads=("$download_directory"/*)
      if (( ''${#downloads[@]} != 1 )) || [[ ! -f "''${downloads[0]}" ]]; then
        die "the transfer did not contain exactly one archive"
      fi
      archive="''${downloads[0]}"

      unzip -tq "$archive" >/dev/null || die "the received file is not a valid zip archive"
      mapfile -t entries < <(unzip -Z1 "$archive")
      (( ''${#entries[@]} > 0 )) || die "the received archive is empty"
      for entry in "''${entries[@]}"; do
        if [[ "$entry" == */* || "$entry" != *.patch ]]; then
          die "the received archive contains an unexpected entry: $entry"
        fi
      done

      unzip -q "$archive" -d "$patch_directory"
      patches=("$patch_directory"/*.patch)
      [[ -e "''${patches[0]}" ]] || die "the received archive contains no patches"
      (( ''${#patches[@]} == ''${#entries[@]} )) \
        || die "the received archive contains duplicate patch names"

      if [[ -n "$branch" ]]; then
        git switch -c "$branch" "''${base:-HEAD}"
      elif [[ -n "$base" ]]; then
        git checkout "$base"
      fi

      printf 'Applying %d patch(es).\n' "''${#patches[@]}"
      git am "''${patches[@]}"
    }

    case "''${1:-}" in
      send)
        shift
        send_bundle "$@"
        ;;
      receive)
        shift
        receive_bundle "$@"
        ;;
      --help|-h|help)
        usage
        ;;
      "")
        usage >&2
        exit 2
        ;;
      *)
        die "unknown command: $1"
        ;;
    esac
  '';
}
