#!/usr/bin/env bash
# Stage r2sql release trees from a completed build:
#   dist/overlay/  — extract ON TOP OF a radare2 install prefix (libr drop-in):
#                      bin/r2sql[.exe]            (next to radare2[.exe])
#                      <r2-plugin-dir>/core_r2sql.*  (r2's own plugin search dir)
#   dist/pipe/     — standalone pipe-only r2sql[.exe] (needs radare2 on PATH)
#
# The plugin's relative path is derived from the installed prefix layout so the
# overlay drops the plugin exactly where this r2 looks for it — Linux uses
# <libdir>/radare2/<ver>/, Windows uses lib/plugins.
set -euo pipefail

PFX="${GITHUB_WORKSPACE}/r2prefix"

# radare2's system plugin dir, RELATIVE to the prefix, derived from the installed
# layout. We do NOT run radare2 to ask it: `radare2 -H R2_LIBR_PLUGINS` drops into
# the "R2PIPE_(IN|OUT) environment not set" error and exits non-zero whenever
# stdin/stdout are pipes (exactly the CI case), so it is not a reliable oracle.
#   * Windows (meson): <prefix>/lib/plugins
#   * Unix    (meson): <prefix>/<libdir>/radare2/<version>  (libdir = lib, lib64,
#     or lib/<triplet>)
# The catch: the default meson build links the core plugins statically, so on Unix
# <libdir>/radare2/<version> need NOT exist on disk after install (the overlay
# creates it). So we can't just scan for that directory — we reconstruct its path:
#   <version> from the always-present data dir share/radare2/<version>, and
#   <libdir>  from where libr_core actually landed.
if [ -d "${PFX}/lib/plugins" ]; then
  REL_PLUGIN="lib/plugins"
else
  VER_DIR="$(find "${PFX}" -type d -path '*/radare2/*' 2>/dev/null \
               | grep -E '/radare2/[0-9][^/]*$' | head -1)"
  [ -n "${VER_DIR}" ] || { echo "ERROR: cannot determine radare2 version under ${PFX}" >&2; exit 1; }
  R2_VER="$(basename "${VER_DIR}")"

  # Match the library (libr_core.dylib/.so/.a/.6.1.7.dylib …), NOT the header
  # r_core.h — hence the 'lib' prefix, which the Unix shared/static lib always
  # carries and the include never does. (Windows, whose import lib is r_core.lib,
  # took the lib/plugins branch above and never reaches here.)
  CORE_LIB="$(find "${PFX}" -maxdepth 4 -name 'libr_core.*' 2>/dev/null | head -1)"
  [ -n "${CORE_LIB}" ] || { echo "ERROR: libr_core not found under ${PFX}" >&2; exit 1; }
  # CORE_LIB is rooted at ${PFX} (it came from `find "${PFX}"`), so dirname keeps
  # that prefix and the strip below yields the libdir relative to the prefix.
  REL_LIBDIR="$(dirname "${CORE_LIB}")"
  REL_LIBDIR="${REL_LIBDIR#"${PFX}/"}"
  REL_PLUGIN="${REL_LIBDIR}/radare2/${R2_VER}"
fi
echo "radare2 plugin overlay dir: ${REL_PLUGIN}"

# Helper: copy the first path that exists.
copy_first() {
  local dest="$1"; shift
  local src
  for src in "$@"; do
    if [ -f "$src" ]; then cp "$src" "$dest"; return 0; fi
  done
  echo "ERROR: none of these exist: $*" >&2
  return 1
}

rm -rf dist
mkdir -p "dist/overlay/bin" "dist/overlay/${REL_PLUGIN}" "dist/pipe"

# Both flavors come from the SAME build tree (one configure with
# R2SQL_BUILD_FULL=ON): r2sql (pipe), r2sql-full (libr CLI), core_r2sql (plugin).

# --- overlay: full (libr) CLI + in-r2 plugin ---
copy_first "dist/overlay/bin/" \
  build/bin/r2sql-full build/bin/r2sql-full.exe \
  build/bin/Release/r2sql-full.exe build/src/cli/r2sql-full build/src/cli/Release/r2sql-full.exe

copy_first "dist/overlay/${REL_PLUGIN}/" \
  build/bin/core_r2sql.so build/bin/core_r2sql.dylib build/bin/core_r2sql.dll \
  build/bin/Release/core_r2sql.dll build/src/plugin/core_r2sql.so \
  build/src/plugin/Release/core_r2sql.dll

# --- pipe-only: standalone single binary (same build tree) ---
copy_first "dist/pipe/" \
  build/bin/r2sql build/bin/r2sql.exe \
  build/bin/Release/r2sql.exe build/src/cli/r2sql build/src/cli/Release/r2sql.exe

cat > dist/overlay/README.txt <<EOF
r2sql-full — radare2 drop-in (overlay, embedded/libr flavor)

Extract this archive ON TOP OF your radare2 install prefix (the directory
that contains bin/radare2[.exe]). It adds:

  bin/r2sql-full[.exe]          full CLI + HTTP/MCP server (in-process libr)
  ${REL_PLUGIN}/core_r2sql.*    in-r2 plugin (load inside r2: L core_r2sql.<ext>)

Because r2sql-full then sits next to radare2[.exe], the libr backend finds
radare2's data dir (share/) automatically, so the 'types' table and
ordinal imports resolve fully.

Usage:
  r2sql-full -s <file> -q "SELECT name FROM funcs LIMIT 5"
  radare2 <file>     then inside r2:   sql SELECT * FROM funcs

(For a portable build that needs no co-location, see the pipe-only r2sql.)

Built against radare2 ${R2_REF}.
EOF

cat > dist/pipe/README.txt <<EOF
r2sql — pipe-only single binary

A standalone r2sql[.exe] with NO radare2 libraries linked. It drives
radare2 over a pipe (--r2pipe), so it only needs radare2[.exe] somewhere
on PATH at runtime. Place it anywhere.

Usage:
  r2sql -s <file> -q "SELECT name FROM funcs LIMIT 5"

Built against radare2 ${R2_REF} (API-compatible r2 on PATH is sufficient).
EOF

echo "=== staged tree ==="
find dist -type f | sort
