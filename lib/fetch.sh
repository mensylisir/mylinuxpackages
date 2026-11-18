#!/usr/bin/env bash
# Generic download helper with SHA256 verification and a shared cache.
# Sourced by build.sh. Requires: curl, sha256sum.
#
# Recipe contract (sourced as shell):
#   SOURCES=( "filename|url|sha256" ... )   -- sha256 may be SKIP
#   CACHE_DIR                               -- optional, defaults to $WORK/http-cache

# Download one file into the cache, verify checksum, expose its path via
# global SOURCE_PATH. A matching cached file is reused without re-downloading.
mlp_fetch() {
  local name="$1" url="$2" sum="$3"
  local cachedir="${CACHE_DIR:-$WORK/http-cache}"
  mkdir -p "$cachedir"
  local dest="$cachedir/$name"

  # MLP_SKIP_SHA256=1 is for local testing with substitute artifacts only.
  # CI and normal builds must always verify; never set it in production.
  if [[ -f "$dest" ]]; then
    if [[ "$sum" == "SKIP" || "${MLP_SKIP_SHA256:-0}" == "1" ]] || _mlp_verify "$dest" "$sum"; then
      echo "  [cache] $name"
      SOURCE_PATH="$dest"
      return 0
    fi
    echo "  [cache] $name checksum mismatch, re-downloading" >&2
    rm -f "$dest"
  fi

  echo "  [fetch] $name"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
    -o "$dest" "$url" || {
      echo "download failed: $url" >&2
      return 1
    }

  if [[ "$sum" != "SKIP" ]] && ! _mlp_verify "$dest" "$sum"; then
    echo "checksum mismatch: $name (expected $sum)" >&2
    return 1
  fi
  SOURCE_PATH="$dest"
}

_mlp_verify() {
  local file="$1" expected="$2"
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]]
}

# Fetch every SOURCES entry into an associative array keyed by filename.
# Usage: mlp_fetch_all ; then reference "${FETCHED[filename]}"
declare -gA FETCHED
mlp_fetch_all() {
  local entry name url sum
  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name url sum <<<"$entry"
    mlp_fetch "$name" "$url" "$sum"
    FETCHED["$name"]="$SOURCE_PATH"
  done
}

# Extract a .tgz whose contents are under a single package/ prefix into dest.
mlp_extract_tgz() {
  local tgz="$1" dest="$2" tmp
  tmp="$(mktemp -d)"
  tar -xzmf "$tgz" -C "$tmp" --strip-components=1 --touch
  mkdir -p "$dest"
  cp -R "$tmp/." "$dest/"
  chmod 755 "$dest"
  find "$dest" -type d -exec chmod 755 {} +
  clean_dir "$tmp"
}
