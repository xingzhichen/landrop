#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/release_tag.sh"

if (($# < 1 || $# > 2)); then
  echo "usage: $0 <semver-tag> [pubspec-file]" >&2
  exit 2
fi

tag="$1"
if ! release_tag_is_valid "$tag"; then
  echo "invalid release tag: $tag" >&2
  exit 2
fi

tag_version="${tag#v}"
release_version="${tag_version%%+*}"
if (($# == 2)); then
  pubspec_file="$2"
else
  project_root="$(cd "$(dirname "$0")/.." && pwd)"
  pubspec_file="$project_root/pubspec.yaml"
fi
if [[ ! -f "$pubspec_file" ]]; then
  echo "pubspec file not found: $pubspec_file" >&2
  exit 2
fi
pubspec_version="$(awk '$1 == "version:" { print $2; exit }' "$pubspec_file")"
pubspec_version="${pubspec_version#\"}"
pubspec_version="${pubspec_version%\"}"
pubspec_version="${pubspec_version#\'}"
pubspec_version="${pubspec_version%\'}"
app_version="${pubspec_version%%+*}"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "invalid app version in pubspec.yaml: $pubspec_version" >&2
  exit 2
fi
if [[ "$release_version" != "$app_version" ]]; then
  echo "release tag $tag does not match app version $app_version" >&2
  exit 1
fi

echo "Release tag $tag matches app version $app_version"
