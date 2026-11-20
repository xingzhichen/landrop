#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/release_tag.sh"

if (($# < 2)); then
  echo "usage: $0 <semver-tag> <asset> [asset ...]" >&2
  exit 2
fi

tag="$1"
shift
if ! release_tag_is_valid "$tag"; then
  echo "invalid release tag: $tag" >&2
  exit 2
fi
version="${tag#v}"
release_version="${version%%[-+]*}"
release_line="${release_version%.*}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
notes_file="$repo_root/RELEASE-${release_line}.md"
title="LanDrop ${version}"
prerelease_version="${version%%+*}"
prerelease=0
if [[ "$prerelease_version" == *-* ]]; then prerelease=1; fi

if [[ ! -f "$notes_file" ]]; then
  echo "release notes file not found: $notes_file" >&2
  exit 2
fi
for asset in "$@"; do
  if [[ ! -f "$asset" ]]; then
    echo "release asset not found: $asset" >&2
    exit 2
  fi
done

if gh release view "$tag" >/dev/null 2>&1; then
  if ((prerelease)); then
    gh release edit "$tag" --title "$title" --notes-file "$notes_file" --prerelease
  else
    gh release edit "$tag" --title "$title" --notes-file "$notes_file" --prerelease=false
  fi
else
  # Create metadata first; a later upload failure is safe to retry because the
  # next run sees the release and uploads assets with --clobber.
  create_args=("$tag" --verify-tag --title "$title" --notes-file "$notes_file")
  if ((prerelease)); then create_args+=(--prerelease); fi
  gh release create "${create_args[@]}"
fi

gh release upload "$tag" "$@" --clobber
