#!/usr/bin/env bash
# Check the Swift package, archive it, and attach the archive to the GitHub Release.
# Swift Package Index reads the git tag. An optional registry upload runs when
# SWIFT_REGISTRY_URL is set. See docs/publishing.md.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${root}"

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
elif [[ -n "${1:-}" ]]; then
  echo "usage: scripts/publish.sh [--dry-run]" >&2
  exit 2
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift is not on PATH" >&2
  exit 1
fi

package_name="$(sed -n 's/.*name: "\([^"]*\)".*/\1/p' Package.swift | head -n 1)"
library="$(sed -n 's/.*\.library(name: "\([^"]*\)".*/\1/p' Package.swift | head -n 1)"
version=""
if [[ -f VERSION ]]; then
  version="$(tr -d '[:space:]' < VERSION)"
elif [[ -f src/Version.swift ]]; then
  version="$(sed -n 's/.*= "\([0-9][0-9.]*\)".*/\1/p' src/Version.swift | head -n 1)"
fi
if [[ -z "${package_name}" || -z "${library}" || -z "${version}" ]]; then
  echo "could not read package name, library product, or version" >&2
  exit 1
fi

origin="$(git remote get-url origin)"
origin="${origin%.git}"
origin="${origin#git@github.com:}"
origin="${origin#https://github.com/}"
repo_url="https://github.com/${origin}"

if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  tag_name="${GITHUB_REF_NAME}"
  tag_version="${tag_name#v}"
  if [[ "${tag_version}" != "${version}" ]]; then
    echo "git tag ${tag_name} does not match package version ${version}" >&2
    exit 1
  fi
else
  tag_name="${version}"
fi

swift package dump-package >/dev/null
archive="${TMPDIR:-/tmp}/${package_name}-${version}.zip"
rm -f "${archive}"
swift package archive-source --output "${archive}"

package_id="${SWIFT_PACKAGE_ID:-leo-gan.${package_name}}"
block="$(cat <<EOF
Swift package \`${package_name}\`, product \`${library}\`.

\`\`\`swift
.package(url: "${repo_url}", from: "${version}"),
\`\`\`

Depend on the product \`${library}\`. The Swift Package Index lists the repository after this tag exists. Source archive: \`${package_name}-${version}.zip\`.
EOF
)"
printf '%s\n' "${block}"
echo "source archive: ${archive}"

if [[ -n "${SWIFT_REGISTRY_URL:-}" ]]; then
  echo "registry: ${SWIFT_REGISTRY_URL}"
  echo "package id: ${package_id}"
fi

if [[ "${dry_run}" -eq 1 ]]; then
  echo "dry-run: registry was not called and the release was not changed"
  exit 0
fi

if [[ "${GITHUB_ACTIONS:-}" == "true" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  printf '%s\n' "${block}" | python3 scripts/github_release.py notes --tag "${tag_name}"
  python3 scripts/github_release.py upload --tag "${tag_name}" --file "${archive}"
fi

if [[ -z "${SWIFT_REGISTRY_URL:-}" ]]; then
  echo "SWIFT_REGISTRY_URL is unset. Swift Package Manager installs from the git tag."
  exit 0
fi

if [[ -n "${SWIFT_REGISTRY_TOKEN:-}" ]]; then
  swift package-registry login "${SWIFT_REGISTRY_URL}" --token "${SWIFT_REGISTRY_TOKEN}" --no-confirm
elif [[ -n "${SWIFT_REGISTRY_USERNAME:-}" && -n "${SWIFT_REGISTRY_PASSWORD:-}" ]]; then
  swift package-registry login "${SWIFT_REGISTRY_URL}" \
    --username "${SWIFT_REGISTRY_USERNAME}" \
    --password "${SWIFT_REGISTRY_PASSWORD}" \
    --no-confirm
else
  echo "SWIFT_REGISTRY_URL is set but SWIFT_REGISTRY_TOKEN or username and password are missing" >&2
  exit 1
fi

swift package-registry publish "${package_id}" "${version}" --url "${SWIFT_REGISTRY_URL}"
