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
      git patch-wormhole send <base>:<branch>:<revision-range> [...]
      git patch-wormhole send [<git-format-patch argument>...]
      git patch-wormhole receive <code> [--branch <name>] [--base <revision>]

    A base:branch:revision-range argument describes one head. send stores the exact
    base commit, formats the selected commits, and can bundle any number of heads.
    Leave branch empty (base::revision-range) to receive that head detached.

    The second send form creates a legacy single-head archive. receive applies a
    multi-head archive according to its stored bases and branch names. --branch and
    --base apply only to legacy archives.

    Examples:
      git patch-wormhole send main:feature:main..feature
      git patch-wormhole send main:feature:main..feature release:fix:release..fix
      git patch-wormhole send main::main..experiment
      git patch-wormhole send main..feature
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

    is_head_specification() {
      local remainder
      remainder="''${1#*:}"
      [[ "$remainder" != "$1" && "$remainder" == *:* ]]
    }

    send_legacy_bundle() {
      local patch_directory archive
      local -a patches

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

    send_multi_head_bundle() {
      local bundle_directory archive manifest
      local specification remainder base branch revision_range base_oid
      local head_directory head_id patch_id patch
      local head_count=0
      local patch_count=0
      local -a patches

      bundle_directory="$temporary_directory/bundle"
      archive="$temporary_directory/git-patches.zip"
      manifest="$bundle_directory/manifest"
      mkdir -p -- "$bundle_directory"
      printf 'git-patch-wormhole-bundle-v1\n' >"$manifest"

      for specification in "$@"; do
        remainder="''${specification#*:}"
        base="''${specification%%:*}"
        branch="''${remainder%%:*}"
        revision_range="''${remainder#*:}"

        [[ -n "$base" ]] || die "a head specification has an empty base: $specification"
        [[ -n "$revision_range" ]] \
          || die "a head specification has an empty revision range: $specification"
        if [[ -n "$branch" ]]; then
          git check-ref-format --branch "$branch" >/dev/null 2>&1 \
            || die "invalid branch name in head specification: $branch"
        fi
        base_oid="$(git rev-parse --verify "$base^{commit}")" \
          || die "base does not resolve to a commit: $base"

        ((head_count += 1))
        printf -v head_id '%04d' "$head_count"
        head_directory="$temporary_directory/head-$head_id"
        mkdir -p -- "$head_directory"

        git format-patch --output-directory "$head_directory" "$revision_range" >/dev/null
        patches=("$head_directory"/*.patch)
        [[ -e "''${patches[0]}" ]] \
          || die "the revision selection for head $head_id produced no patches: $revision_range"

        printf '%s\n' "$head_id" >>"$manifest"
        printf '%s\n' "$base_oid" >"$bundle_directory/head-$head_id-base"
        printf '%s' "$branch" >"$bundle_directory/head-$head_id-branch"

        patch_id=0
        for patch in "''${patches[@]}"; do
          ((patch_id += 1))
          ((patch_count += 1))
          printf -v destination 'head-%s-%04d.patch' "$head_id" "$patch_id"
          mv -- "$patch" "$bundle_directory/$destination"
        done
      done

      (
        cd "$bundle_directory"
        zip -q "$archive" -- ./*
      )

      printf 'Sending %d head(s) containing %d patch(es). The recipient code follows.\n' \
        "$head_count" "$patch_count"
      wormhole-rs --no-color send --no-qr --rename git-patches.zip "$archive"
    }

    send_bundle() {
      local argument
      local any_head_specification=false
      local all_head_specifications=true

      (( $# > 0 )) || die "send requires a head specification or Git revision selection"
      require_repository

      for argument in "$@"; do
        if is_head_specification "$argument"; then
          any_head_specification=true
        else
          all_head_specifications=false
        fi
      done
      if "$any_head_specification" && ! "$all_head_specifications"; then
        die "cannot mix base:branch:revision-range arguments with legacy format-patch arguments"
      fi

      temporary_directory="$(mktemp -d -t git-patch-wormhole.XXXXXX)"
      if "$all_head_specifications"; then
        send_multi_head_bundle "$@"
      else
        send_legacy_bundle "$@"
      fi
    }

    validate_branch() {
      local branch="$1"
      local existing

      [[ -n "$branch" ]] || return 0
      git check-ref-format --branch "$branch" >/dev/null 2>&1 \
        || die "invalid branch name in archive: $branch"
      if git show-ref --verify --quiet "refs/heads/$branch"; then
        die "branch already exists: $branch"
      fi
      for existing in "''${validated_branches[@]}"; do
        [[ "$existing" != "$branch" ]] || die "duplicate branch name in archive: $branch"
      done
      validated_branches+=("$branch")
    }

    receive_multi_head_bundle() {
      local patch_directory="$1"
      local entry_count="$2"
      local expected_id id base branch resolved_base expected_entry_count=1
      local index result
      local -a manifest_lines head_ids head_bases head_branches patches
      validated_branches=()

      mapfile -t manifest_lines <"$patch_directory/manifest"
      (( ''${#manifest_lines[@]} > 1 )) || die "the multi-head archive contains no heads"
      [[ "''${manifest_lines[0]}" == "git-patch-wormhole-bundle-v1" ]] \
        || die "the archive has an unsupported manifest version"

      for ((index = 1; index < ''${#manifest_lines[@]}; index++)); do
        id="''${manifest_lines[$index]}"
        printf -v expected_id '%04d' "$index"
        [[ "$id" == "$expected_id" ]] \
          || die "the archive manifest contains an invalid head identifier: $id"
        [[ -f "$patch_directory/head-$id-base" ]] \
          || die "head $id has no base metadata"
        [[ -f "$patch_directory/head-$id-branch" ]] \
          || die "head $id has no branch metadata"

        base="$(<"$patch_directory/head-$id-base")"
        branch="$(<"$patch_directory/head-$id-branch")"
        [[ "$base" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] \
          || die "head $id has an invalid base commit"
        resolved_base="$(git rev-parse --verify "$base^{commit}")" \
          || die "base commit for head $id is not available: $base"
        [[ "$resolved_base" == "$base" ]] \
          || die "base for head $id does not resolve to its stored commit: $base"
        validate_branch "$branch"

        patches=("$patch_directory"/head-"$id"-[0-9][0-9][0-9][0-9].patch)
        [[ -e "''${patches[0]}" ]] || die "head $id contains no patches"
        ((expected_entry_count += 2 + ''${#patches[@]}))
        head_ids+=("$id")
        head_bases+=("$base")
        head_branches+=("$branch")
      done

      (( expected_entry_count == entry_count )) \
        || die "the multi-head archive contains unreferenced or duplicate entries"

      for index in "''${!head_ids[@]}"; do
        id="''${head_ids[$index]}"
        base="''${head_bases[$index]}"
        branch="''${head_branches[$index]}"
        patches=("$patch_directory"/head-"$id"-[0-9][0-9][0-9][0-9].patch)

        if [[ -n "$branch" ]]; then
          git switch -c "$branch" "$base"
          printf 'Applying %d patch(es) for head %s on branch %s.\n' \
            "''${#patches[@]}" "$id" "$branch"
        else
          git checkout --detach "$base"
          printf 'Applying %d patch(es) for head %s on a detached HEAD.\n' \
            "''${#patches[@]}" "$id"
        fi
        git am "''${patches[@]}"
        result="$(git rev-parse HEAD)"
        if [[ -n "$branch" ]]; then
          printf 'Created branch %s at %s.\n' "$branch" "$result"
        else
          printf 'Created detached head %s. Create a branch to retain it.\n' "$result"
        fi
      done
    }

    receive_legacy_bundle() {
      local patch_directory="$1"
      local branch="$2"
      local base="$3"
      local -a patches

      patches=("$patch_directory"/*.patch)
      [[ -e "''${patches[0]}" ]] || die "the received archive contains no patches"

      if [[ -n "$branch" ]]; then
        git switch -c "$branch" "''${base:-HEAD}"
      elif [[ -n "$base" ]]; then
        git checkout "$base"
      fi

      printf 'Applying %d patch(es).\n' "''${#patches[@]}"
      git am "''${patches[@]}"
    }

    receive_bundle() {
      local code="" branch="" base=""
      local download_directory patch_directory archive entry
      local has_manifest=false
      local -a downloads entries extracted_entries

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
        [[ -n "$entry" && "$entry" != */* && "$entry" != *\\* ]] \
          || die "the received archive contains an unsafe entry: $entry"
        if [[ "$entry" == "manifest" ]]; then
          has_manifest=true
        fi
      done

      if "$has_manifest"; then
        [[ -z "$branch" && -z "$base" ]] \
          || die "--branch and --base cannot override a multi-head archive"
        for entry in "''${entries[@]}"; do
          if [[ "$entry" != "manifest" \
            && ! "$entry" =~ ^head-[0-9]{4}-(base|branch|[0-9]{4}\.patch)$ ]]; then
            die "the multi-head archive contains an unexpected entry: $entry"
          fi
        done
      else
        for entry in "''${entries[@]}"; do
          [[ "$entry" == *.patch ]] \
            || die "the legacy archive contains an unexpected entry: $entry"
        done
      fi

      unzip -q "$archive" -d "$patch_directory"
      extracted_entries=("$patch_directory"/*)
      (( ''${#extracted_entries[@]} == ''${#entries[@]} )) \
        || die "the received archive contains duplicate entry names"

      if "$has_manifest"; then
        receive_multi_head_bundle "$patch_directory" "''${#entries[@]}"
      else
        receive_legacy_bundle "$patch_directory" "$branch" "$base"
      fi
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
