#!/usr/bin/env bash
# =============================================================================
# build-gnustep-support.sh — cross-build driver for nextbsd-gnustep-support
# =============================================================================
#
# Builds the libraries GNUstep needs on NextBSD (E24, nextbsd/nextbsd#574, plan
# step 9) for ONE architecture, from pinned upstream release tarballs, into the
# /usr prefix with upstream sonames. Layout and checks follow the nextbsd-xlibs
# reference (wiki: Source-Repo-Conventions).
#
# For each component, in COMPONENTS order:
#   1. fetch:   download the tarball named in sources.lock, refuse it unless
#               its SHA-256 matches, unpack it under .build/src/;
#   2. patch:   apply patches/<name>/series in order (each patch must state
#               its Origin:);
#   3. build:   the upstream build system as it is, out of tree: autotools
#               (cross/autotools/<arch>.site, --host=<triple>), CMake
#               (cross/cmake/<arch>.cmake) or meson (cross/meson/<arch>.ini),
#               installed with DESTDIR into .build/<name>-root-<arch>/;
#   4. stage:   check and tidy that install, then copy it into $SYSROOT (so
#               later components find its headers, .pc files and libraries)
#               and into $DESTDIR (the published artifact).
#
# Nothing here uses FreeBSD packages, the ports tree or ports tools, and
# nothing links against nextbsd-userland: these components need only the
# NextBSD base (compat) sysroot (libc, libm, libthr, zlib, liblzma) and each
# other. Base's ICU, libxml2, libxslt, libffi and curl are GNUstep's own
# dependencies, not these libraries'.
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-kernel-toolchain container (pinned clang/lld 19.1.7 in
#   $CROSS_BINDIR, meson, ninja, cmake, pkgconf, autotools), with compat's
#   `continuous` base extracted into $SYSROOT. $SYSROOT is scratch: this
#   script installs every component into its /usr as it goes.
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

# Install prefix (plan Q7): /usr for libraries that don't need X. Their .pc
# files go in FreeBSD base's /usr/libdata/pkgconfig whatever the upstream
# default, so one directory goes on pkgconf's path.
PREFIX=/usr
PCDIR=$PREFIX/libdata/pkgconfig

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd ;;
    *)     echo "FAIL: unsupported T=$T (amd64 / arm64)" >&2; exit 1 ;;
esac
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS=-j"$(nproc 2>/dev/null || echo 2)"

SYSROOT="$(cd "$SYSROOT" && pwd)"
export SYSROOT DESTDIR CROSS_BINDIR GS_CROSS

# pkgconf only, and only the sysroot's .pc directories (base and this repo,
# then NextBSD X for cairo): never the build host's.
export PKG_CONFIG=pkgconf
export PKG_CONFIG_LIBDIR="$SYSROOT$PCDIR:$SYSROOT/usr/X11/lib/pkgconfig"
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

# soname_check <lib> <soname>: the staged library (by its development link in
# $DESTDIR/usr/lib) carries the upstream soname, and the soname link exists.
soname_check() {
    local lib="$DESTDIR$PREFIX/lib/$1" want="$2"
    [ -e "$lib" ] || fail "$1 was not staged"
    "$READELF" -d "$lib" 2>/dev/null | grep -q "SONAME.*\[$want\]" \
        || fail "$1 does not have SONAME $want"
    [ -e "$DESTDIR$PREFIX/lib/$want" ] || fail "$want was not staged"
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

# Fresh out-of-tree build and install-root directories for a component.
fresh_dirs() {
    local name="$1"
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

# The base's own files, listed while the sysroot is still the pristine compat
# base (before this script has installed anything into it), so stage can
# refuse a component that would overwrite one. A later partial run reuses the
# list.
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
#   - everything must be under /usr, and nothing may replace a base file;
#   - libtool .la files, docs and info manuals are dropped (man pages are kept);
#   - .pc files move to /usr/libdata/pkgconfig;
#   - no .pc file may name /usr/local or a build-host path.
stage() {
    local name="$1" x="$COMP_ROOT$PREFIX" stray f clash
    [ -d "$x" ] || fail "$name installed nothing under $PREFIX"
    stray=$(cd "$COMP_ROOT" && find . -mindepth 1 ! -path ".$PREFIX" ! -path ".$PREFIX/*")
    [ -z "$stray" ] || fail "$name installed outside $PREFIX: $stray"
    find "$x" -name '*.la' -delete
    rm -rf "$x/share/doc" "$x/share/info"
    for f in lib/pkgconfig share/pkgconfig; do
        if [ -d "$x/$f" ]; then
            mkdir -p "$COMP_ROOT$PCDIR"
            mv "$x/$f"/*.pc "$COMP_ROOT$PCDIR/"
            rmdir "$x/$f"
        fi
    done
    for f in "$COMP_ROOT$PCDIR"/*.pc; do
        [ -e "$f" ] || continue
        [ -L "$f" ] && continue
        grep -q "^prefix=$PREFIX\$" "$f" || fail "$(basename "$f"): prefix is not $PREFIX"
        if grep -n -F -e /usr/local -e "$ROOT" -e "$SYSROOT" "$f"; then
            fail "$(basename "$f") names /usr/local or a build-host path"
        fi
    done
    find "$x" -type d -empty -delete
    clash=$(cd "$COMP_ROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort | LC_ALL=C comm -12 - "$BASE_LIST")
    [ -z "$clash" ] || fail "$name would replace files of the NextBSD base: $clash"
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$SYSROOT" && tar -xf -)
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -)
    note "staged $(cd "$COMP_ROOT" && find . ! -type d | wc -l) files"
}

# =============================================================================
# Host build tools (built on the runner, never shipped)
# =============================================================================
# NASM for libjpeg-turbo's x86-64 SIMD (amd64 only; arm64's Neon code uses
# compiler intrinsics). Pinned in sources.lock and built with the runner's cc
# until the toolchain image carries it.
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
# libsndfile, libao, sqlite; then libtiff (jpeg) and nettle (gmp); then GnuTLS.
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
    # gmp probes the compiler by linking "$CC $CFLAGS conftest.c", without
    # LDFLAGS, so lld has to be in CFLAGS too (the site file keeps an
    # inherited CFLAGS); otherwise the probe links with the runner's x86 ld.
    CFLAGS="-O2 -pipe -fuse-ld=lld -Wno-unused-command-line-argument" \
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

# =============================================================================
# driver
# =============================================================================
# Add a component: pin it in sources.lock, write build_<name>() above (hyphens
# in the name become underscores in the function), put its patches, if any, in
# patches/<name>/ with a series file, and append <name> here in build order.
COMPONENTS="giflib libjpeg-turbo libpng gmp libsndfile libao sqlite libtiff nettle gnutls"

if [ $# -gt 0 ]; then
    for c in "$@"; do
        case " $COMPONENTS " in
            *" $c "*) ;;
            *) fail "unknown component '$c' (known: $COMPONENTS)" ;;
        esac
    done
    COMPONENTS="$*"
fi

echo "nextbsd-gnustep-support: building [$COMPONENTS] for $T/$TA into $DESTDIR$PREFIX"
mkdir -p "$DESTDIR" "$BUILD"
base_list
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done

echo
echo "==> staged into $DESTDIR:"
( cd "$DESTDIR" && find . ! -type d | sort | sed 's#^\.##' )
