#!/usr/bin/env bash

release_tag_is_valid() {
  local tag="${1:-}"
  local numeric='(0|[1-9][0-9]*)'
  local nonnumeric='[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*'
  local prerelease_identifier="(${numeric}|${nonnumeric})"
  local build_identifier='[0-9A-Za-z-]+'
  local pattern="^v${numeric}\\.${numeric}\\.${numeric}(-${prerelease_identifier}(\\.${prerelease_identifier})*)?(\\+${build_identifier}(\\.${build_identifier})*)?$"
  [[ "$tag" =~ $pattern ]]
}
