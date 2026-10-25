#!/usr/bin/env bash
# =============================================================================
# build-gnustep-support.sh — cross-build driver for nextbsd-gnustep-support
# =============================================================================
#
# Builds the libraries GNUstep needs on NextBSD (E24, nextbsd/nextbsd#574, plan
# step 9) for ONE architecture, from pinned upstream release tarballs, into the
# /usr prefix with upstream sonames; cairo, which needs X, goes into /usr/X11
# beside nextbsd-xlibs. Layout and checks follow the nextbsd-xlibs reference
# (wiki: Source-Repo-Conventions).
#
# For each component, in COMPONENTS order:
#   1. fetch:   download the tarball named in sources.lock, refuse it unless
#               its SHA-256 matches, unpack it under .build/src/;
#   2. patch:   apply patches/<name>/series in order (each patch must state
#               its Origin:);
#   3. build:   the upstream build system as it is, out of tree: autotools
#               (cross/autotools/<arch>.site, --host=<triple>), CMake
#               (cross/cmake/<arch>.cmake) or meson (cross/meson/<arch>.ini),
#               installed with DESTDIR into .build/<name>-root-<arch>/,
#               under the component's prefix (/usr, or /usr/X11 for cairo);
#   4. stage:   check and tidy that install, then copy it into $SYSROOT (so
#               later components find its headers, .pc files and libraries)
#               and into $DESTDIR (the published artifact).
#
# Nothing here uses FreeBSD packages, the ports tree or ports tools, and
# nothing links against nextbsd-userland: these components need only the
# NextBSD base (compat) sysroot (libc, libm, libthr, zlib, liblzma) and each
# other, plus, for cairo, nextbsd-displayserver-support (pixman, freetype,
# fontconfig and expat in /usr) and nextbsd-xlibs (the X libraries in
# /usr/X11). Base's ICU, libxml2, libxslt, libffi and
# curl are GNUstep's own dependencies, not these libraries'.
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-toolchain container (pinned clang/lld 19.1.7 in
#   $CROSS_BINDIR, meson, ninja, cmake, pkgconf, autotools), with compat's
#   `continuous` base, nextbsd-displayserver-support's and nextbsd-xlibs'
#   `continuous` artifacts extracted into $SYSROOT, in that order. $SYSROOT is
#   scratch: this script installs every component into it as it goes. The
#   displayserver-support and xlibs files are build input only and never
#   reach $DESTDIR.
#
# USAGE
#   ./build-gnustep-support.sh            every component, in COMPONENTS order
#   ./build-gnustep-support.sh gnutls     named components only (their
#                                         dependencies must already be in
#                                         $SYSROOT/usr)
# =============================================================================

set -euo pipefail

# ---- required environment ----------------------------------------------------
: "${T:?set T to the target (amd64 / arm64)}"
: "${TA:?set TA to the target_arch (amd64 / aarch64)}"
: "${SYSROOT:?set SYSROOT to the staged NextBSD base}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
: "${DESTDIR:=/stage}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build"
DL="$BUILD/dl"
LOCK="$ROOT/sources.lock"
PATCHES="$ROOT/patches"
GS_CROSS="$ROOT/cross"

# Install prefixes (plan Q7): /usr for libraries that don't need X. Their .pc
# files go in FreeBSD base's /usr/libdata/pkgconfig whatever the upstream
# default, so one directory goes on pkgconf's path. Libraries that need X
# (cairo) go in /usr/X11 beside nextbsd-xlibs, with their .pc files in
# /usr/X11/lib/pkgconfig as xlibs has them (wiki: Source-Repo-Conventions).
# fresh_dirs sets COMP_PREFIX and COMP_PCDIR, the pair for the component being
# built; stage and soname_check use them.
PREFIX=/usr
PCDIR=$PREFIX/libdata/pkgconfig
X_PREFIX=/usr/X11
X_PCDIR=$X_PREFIX/lib/pkgconfig

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd ;;
    *)     echo "FAIL: unsupported T=$T (amd64 / arm64)" >&2; exit 1 ;;
esac
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS=-j"$(nproc 2>/dev/null || echo 2)"

SYSROOT="$(cd "$SYSROOT" && pwd)"
export SYSROOT DESTDIR CROSS_BINDIR GS_CROSS

# pkgconf only, and only the sysroot's .pc directories (base,
# nextbsd-displayserver-support and this repo, then NextBSD X for cairo):
# never the build host's. /usr/libdata/pkgconfig comes first, so while
# nextbsd-xlibs still ships its own /usr/X11 copies of pixman, freetype,
# fontconfig and expat (until nextbsd-xlibs#9), cairo resolves /usr's.
export PKG_CONFIG=pkgconf
export PKG_CONFIG_LIBDIR="$SYSROOT$PCDIR:$SYSROOT$X_PCDIR"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
unset PKG_CONFIG_PATH

READELF="$CROSS_BINDIR/llvm-readelf"

# ---- helpers -----------------------------------------------------------------
comp() { echo; echo "==> [$T/$TA] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# lock_field <name> <version|sha256|url>: a component's pin from sources.lock.
lock_field() {
    local name="$1" field="$2" col
    case "$field" in
        version) col=2 ;;
        sha256)  col=3 ;;
        url)     col=4 ;;
        *)       fail "lock_field: unknown field $field" ;;
    esac
    awk -v n="$name" -v c="$col" '$1 == n && $1 !~ /^#/ { print $c; found=1 } END { exit !found }' "$LOCK" \
        || fail "$name is not pinned in sources.lock"
}

# Assert a staged object links a given library (a cross `readelf -d` check; we
# cannot exec target binaries on the runner).
needed_check() {
    local obj="$1" want="$2"
    "$READELF" -d "$obj" 2>/dev/null | grep -q "NEEDED.*\[$want" \
        || fail "$obj missing DT_NEEDED $want"
    note "DT_NEEDED ok: $(basename "$obj") -> $want"
}

