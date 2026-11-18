#!/usr/bin/env bash
# Generic download helper with checksum verification and a shared cache.
# Sourced by build.sh. Requires: curl, sha256sum (b2sum optional).
#
# SOURCES entry format:  "filename|url|checksum"
#   url       https://...  -> downloaded with curl
#             local:NAME   -> copied from the recipe dir (PKG_DIR/NAME)
#   checksum  <64 hex>     -> sha256 (default)
#             b2:<128 hex> -> blake2b-512 (used by some upstreams, e.g. Trae)
#             SKIP         -> no verification (discouraged; local tests only)
#
# CACHE_DIR defaults to $WORK/http-cache. Fetched paths land in FETCHED[name].
mlp_fetch() {
  local name="$1" url="$2" sum="$3"
  local cachedir="${CACHE_DIR:-$WORK/http-cache}"
  mkdir -p "$cachedir"
  local dest="$cachedir/$name"

  if [[ -f "$dest" ]]; then
    if _mlp_accept "$dest" "$sum"; then
      echo "  [cache] $name" >&2
      SOURCE_PATH="$dest"
      return 0
    fi
    echo "  [cache] $name checksum mismatch, re-downloading" >&2
    rm -f "$dest"
  fi

  if [[ "$url" == local:* ]]; then
    local src="${url#local:}"
    [[ -f "${PKG_DIR:-.}/$src" ]] || { echo "local source missing: $src" >&2; return 1; }
    cp "${PKG_DIR:-.}/$src" "$dest"
  else
    echo "  [fetch] $name" >&2
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
      -o "$dest" "$url" || { echo "download failed: $url" >&2; return 1; }
  fi

  if ! _mlp_accept "$dest" "$sum"; then
    echo "checksum mismatch: $name (expected $sum)" >&2
    return 1
  fi
  SOURCE_PATH="$dest"
}

_mlp_accept() {
  local file="$1" expected="$2"
  [[ "$expected" == "SKIP" || "${MLP_SKIP_SHA256:-0}" == "1" ]] && return 0
  local actual
  if [[ "$expected" == b2:* ]]; then
    need b2sum "coreutils"
    actual="$(b2sum "$file" | awk '{print $1}')"
    [[ "$actual" == "${expected#b2:}" ]]
  else
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]]
  fi
}

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