# needed_resolve_check <obj>: every DT_NEEDED of a staged object is a library
# the target has in /lib, /usr/lib or /usr/X11/lib (base, this repo,
# nextbsd-xlibs; all in $SYSROOT by now), and the object carries no
# DT_RPATH/DT_RUNPATH. rtld finds /usr/X11/lib through the ldconfig hints, as
# it does for xlibs' own libraries (nextbsd/nextbsd-overlays#22), so nothing
# may record a build path or a private search path.
needed_resolve_check() {
    local obj="$1" dyn n d found
    dyn=$("$READELF" -d "$obj") || fail "$obj: cannot read its dynamic section"
    if printf '%s\n' "$dyn" | grep -E '\((RPATH|RUNPATH)\)'; then
        fail "$(basename "$obj") carries an RPATH/RUNPATH"
    fi
    for n in $(printf '%s\n' "$dyn" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p'); do
        found=
        for d in /lib /usr/lib "$X_PREFIX/lib"; do
            if [ -e "$SYSROOT$d/$n" ]; then found=$d; break; fi
        done
        [ -n "$found" ] || fail "$(basename "$obj"): DT_NEEDED $n is in none of /lib, /usr/lib, $X_PREFIX/lib"
    done
    note "DT_NEEDED resolve, no RPATH/RUNPATH: $(basename "$obj")"
}

# soname_check <lib> <soname>: the staged library (by its development link in
# the component's lib directory, $DESTDIR/usr/lib or $DESTDIR/usr/X11/lib)
# carries the upstream soname, and the soname link exists.
soname_check() {
    local lib="$DESTDIR$COMP_PREFIX/lib/$1" want="$2"
    [ -e "$lib" ] || fail "$1 was not staged"
    "$READELF" -d "$lib" 2>/dev/null | grep -q "SONAME.*\[$want\]" \
        || fail "$1 does not have SONAME $want"
    [ -e "$DESTDIR$COMP_PREFIX/lib/$want" ] || fail "$want was not staged"
    note "SONAME ok: $want"
}

# pc_check <module> [version]: the staged .pc resolves through pkgconf the way
# later components (and builds on the machine) see it, and, if given, at that
# version.
pc_check() {
    local mod="$1" want="${2:-}" got
    got=$(pkgconf --modversion "$mod") || fail "pkgconf cannot resolve $mod"
    pkgconf --cflags --libs "$mod" >/dev/null || fail "pkgconf cannot resolve $mod's dependencies"
    [ -z "$want" ] || [ "$got" = "$want" ] || fail "$mod.pc is version $got, expected $want"
    note "pkgconf ok: $mod $got"
}

# fetch <name>: download (cached in .build/dl), verify and unpack the pinned
# tarball, apply the patch series. Sets SRC_DIR and VERSION.
fetch() {
    local name="$1" url sha file got
    VERSION=$(lock_field "$name" version)
    url=$(lock_field "$name" url)
    sha=$(lock_field "$name" sha256)
    file="$DL/$(basename "$url")"
    mkdir -p "$DL"
    if [ ! -f "$file" ]; then
        note "fetch $url"
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    got=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { rm -f "$file"; fail "$name: SHA-256 mismatch for $(basename "$file") (got $got, sources.lock has $sha)"; }
    note "$name $VERSION, sha256 ok"
    SRC_DIR="$BUILD/src/$name-$VERSION"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    tar -xf "$file" -C "$SRC_DIR" --strip-components=1
    apply_patches "$name"
}

# apply_patches <name>: patches/<name>/series lists the patches in order, one
# per line (# comments allowed). Every *.patch in the directory must be listed,
# and every patch must say where it came from in an `Origin:` header line
# (DEP-3 style: upstream commit or MR, a FreeBSD port file used as a reference,
# or "NextBSD" for our own).
apply_patches() {
    local name="$1" dir="$PATCHES/$1" p n=0
    [ -d "$dir" ] || return 0
    [ -f "$dir/series" ] || fail "patches/$name has no series file"
    for p in "$dir"/*.patch; do
        [ -e "$p" ] || continue
        grep -qx "$(basename "$p")" "$dir/series" || fail "patches/$name/$(basename "$p") is not listed in series"
    done
    while read -r p; do
        case "$p" in ''|'#'*) continue ;; esac
        [ -f "$dir/$p" ] || fail "patches/$name/series lists missing $p"
        grep -q '^Origin:' "$dir/$p" || fail "patches/$name/$p has no Origin: line"
        patch -d "$SRC_DIR" -p1 --forward --batch --quiet < "$dir/$p" || fail "patches/$name/$p does not apply"
        note "patch $p"
        n=$((n + 1))
    done < "$dir/series"
    note "$n patch(es) applied"
}

# csv_list <words...>: the words joined with commas (component lists for
# configure options).
csv_list() { local IFS=,; echo "$*"; }

# fresh_dirs <name> [prefix]: fresh out-of-tree build and install-root
# directories for a component, and its install prefix (default /usr; /usr/X11
# for a library that needs X) with that prefix's .pc directory.
fresh_dirs() {
    local name="$1"
    COMP_PREFIX="${2:-$PREFIX}"
    case "$COMP_PREFIX" in
        "$PREFIX")   COMP_PCDIR=$PCDIR ;;
        "$X_PREFIX") COMP_PCDIR=$X_PCDIR ;;
        *)           fail "$name: install prefix $COMP_PREFIX is neither $PREFIX nor $X_PREFIX" ;;
    esac
    COMP_BUILD="$BUILD/$name-$T"
    COMP_ROOT="$BUILD/$name-root-$T"
    rm -rf "$COMP_BUILD" "$COMP_ROOT"
    mkdir -p "$COMP_BUILD" "$COMP_ROOT"
}

# autotools_build [configure options...]: upstream configure in --host mode with
# the arch's CONFIG_SITE, out of tree; make; make install into $COMP_ROOT.
autotools_build() {
    (
        cd "$COMP_BUILD"
        CONFIG_SITE="$GS_CROSS/autotools/$T.site" \
        "$SRC_DIR/configure" \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --with-sysroot="$SYSROOT" \
            --prefix="$PREFIX" --libdir="$PREFIX/lib" \
            --mandir="$PREFIX/share/man" \
            --enable-shared --disable-static \
            --disable-dependency-tracking --disable-silent-rules \
            "$@"
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
}

# cmake_build [cmake -D options...]: configure, build and install $SRC_DIR into
# $COMP_ROOT with the arch's CMake toolchain file (it reads $SYSROOT and
# $CROSS_BINDIR from the environment).
cmake_build() {
    cmake -S "$SRC_DIR" -B "$COMP_BUILD" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$GS_CROSS/cmake/$T.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_MANDIR=share/man \
        -DBUILD_SHARED_LIBS=ON \
        "$@"
    cmake --build "$COMP_BUILD" $JOBS
    DESTDIR="$COMP_ROOT" cmake --install "$COMP_BUILD"
}

# meson_build [meson -D options...]: configure, build and install $SRC_DIR into
# $COMP_ROOT under $COMP_PREFIX with the arch's cross files. The first is
# generated here and carries this run's paths (sysroot, LLVM binaries); the
# second is the checked-in cross/meson/<arch>.ini, which uses them.
meson_build() {
    local paths="$BUILD/cross/paths-$T.ini"
    mkdir -p "$BUILD/cross"
    cat > "$paths" <<EOF
[constants]
sysroot = '$SYSROOT'
llvm_bindir = '$CROSS_BINDIR'
EOF
    meson setup "$COMP_BUILD" "$SRC_DIR" \
        --cross-file "$paths" --cross-file "$GS_CROSS/meson/$T.ini" \
        --prefix="$COMP_PREFIX" --libdir=lib --mandir=share/man \
        --buildtype=release -Ddefault_library=shared --wrap-mode=nodownload \
        "$@"
    meson compile -C "$COMP_BUILD"
    DESTDIR="$COMP_ROOT" meson install -C "$COMP_BUILD" --no-rebuild
}

# The base's own files (compat, plus the nextbsd-displayserver-support and
# nextbsd-xlibs artifacts CI stages over it), listed while the sysroot doesn't
# yet hold anything this script installs, so stage can refuse a component that would overwrite one. A later
# partial run reuses the list.
base_list() {
    BASE_LIST="$BUILD/base-files-$T.list"
    if [ ! -e "$SYSROOT$PREFIX/include/gif_lib.h" ]; then
        (cd "$SYSROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort) > "$BASE_LIST"
    elif [ ! -f "$BASE_LIST" ]; then
        fail "$SYSROOT already holds this repo's files but $BASE_LIST is missing; start from a fresh compat base"
    fi
}

# stage <name>: tidy and check $COMP_ROOT, then copy it into $SYSROOT (for the
# components after this one) and $DESTDIR (the artifact).
#   - everything must be under the component's prefix ($COMP_PREFIX: /usr, or
#     /usr/X11 for cairo), and nothing may replace a base,
#     displayserver-support or xlibs file;
#   - libtool .la files, docs and info manuals are dropped (man pages are kept);
#   - .pc files move to the prefix's .pc directory ($COMP_PCDIR:
#     /usr/libdata/pkgconfig, or /usr/X11/lib/pkgconfig) and must say
#     prefix=$COMP_PREFIX;
#   - no .pc file may name /usr/local or a build-host path.
stage() {
    local name="$1" p="$COMP_PREFIX" x="$COMP_ROOT$COMP_PREFIX" stray f clash
    [ -d "$x" ] || fail "$name installed nothing under $p"
    # ./usr itself is allowed: it is the parent of /usr/X11.
    stray=$(cd "$COMP_ROOT" && find . -mindepth 1 ! -path ./usr ! -path ".$p" ! -path ".$p/*")
    [ -z "$stray" ] || fail "$name installed outside $p: $stray"
    find "$x" -name '*.la' -delete
    rm -rf "$x/share/doc" "$x/share/info"
    # meson puts a library's .pc in libdata/pkgconfig when host_machine is
    # freebsd (the base layout), whatever the prefix.
    for f in lib/pkgconfig share/pkgconfig libdata/pkgconfig; do
        [ "$p/$f" = "$COMP_PCDIR" ] && continue
        if [ -d "$x/$f" ]; then
            mkdir -p "$COMP_ROOT$COMP_PCDIR"
            mv "$x/$f"/*.pc "$COMP_ROOT$COMP_PCDIR/"
            rmdir "$x/$f"
        fi
    done
    for f in "$COMP_ROOT$COMP_PCDIR"/*.pc; do
        [ -e "$f" ] || continue
        [ -L "$f" ] && continue
        grep -q "^prefix=$p\$" "$f" || fail "$(basename "$f"): prefix is not $p"
        if grep -n -F -e /usr/local -e "$ROOT" -e "$SYSROOT" "$f"; then
            fail "$(basename "$f") names /usr/local or a build-host path"
        fi
    done
    find "$x" -type d -empty -delete
    clash=$(cd "$COMP_ROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort | LC_ALL=C comm -12 - "$BASE_LIST")
    [ -z "$clash" ] || fail "$name would replace files of the NextBSD base: $clash"
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$SYSROOT" && tar -xf -)
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -)
    note "staged $(cd "$COMP_ROOT" && find . ! -type d | wc -l) files, $(du -sk --apparent-size "$COMP_ROOT" | cut -f1) KiB"
}

# =============================================================================
# Host build tools (built on the runner, never shipped)
# =============================================================================
# NASM for libjpeg-turbo's x86-64 SIMD and FFmpeg's x86-64 assembly (amd64
# only; on arm64 libjpeg-turbo's Neon code uses compiler intrinsics and
# FFmpeg's is GNU-syntax assembly clang builds). Pinned in sources.lock and
# built with the runner's cc until the toolchain image carries it.
host_nasm() {
    NASM="$BUILD/host/bin/nasm"
    if [ -x "$NASM" ] && "$NASM" -v | grep -q "version $(lock_field nasm version) "; then
        return 0
    fi
    comp "nasm $(lock_field nasm version) [host tool]"
    fetch nasm
    (
        cd "$SRC_DIR"
        ./configure --prefix="$BUILD/host" >/dev/null
        make $JOBS nasm
    )
    mkdir -p "$BUILD/host/bin"
    install -m 0755 "$SRC_DIR/nasm" "$NASM"
    note "$("$NASM" -v)"
}

# =============================================================================
# Components, in build order (plan step 9): giflib, jpeg, png, gmp,
# libsndfile, libao, sqlite; then libtiff (jpeg) and nettle (gmp); then GnuTLS;
# then cairo (png, and nextbsd-xlibs); then flite and FFmpeg.
# No component has a D-Bus, Avahi or GLib option left on.
# =============================================================================

# giflib — upstream's plain GNU Makefile (it has no configure), library and
# header only: upstream's `all` also builds the utilities, a second shared
# library named libutil (which would clash with base's libutil) and docs that
# want xmlto. The cross compiler comes from the same CONFIG_SITE file the
# autotools builds use.
build_giflib() {
    comp "giflib [makefile cross]"
    fresh_dirs giflib
    fetch giflib
    (
        # shellcheck source=/dev/null
        . "$GS_CROSS/autotools/$T.site"
        make -C "$SRC_DIR" $JOBS libgif.so \
            CC="$CC" AR="$AR" LDFLAGS="$LDFLAGS" \
            CFLAGS="-std=gnu99 -fPIC -Wall -O2 -pipe -DHAVE_REALLOCARRAY"
        make -C "$SRC_DIR" install-include install-shared-lib \
            PREFIX="$PREFIX" DESTDIR="$COMP_ROOT"
    )
    stage giflib
    soname_check libgif.so libgif.so.7
    test -f "$DESTDIR$PREFIX/include/gif_lib.h" || fail "gif_lib.h not staged"
}

# libjpeg-turbo — CMake. libjpeg.so.8 (the jpeg8 ABI, as FreeBSD and most
# distributions ship it); no TurboJPEG API, tools or tests. SIMD is required:
# NASM on amd64, Neon intrinsics on arm64.
build_libjpeg_turbo() {
    comp "libjpeg-turbo [cmake cross]"
    local simd=()
    if [ "$T" = amd64 ]; then
        host_nasm
        simd=(-DCMAKE_ASM_NASM_COMPILER="$NASM")
    fi
    fresh_dirs libjpeg-turbo
    fetch libjpeg-turbo
    cmake_build \
        -DENABLE_SHARED=ON -DENABLE_STATIC=OFF \
        -DWITH_JPEG8=ON -DWITH_TURBOJPEG=OFF \
        -DWITH_TOOLS=OFF -DWITH_TESTS=OFF \
        -DWITH_SIMD=ON -DREQUIRE_SIMD=ON \
        "${simd[@]}"
    stage libjpeg-turbo
    soname_check libjpeg.so libjpeg.so.8
    pc_check libjpeg
}

# libpng — autotools (the release's generated configure). zlib from base.
build_libpng() {
    comp "libpng [autotools cross]"
    fresh_dirs libpng
    fetch libpng
    autotools_build --disable-tests --disable-tools
    stage libpng
    soname_check libpng16.so libpng16.so.16
    needed_check "$DESTDIR$PREFIX/lib/libpng16.so.16" libz.so
    pc_check libpng16 "$VERSION"
    pc_check libpng
}

# gmp — autotools. A fat library on amd64 (it picks its kernels for the CPU at
# run time); the generic aarch64 assembly on arm64, where gmp has no fat
# build. No C++ binding.
build_gmp() {
    comp "gmp [autotools cross]"
    local fat=()
    [ "$T" = amd64 ] && fat=(--enable-fat)
    fresh_dirs gmp
    fetch gmp
    autotools_build --disable-cxx "${fat[@]}"
    stage gmp
    soname_check libgmp.so libgmp.so.10
    pc_check gmp "$VERSION"
}

# libsndfile — CMake. WAV/AIFF/AU/CAF and the other built-in formats; no
# external codecs (FLAC, Vorbis, Opus, MPEG). gnustep-gui builds NSSound only
# when both libsndfile and libao are present.
build_libsndfile() {
    comp "libsndfile [cmake cross]"
    fresh_dirs libsndfile
    fetch libsndfile
    # CPU_CLIPS_*: answers for a check that runs a program. FALSE selects the
    # portable float-to-int conversion, correct on every CPU.
    cmake_build \
        -DENABLE_EXTERNAL_LIBS=OFF -DENABLE_MPEG=OFF -DENABLE_EXPERIMENTAL=OFF \
        -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_REGTEST=OFF \
        -DENABLE_CPACK=OFF -DINSTALL_MANPAGES=OFF -DINSTALL_PKGCONFIG_MODULE=ON \
        -DCPU_CLIPS_POSITIVE=FALSE -DCPU_CLIPS_NEGATIVE=FALSE \
        -DCMAKE_DISABLE_FIND_PACKAGE_ALSA=ON -DCMAKE_DISABLE_FIND_PACKAGE_Sndio=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_SQLite3=ON -DCMAKE_DISABLE_FIND_PACKAGE_Speex=ON
    stage libsndfile
    soname_check libsndfile.so libsndfile.so.1
    pc_check sndfile "$VERSION"
}

# libao — autotools. The OSS output plugin only (/dev/dsp); PulseAudio, ESD,
# aRts, NAS and ALSA are off (PulseAudio would also bring D-Bus, plan D2).
build_libao() {
    comp "libao [autotools cross]"
    fresh_dirs libao
    fetch libao
    autotools_build \
        --disable-pulse --disable-esd --disable-arts --disable-nas \
        --disable-alsa --disable-alsa-mmap --without-x
    # ckport/db/libao.ckport is metadata for RoarAudio's ckport tool, which
    # NextBSD doesn't ship.
    rm -rf "$COMP_ROOT$PREFIX/lib/ckport"
    stage libao
    soname_check libao.so libao.so.4
    [ -f "$DESTDIR$PREFIX/lib/ao/plugins-4/liboss.so" ] || fail "libao's OSS plugin was not staged"
    if find "$DESTDIR$PREFIX/lib/ao/plugins-4" -name '*.so' ! -name liboss.so | grep .; then
        fail "libao plugins other than OSS were staged"
    fi
    pc_check ao "$VERSION"
}

# sqlite — the autosetup "autoconf" bundle (not GNU autoconf, so it doesn't
# read CONFIG_SITE: the same file is sourced into its environment). The
# library, headers and .pc only (no sqlite3 shell), with the traditional
# libsqlite3.so.0 soname. Base keeps its private copy as libprivatesqlite3.
build_sqlite() {
    comp "sqlite [autosetup cross]"
    fresh_dirs sqlite
    fetch sqlite
    (
        set -a
        # shellcheck source=/dev/null
        . "$GS_CROSS/autotools/$T.site"
        set +a
        cd "$COMP_BUILD"
        "$SRC_DIR/configure" \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --prefix="$PREFIX" --libdir="$PREFIX/lib" --mandir="$PREFIX/share/man" \
            --disable-static --soname=legacy --disable-rpath --disable-readline \
            --enable-fts4 --enable-fts5 --enable-rtree --enable-column-metadata
        make $JOBS libsqlite3.so
        make install-dll install-headers install-pc DESTDIR="$COMP_ROOT"
    )
    stage sqlite
    soname_check libsqlite3.so libsqlite3.so.0
    pc_check sqlite3 "$VERSION"
}

# libtiff — CMake. JPEG (this repo), zlib and LZMA (base); jbig, lerc,
# libdeflate, zstd and webp off. No tools, tests, docs or C++ API.
build_libtiff() {
    comp "libtiff [cmake cross]"
    fresh_dirs libtiff
    fetch libtiff
    cmake_build \
        -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
        -Dtiff-cxx=OFF -Dtiff-opengl=OFF -Dsphinx=OFF \
        -Djpeg=ON -Dold-jpeg=ON -Dzlib=ON -Dpixarlog=ON -Dlzma=ON \
        -Djbig=OFF -Dlerc=OFF -Dlibdeflate=OFF -Dzstd=OFF -Dwebp=OFF
    stage libtiff
    soname_check libtiff.so libtiff.so.6
    needed_check "$DESTDIR$PREFIX/lib/libtiff.so.6" libjpeg.so.8
    needed_check "$DESTDIR$PREFIX/lib/libtiff.so.6" libz.so
    needed_check "$DESTDIR$PREFIX/lib/libtiff.so.6" liblzma.so
    pc_check libtiff-4 "$VERSION"
}

# nettle — autotools. nettle and hogweed (public-key, over gmp). Fat on both
# arches (run-time CPU detection for AES, SHA and GHASH). Its small tools
# (nettle-hash, pkcs1-conv, ...) install with it.
build_nettle() {
    comp "nettle [autotools cross]"
    fresh_dirs nettle
    fetch nettle
    autotools_build --enable-public-key --enable-fat --disable-openssl --disable-documentation
    stage nettle
    soname_check libnettle.so libnettle.so.8
    soname_check libhogweed.so libhogweed.so.6
    needed_check "$DESTDIR$PREFIX/lib/libhogweed.so.6" libgmp.so.10
    pc_check nettle "$VERSION"
    pc_check hogweed "$VERSION"
}

# GnuTLS — autotools, minimal (plan Q3): nettle/hogweed and gmp from this
# repo, zlib from base, its bundled libtasn1 and libunistring. p11-kit,
# libidn2, TPM, DANE (unbound), brotli, zstd, the C++ and OpenSSL-compat
# libraries, tools, docs and NLS are off. It trusts the /etc/ssl/certs
# directory base OpenSSL uses (certctl), so GNUstep's NSURLConnection (GnuTLS)
# and NSURLSession (curl, OpenSSL) see one CA set.
build_gnutls() {
    comp "gnutls [autotools cross]"
    fresh_dirs gnutls
    fetch gnutls
    autotools_build \
        --with-included-libtasn1 --with-included-unistring \
        --without-p11-kit --without-idn --without-tpm --without-tpm2 \
        --disable-libdane --without-brotli --without-zstd --with-zlib=link \
        --disable-cxx --disable-openssl-compatibility \
        --disable-doc --disable-manpages --disable-tools --disable-tests \
        --disable-nls --disable-rpath --disable-valgrind-tests \
        --with-default-trust-store-dir=/etc/ssl/certs
    stage gnutls
    local lib="$DESTDIR$PREFIX/lib/libgnutls.so.30"
    soname_check libgnutls.so libgnutls.so.30
    needed_check "$lib" libnettle.so.8
    needed_check "$lib" libhogweed.so.6
    needed_check "$lib" libgmp.so.10
    needed_check "$lib" libz.so
    if "$READELF" -d "$lib" | grep -E 'NEEDED.*\[(libp11-kit|libidn2|libtasn1|libunistring)'; then
        fail "libgnutls links a library that should be off or bundled"
    fi
    grep -q /etc/ssl/certs "$lib" || fail "libgnutls does not carry the /etc/ssl/certs trust store"
    [ ! -e "$DESTDIR$PREFIX/lib/libgnutls-openssl.so" ] || fail "libgnutls-openssl was staged"
    [ ! -e "$DESTDIR$PREFIX/lib/libgnutlsxx.so" ] || fail "libgnutlsxx was staged"
    pc_check gnutls "$VERSION"
}

# cairo — meson, into /usr/X11 (plan Q7: it needs X), beside nextbsd-xlibs.
# From nextbsd-displayserver-support, in /usr (E25): pixman, freetype and
# fontconfig (with expat); from xlibs, in /usr/X11: the X libraries (libX11,
# libXext, libXrender, libxcb with xcb-render and xcb-shm). Both are staged in
# the sysroot by CI and never reach this artifact. libpng from this repo, zlib
# from base. Until nextbsd-xlibs#9 xlibs also carries /usr/X11 copies of the
# first four; pkgconf must resolve them in /usr/libdata/pkgconfig, which
# CAIRO_DS_PCS checks.
#   on:  the image, xlib (with XRender), xcb (with SHM), PNG, PDF, PostScript,
#        SVG, script and tee surfaces; FreeType and fontconfig fonts.
#   off: GLib, and with it cairo-gobject (plan D2 keeps GLib out); LZO (the
#        script surface's optional compression); xlib-xcb (upstream's
#        default); Quartz and DirectWrite (win32 is built only for Windows
#        hosts); libspectre; binutils' bfd symbol lookup in cairo-trace (GPL);
#        the GTK utilities; tests, and with them the poppler, librsvg and
#        ghostscript converters only the tests use; gtk-doc.
# Upstream also installs its script interpreter library (LGPL-2.1/MPL-1.1, like
# the library; kept) and cairo-trace, an LD_PRELOAD debugging tracer
# (bin/cairo-trace, lib/cairo/libcairo-trace.so and libcairo-fdr.so), which is
# GPL-3.0-or-later and has no meson option: it is removed from the install
# root, so nothing GPL ships.
# IPC_RMID_DEFERRED_RELEASE comes from a check that runs a program on the
# target; under cross builds cairo takes it as false, the answer that is safe
# on any kernel (the SHM segment is removed when cairo frees it, not right
# after the X server attaches it).
CAIRO_PCS="cairo cairo-png cairo-ft cairo-fc cairo-xlib cairo-xlib-xrender cairo-xcb
    cairo-xcb-shm cairo-pdf cairo-ps cairo-svg cairo-script cairo-tee cairo-script-interpreter"
CAIRO_DS_PCS="pixman-1 freetype2 fontconfig expat"
CAIRO_FEATURES="XLIB_SURFACE XLIB_XRENDER_SURFACE XCB_SURFACE XCB_SHM_FUNCTIONS PNG_FUNCTIONS
    FT_FONT FC_FONT PDF_SURFACE PS_SURFACE SVG_SURFACE SCRIPT_SURFACE TEE_SURFACE"

build_cairo() {
    comp "cairo [meson cross, $X_PREFIX]"
    local x="$DESTDIR$X_PREFIX" lib="$DESTDIR$X_PREFIX/lib/libcairo.so.2" n f log
    [ -f "$SYSROOT$X_PCDIR/x11.pc" ] \
        || fail "cairo needs nextbsd-xlibs in $SYSROOT$X_PREFIX (CI stages its continuous artifact)"
    for n in $CAIRO_DS_PCS; do
        [ -f "$SYSROOT$PCDIR/$n.pc" ] \
            || fail "cairo needs nextbsd-displayserver-support's $n.pc in $SYSROOT$PCDIR (CI stages its continuous artifact)"
        f=$(pkgconf --path "$n") || fail "pkgconf cannot resolve $n"
        [ "$f" = "$SYSROOT$PCDIR/$n.pc" ] || fail "pkgconf resolves $n to $f, not $SYSROOT$PCDIR/$n.pc"
        note "pkgconf path: $n -> ${f#"$SYSROOT"} ($(pkgconf --modversion "$n"))"
    done
    fresh_dirs cairo "$X_PREFIX"
    fetch cairo
    meson_build \
        -Dxlib=enabled -Dxcb=enabled -Dxlib-xcb=disabled \
        -Dpng=enabled -Dzlib=enabled -Dfreetype=enabled -Dfontconfig=enabled -Dtee=enabled \
        -Dglib=disabled -Dlzo=disabled -Dspectre=disabled -Dsymbol-lookup=disabled \
        -Dquartz=disabled -Ddwrite=disabled -Dgtk2-utils=disabled \
        -Dtests=disabled -Dgtk_doc=false
    # What meson got from pkgconf: pixman's and freetype's include directories
    # are /usr's, not xlibs' /usr/X11 copies.
    log="$COMP_BUILD/meson-logs/meson-log.txt"
    for n in pixman-1 freetype2; do
        grep -q -F -- "-I$SYSROOT$PREFIX/include/$n" "$log" \
            || fail "cairo's meson setup did not take $n from $PREFIX/include/$n"
        note "meson pkgconf cflags: -I$PREFIX/include/$n"
    done
    if grep -E -- "-I$SYSROOT$X_PREFIX/include/(pixman-1|freetype2)" "$log"; then
        fail "cairo's meson setup took pixman or freetype from $X_PREFIX"
    fi
    # Which copies the compiler read (ninja's depfiles; for the log only).
    # fontconfig's headers sit in plain include/, which pkgconf leaves to the
    # compiler's default path, so the -I for /usr/X11/include (from x11.pc)
    # can still find xlibs' copy first until nextbsd-xlibs#9.
    ninja -C "$COMP_BUILD" -t deps 2>/dev/null \
        | grep -E -o "$SYSROOT[^ ]*/(pixman\.h|ft2build\.h|fontconfig/fontconfig\.h)" \
        | sort -u | sed "s#^$SYSROOT#    - compiled with #" || true
    rm -rf "$COMP_ROOT$X_PREFIX/bin/cairo-trace" "$COMP_ROOT$X_PREFIX/lib/cairo"
    stage cairo
    [ ! -e "$x/bin/cairo-trace" ] && [ ! -e "$x/lib/cairo" ] || fail "cairo-trace (GPL-3.0-or-later) was staged"
    soname_check libcairo.so libcairo.so.2
    soname_check libcairo-script-interpreter.so libcairo-script-interpreter.so.2
    for n in libpng16.so.16 libz.so libpixman-1.so.0 libfontconfig.so.1 libfreetype.so.6 \
             libX11.so.6 libXext.so.6 libXrender.so.1 libxcb.so.1 libxcb-render.so.0 libxcb-shm.so.0; do
        needed_check "$lib" "$n"
    done
    if "$READELF" -d "$lib" | grep -E 'NEEDED.*\[lib(lzo2|glib-2|gobject-2|bfd|X11-xcb|spectre)'; then
        fail "libcairo links a library that should be off"
    fi
    while IFS= read -r f; do
        needed_resolve_check "$f"
    done < <(find "$x/lib" -type f -name '*.so*')
    for n in $CAIRO_FEATURES; do
        grep -qx "#define CAIRO_HAS_$n 1" "$x/include/cairo/cairo-features.h" \
            || fail "cairo-features.h: CAIRO_HAS_$n is not 1"
    done
    if grep -E 'CAIRO_HAS_(GOBJECT_FUNCTIONS|XLIB_XCB_FUNCTIONS|QUARTZ|WIN32|DWRITE)' "$x/include/cairo/cairo-features.h"; then
        fail "cairo-features.h has a backend that should be off"
    fi
    [ ! -e "$DESTDIR$X_PCDIR/cairo-gobject.pc" ] || fail "cairo-gobject was staged"
    for n in $CAIRO_PCS; do
        pc_check "$n" "$VERSION"
    done
}

# flite — its own autoconf configure and makefiles, which build in the source
# tree only. One voice, cmu_us_kal16 (plan Q6): gnustep-gui's speech server
# (Tools/speech/FliteSpeechEngine.m) registers that voice and no other, and
# gnustep-gui's configure builds the `speech` and `say` tools only when
# -lflite_cmu_us_kal16 links. patches/flite adds config/nextbsd.lv (that voice,
# the usenglish language and the cmulex lexicon) and turns on flite's shared
# libraries for BSD targets. Output is OSS (/dev/dsp), like libao's.
# flite's `make install` also installs its static archives and three programs
# that each link the whole voice statically (and expects flite_time, which
# needs another voice), so the headers and shared libraries are installed with
# the same two commands its install rules use (top-level Makefile and
# main/Makefile). No .pc file: gnustep-gui finds flite with AC_CHECK_LIB.
build_flite() {
    comp "flite [autoconf cross, in tree]"
    fresh_dirs flite
    fetch flite
    local plat libdir
    (
        cd "$SRC_DIR"
        CONFIG_SITE="$GS_CROSS/autotools/$T.site" \
        ./configure \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --prefix="$PREFIX" --libdir="$PREFIX/lib" \
            --enable-shared --with-audio=oss \
            --with-langvox=nextbsd --with-lang=usenglish --with-lex=cmulex \
            --with-vox=cmu_us_kal16
        grep -qx 'SHFLAGS  = -fPIC' config/config || fail "flite: configure did not turn on shared libraries"
        grep -qx 'AUDIODRIVER = oss' config/config || fail "flite: configure did not pick OSS output"
        make $JOBS
    )
    plat=$(cd "$SRC_DIR/build" && echo *)
    libdir="$SRC_DIR/build/$plat/lib"
    mkdir -p "$COMP_ROOT$PREFIX/include/flite" "$COMP_ROOT$PREFIX/lib"
    install -m 644 "$SRC_DIR"/include/*.h "$COMP_ROOT$PREFIX/include/flite/"
    cp -pP "$libdir"/*.so "$libdir"/*.so.* "$COMP_ROOT$PREFIX/lib/"
    stage flite
    local l
    for l in flite flite_cmulex flite_usenglish flite_cmu_us_kal16; do
        soname_check "lib$l.so" "lib$l.so.1"
    done
    needed_check "$DESTDIR$PREFIX/lib/libflite.so.1" libm.so
    needed_check "$DESTDIR$PREFIX/lib/libflite_cmu_us_kal16.so.1" libflite_usenglish.so.1
    needed_check "$DESTDIR$PREFIX/lib/libflite_cmu_us_kal16.so.1" libflite_cmulex.so.1
    needed_check "$DESTDIR$PREFIX/lib/libflite_cmu_us_kal16.so.1" libflite.so.1
    "$READELF" --dyn-syms "$DESTDIR$PREFIX/lib/libflite_cmu_us_kal16.so.1" | grep -q ' register_cmu_us_kal16$' \
        || fail "libflite_cmu_us_kal16 does not export register_cmu_us_kal16"
    if find "$DESTDIR$PREFIX/lib" -name 'libflite_*' | grep -v -E '/libflite_(cmulex|usenglish|cmu_us_kal16)\.so'; then
        fail "flite libraries other than the one voice, its language and lexicon were staged"
    fi
    test -f "$DESTDIR$PREFIX/include/flite/flite.h" || fail "flite/flite.h not staged"
}

# FFmpeg — its own configure (not autoconf), out of tree, in cross mode. Plan
# Q6: LGPL only (no --enable-gpl, --enable-version3 or --enable-nonfree), no
# external libraries at all (--disable-autodetect: no zlib, SDL, X, VA-API,
# Vulkan, ALSA/PulseAudio; nothing that could bring D-Bus or Avahi; and
# --disable-iconv, since configure still probes libc's iconv under
# --disable-autodetect; it only serves subtitle charset conversion), no
# network (no http/tcp/rtsp, no avahi or mDNS), no documentation. Components
# start from --disable-everything:
#   - decoders, demuxers and parsers for local playback of the common audio
#     and video formats, by FFmpeg's own decoders: what gnustep-gui's NSMovie
#     and NSSound (GSAudioPlayer), libs-av and Gershwin's Player open;
#   - protocols file and pipe;
#   - one encoder and one muxer, raw 32-bit float PCM, for Whisper, which runs
#     `ffmpeg -i <file> -f f32le -acodec pcm_f32le -ar 16000 -ac 1 pipe:1`;
#   - the OSS input device: Whisper records with `ffmpeg -f oss -i /dev/dsp`;
#   - the filters the ffmpeg command needs (resampling, format conversion, and
#     those it selects itself).
# Libraries libavutil, libavcodec, libavformat, libavdevice, libavfilter,
# libswscale and libswresample with upstream sonames, and the `ffmpeg`
# command; no ffprobe or ffplay (which needs SDL). x86-64 assembly with NASM;
# aarch64's Neon assembly through clang.
FFMPEG_DECODERS="aac ac3 eac3 alac flac mp1float mp2float mp3float opus vorbis
    pcm_s8 pcm_u8 pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be
    pcm_f32le pcm_f32be pcm_f64le pcm_f64be pcm_alaw pcm_mulaw adpcm_ima_wav adpcm_ms
    h264 hevc vp8 vp9 mpeg4 h263 mpeg1video mpeg2video mjpeg theora"
FFMPEG_DEMUXERS="mov matroska ogg wav aiff caf au flac mp3 aac ac3 eac3 avi mpegps mpegts"
FFMPEG_PARSERS="aac ac3 flac mpegaudio opus vorbis h264 hevc vp8 vp9 mpeg4video mpegvideo mjpeg h263"
FFMPEG_PROTOCOLS="file pipe"
FFMPEG_ENCODERS="pcm_f32le"
FFMPEG_MUXERS="pcm_f32le"
FFMPEG_INDEVS="oss"
FFMPEG_FILTERS="aresample aformat anull format null scale"

build_ffmpeg() {
    comp "ffmpeg [configure cross]"
    local arch asm=()
    case "$T" in
        amd64) arch=x86_64; host_nasm; asm=(--x86asmexe="$NASM") ;;
        arm64) arch=aarch64 ;;
    esac
    fresh_dirs ffmpeg
    fetch ffmpeg
    (
        # shellcheck source=/dev/null
        . "$GS_CROSS/autotools/$T.site"
        cd "$COMP_BUILD"
        "$SRC_DIR/configure" \
            --enable-cross-compile --target-os=freebsd --arch="$arch" \
            --cc="$CC" --cxx="$CXX" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" \
            --strip="$STRIP" --pkg-config=pkgconf --host-cc="$CC_FOR_BUILD" \
            "${asm[@]}" \
            --prefix="$PREFIX" --libdir="$PREFIX/lib" --shlibdir="$PREFIX/lib" \
            --incdir="$PREFIX/include" --pkgconfigdir="$PCDIR" \
            --enable-shared --disable-static --enable-pic --disable-debug \
            --disable-gpl --disable-version3 --disable-nonfree \
            --disable-autodetect --disable-iconv --enable-pthreads \
            --disable-network --disable-doc \
            --disable-programs --enable-ffmpeg \
            --disable-everything \
            --enable-decoder="$(csv_list $FFMPEG_DECODERS)" \
            --enable-demuxer="$(csv_list $FFMPEG_DEMUXERS)" \
            --enable-parser="$(csv_list $FFMPEG_PARSERS)" \
            --enable-protocol="$(csv_list $FFMPEG_PROTOCOLS)" \
            --enable-encoder="$(csv_list $FFMPEG_ENCODERS)" \
            --enable-muxer="$(csv_list $FFMPEG_MUXERS)" \
            --enable-indev="$(csv_list $FFMPEG_INDEVS)" \
            --enable-filter="$(csv_list $FFMPEG_FILTERS)"
        # The licence and the switches the plan asks for, as configure
        # resolved them.
        grep -qx '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' config.h \
            || fail "FFmpeg is not configured LGPL-2.1-or-later: $(grep FFMPEG_LICENSE config.h)"
        local c
        for c in GPL VERSION3 NONFREE NETWORK ZLIB ICONV; do
            grep -qx "#define CONFIG_$c 0" config.h || fail "FFmpeg: CONFIG_$c is not 0"
        done
        grep -qx '#define CONFIG_OSS_INDEV 1' config_components.h || fail "FFmpeg: the OSS input device is not enabled"
        grep -qx '#define HAVE_PTHREADS 1' config.h || fail "FFmpeg: pthreads are not enabled"
        make $JOBS
        # The libraries, headers, .pc files and the ffmpeg command; not
        # install-data (libx264/libvpx presets for encoders that aren't built).
        make install-progs install-headers DESTDIR="$COMP_ROOT"
    )
    stage ffmpeg
    soname_check libavutil.so libavutil.so.61
    soname_check libavcodec.so libavcodec.so.63
    soname_check libavformat.so libavformat.so.63
    soname_check libavdevice.so libavdevice.so.63
    soname_check libavfilter.so libavfilter.so.12
    soname_check libswscale.so libswscale.so.10
    soname_check libswresample.so libswresample.so.7
    local bin="$DESTDIR$PREFIX/bin/ffmpeg" l f
    [ -x "$bin" ] || fail "the ffmpeg command was not staged"
    for l in libavdevice.so.63 libavfilter.so.12 libavformat.so.63 libavcodec.so.63 \
             libswresample.so.7 libswscale.so.10 libavutil.so.61; do
        needed_check "$bin" "$l"
    done
    # Nothing outside FFmpeg's own libraries and the base's libc, libm, libthr
    # and libgcc_s.
    for f in "$bin" "$DESTDIR$PREFIX"/lib/lib{avutil,avcodec,avformat,avdevice,avfilter,swscale,swresample}.so; do
        if "$READELF" -d "$f" | grep NEEDED | grep -v -E '\[lib(av(util|codec|format|device|filter)|sw(scale|resample)|c|m|thr|gcc_s)\.so'; then
            fail "$(basename "$f") links a library outside FFmpeg and the base"
        fi
    done
    for l in libavutil libavcodec libavformat libavdevice libavfilter libswscale libswresample; do
        pc_check "$l"
    done
}

# =============================================================================
# driver
# =============================================================================
# Add a component: pin it in sources.lock, write build_<name>() above (hyphens
# in the name become underscores in the function), put its patches, if any, in
# patches/<name>/ with a series file, and append <name> here in build order.
COMPONENTS="giflib libjpeg-turbo libpng gmp libsndfile libao sqlite libtiff nettle gnutls cairo flite ffmpeg"

if [ $# -gt 0 ]; then
    for c in "$@"; do
        case " $COMPONENTS " in
            *" $c "*) ;;
            *) fail "unknown component '$c' (known: $COMPONENTS)" ;;
        esac
    done
    COMPONENTS="$*"
fi

echo "nextbsd-gnustep-support: building [$COMPONENTS] for $T/$TA into $DESTDIR ($PREFIX; $X_PREFIX for cairo)"
mkdir -p "$DESTDIR" "$BUILD"
base_list
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done

echo
echo "==> staged into $DESTDIR:"
( cd "$DESTDIR" && find . ! -type d | sort | sed 's#^\.##' )
