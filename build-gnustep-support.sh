#!/usr/bin/env bash
# =============================================================================
# build-gnustep-support.sh — cross-build driver for nextbsd-gnustep-support
# =============================================================================
#
# Builds the libraries GNUstep needs on NextBSD (E24, nextbsd/nextbsd#574) for
# ONE architecture into $DESTDIR, from the pinned upstream tarballs listed in
# sources.lock, with NextBSD's changes applied from patches/<name>/.
#
# Modelled on nextbsd-contrib's build-contrib.sh: same container, same compat
# sysroot, one build_<name>() per component, a COMPONENTS list, out-of-tree
# builds under .build/, readelf checks instead of running target binaries.
# What is different here is that the components build on each other (libtiff
# needs libjpeg, GnuTLS needs nettle and gmp), so every component is installed
# twice:
#   - in full into the WORKING SYSROOT (.build/sysroot-<arch>: a hard-linked
#     copy of $SYSROOT), where later components find its headers, libraries
#     and .pc files;
#   - the shipped subset into $DESTDIR: shared libraries with their
#     development links, headers and .pc files (Gershwin builds GNUstep on the
#     machine, plan D10/D11, so the development files ship). No static
#     libraries, libtool archives, programs, docs or man pages.
# The compat base given as $SYSROOT is never written to.
#
# Layout of what ships (plan Q7): /usr/lib, /usr/include, and .pc files in
# /usr/libdata/pkgconfig (FreeBSD base's pkg-config directory). Upstream
# sonames are kept. Nothing goes to /usr/local.
#
# Nothing links against nextbsd-userland: every component here needs only the
# compat base (libc, libm, libthr, zlib, liblzma) and earlier components.
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-kernel-toolchain container (pinned clang/lld 19.1.7 in
#   $CROSS_BINDIR; meson, ninja, cmake, pkgconf, autotools on PATH), with
#   compat's `continuous` base extracted into $SYSROOT.
#
# USAGE
#   ./build-gnustep-support.sh             every component, in COMPONENTS order,
#                                          from a fresh working sysroot
#   ./build-gnustep-support.sh gnutls      named components only, reusing the
#                                          working sysroot an earlier run left
# =============================================================================

set -euo pipefail

# ---- required environment ----------------------------------------------------
: "${T:?set T to the target (amd64 / arm64)}"
: "${TA:?set TA to the target_arch (amd64 / aarch64)}"
: "${SYSROOT:?set SYSROOT to the staged compat base}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
: "${DESTDIR:=/stage}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build"
DIST="$BUILD/dist"              # downloaded tarballs, verified against sources.lock
LOCK="$ROOT/sources.lock"
PATCHES="$ROOT/patches"
CROSS="$ROOT/cross"

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd ;;
    *)     CROSS_TRIPLE="${TA}-unknown-freebsd" ;;
esac
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS=-j"$(nproc 2>/dev/null || echo 2)"

# The pristine compat base (read-only here: the collision check compares
# against it) and the working sysroot every component builds against.
BASEROOT="$(cd "$SYSROOT" && pwd)"
WORKROOT="$BUILD/sysroot-$T"

# ---- helpers -----------------------------------------------------------------
comp() { echo; echo "==> [$T/$TA] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# The image ships the pinned LLVM binutils in $CROSS_BINDIR (and /usr/bin/<tool>-19).
llvm_tool() {
    local t
    for t in "$CROSS_BINDIR/$1" "$(command -v "$1-19" 2>/dev/null)" "$(command -v "$1" 2>/dev/null)"; do
        [ -n "$t" ] && [ -x "$t" ] && { echo "$t"; return 0; }
    done
    fail "$1 not found (looked in $CROSS_BINDIR and PATH)"
}
AR=$(llvm_tool llvm-ar); RANLIB=$(llvm_tool llvm-ranlib); NM=$(llvm_tool llvm-nm)
STRIP=$(llvm_tool llvm-strip); OBJDUMP=$(llvm_tool llvm-objdump); READELF=$(llvm_tool llvm-readelf)

# Assert a staged object links a given library (cross readelf; target binaries
# cannot run on the runner).
needed_check() {
    local obj="$1" want="$2"
    "$READELF" -d "$obj" 2>/dev/null | grep -q "NEEDED.*\[$want" \
        || fail "$obj missing DT_NEEDED $want"
    note "DT_NEEDED ok: $(basename "$obj") -> $want"
}

# Assert a staged library carries the upstream soname (FreeBSD binaries and
# pkg's shlib tracking depend on it, plan audit 2 §1.1).
soname_check() {
    local lib="$DESTDIR/usr/lib/$1" want="$2"
    [ -f "$lib" ] || fail "$1 was not staged"
    "$READELF" -d "$lib" 2>/dev/null | grep -q "SONAME.*\[$want\]" \
        || fail "$1 has soname '$("$READELF" -d "$lib" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')', want $want"
    [ -e "$DESTDIR/usr/lib/$want" ] || fail "$want link was not staged"
    note "soname ok: $1 -> $want"
}

# Fresh out-of-tree build and install-root directories for a component.
fresh_dirs() {
    local name="$1"
    COMP_BUILD="$BUILD/$name-$T"
    COMP_ROOT="$BUILD/$name-root-$T"
    rm -rf "$COMP_BUILD" "$COMP_ROOT"
    mkdir -p "$COMP_BUILD" "$COMP_ROOT"
}

# lock <name> <field>: a field of a sources.lock line (version, sha256, url).
lock() {
    local f
    case "$2" in version) f=2 ;; sha256) f=3 ;; url) f=4 ;; *) fail "lock: bad field $2" ;; esac
    awk -v n="$1" -v f="$f" '$1 == n { print $f; found = 1 } END { exit !found }' "$LOCK" \
        || fail "$1 is not in sources.lock"
}

# fetch_source <name> [tag]: download (or reuse) the pinned tarball, verify its
# SHA-256, unpack it fresh into .build/src/<name>-<tag>, and apply
# patches/<name>/*.patch in order. Sets SRCDIR and VERSION.
fetch_source() {
    local name="$1" tag="${2:-$T}" url sha file got p
    VERSION=$(lock "$name" version); sha=$(lock "$name" sha256); url=$(lock "$name" url)
    file="$DIST/$(basename "$url")"
    mkdir -p "$DIST"
    if [ ! -f "$file" ] || [ "$(sha256sum "$file" | cut -d' ' -f1)" != "$sha" ]; then
        note "fetch $url"
        curl -fsSL --retry 5 --retry-delay 10 -o "$file.part" "$url" || fail "download failed: $url"
        mv "$file.part" "$file"
    fi
    got=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { rm -f "$file"; fail "$name: SHA-256 mismatch for $(basename "$file") (got $got, sources.lock has $sha)"; }
    note "$name $VERSION, sha256 ok"
    SRCDIR="$BUILD/src/$name-$tag"
    rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
    tar -xf "$file" -C "$SRCDIR" --strip-components=1
    if [ -d "$PATCHES/$name" ]; then
        for p in "$PATCHES/$name"/*.patch; do
            [ -e "$p" ] || continue
            note "patch $(basename "$p")"
            patch -d "$SRCDIR" -p1 --batch --forward --no-backup-if-mismatch < "$p" \
                || fail "$name: $(basename "$p") does not apply"
        done
    fi
}

# The cross environment for autotools configure scripts, as in contrib:
# --host=<triple>, the toolchain clang with --sysroot, LLVM binutils.
# CC_FOR_BUILD is the runner's cc for helpers that run during the build.
cross_configure() {
    local src="$1"; shift
    CC="$CROSS_BINDIR/clang --target=$CROSS_TRIPLE --sysroot=$SYSROOT --ld-path=$CROSS_BINDIR/ld.lld" \
    CXX="$CROSS_BINDIR/clang++ --target=$CROSS_TRIPLE --sysroot=$SYSROOT --ld-path=$CROSS_BINDIR/ld.lld" \
    CFLAGS="-O2 -pipe" \
    CXXFLAGS="-O2 -pipe" \
    LDFLAGS="-L$SYSROOT/usr/lib" \
    AR="$AR" RANLIB="$RANLIB" NM="$NM" STRIP="$STRIP" OBJDUMP="$OBJDUMP" \
    CC_FOR_BUILD=cc \
    "$src/configure" \
        --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
        --prefix=/usr --libdir=/usr/lib --includedir=/usr/include \
        --mandir=/usr/share/man --sysconfdir=/etc --localstatedir=/var \
        "$@"
}

# CMake with cross/cross-<arch>.cmake (reads $SYSROOT and $CROSS_BINDIR).
cross_cmake() {
    cmake -S "$SRCDIR" -B "$COMP_BUILD" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$CROSS/cross-$T.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_INCLUDEDIR=include \
        -DBUILD_SHARED_LIBS=ON \
        "$@"
    cmake --build "$COMP_BUILD" $JOBS
    DESTDIR="$COMP_ROOT" cmake --install "$COMP_BUILD"
}

# publish <extra-path>...: normalise $COMP_ROOT, install it in full into the
# working sysroot, then stage the shipped subset into $DESTDIR: top-level
# usr/lib/*.so* (libraries and their development links), usr/include, the .pc
# files, and any extra paths given (relative to /). Shipped files are stripped,
# made 0444 as FreeBSD base installs libraries and headers, and must not
# already exist in the compat base.
publish() {
    local r="$COMP_ROOT" d p list
    for d in usr/lib/pkgconfig usr/share/pkgconfig; do
        if [ -d "$r/$d" ]; then
            mkdir -p "$r/usr/libdata/pkgconfig"
            mv "$r/$d"/*.pc "$r/usr/libdata/pkgconfig/"
            rmdir "$r/$d"
        fi
    done
    # libtool archives carry absolute paths that would point later links at
    # the runner; FreeBSD base does not ship them either.
    find "$r" -name '*.la' -delete
    if [ -d "$r/usr/libdata/pkgconfig" ] \
        && grep -rlF -e "$BUILD" -e "$BASEROOT" -e /usr/local "$r/usr/libdata/pkgconfig"; then
        fail "a .pc file above names a build path or /usr/local"
    fi

    cp -a --remove-destination "$r/." "$SYSROOT/"

    list="$BUILD/ship-$T.list"
    (
        cd "$r"
        [ -d usr/lib ] && find usr/lib -maxdepth 1 \( -type f -o -type l \) -name '*.so*'
        [ -d usr/include ] && find usr/include ! -type d
        [ -d usr/libdata/pkgconfig ] && find usr/libdata/pkgconfig ! -type d
        for p in "$@"; do
            [ -e "$p" ] || fail "extra path /$p was not installed"
            find "$p" ! -type d
        done
    ) | sort > "$list"
    [ -s "$list" ] || fail "nothing to ship"
    while read -r p; do
        if [ -e "$BASEROOT/$p" ] || [ -L "$BASEROOT/$p" ]; then
            fail "/$p is already in the compat base"
        fi
        mkdir -p "$DESTDIR/$(dirname "$p")"
        cp -a --remove-destination "$r/$p" "$DESTDIR/$p"
        if [ -f "$DESTDIR/$p" ] && [ ! -L "$DESTDIR/$p" ]; then
            case "$p" in
                *.so|*.so.*) "$STRIP" --strip-unneeded "$DESTDIR/$p" ;;
            esac
            chmod 0444 "$DESTDIR/$p"
        fi
    done < "$list"
    note "shipped $(wc -l < "$list") paths"
}

# =============================================================================
# Host build tools (built on the runner, never shipped)
# =============================================================================
# NASM for libjpeg-turbo's x86-64 SIMD (amd64 only; arm64's Neon code uses
# compiler intrinsics). Built from the pinned tarball until the toolchain
# image carries it.
host_nasm() {
    NASM="$BUILD/host/bin/nasm"
    [ -x "$NASM" ] && [ -f "$BUILD/host/nasm-$(lock nasm version)" ] && return 0
    comp "nasm [host tool]"
    fetch_source nasm host
    (
        cd "$SRCDIR"
        ./configure --prefix="$BUILD/host" >/dev/null
        make $JOBS nasm
    )
    mkdir -p "$BUILD/host/bin"
    install -m 0755 "$SRCDIR/nasm" "$NASM"
    : > "$BUILD/host/nasm-$VERSION"
    note "$("$NASM" -v)"
}

# =============================================================================
# giflib — plain GNU Makefile
# =============================================================================
# Only the library: upstream's `all` also builds the utilities, a second
# shared library named libutil (which would collide with base's libutil) and
# docs that want xmlto.
build_giflib() {
    comp "giflib [makefile cross]"
    fresh_dirs giflib
    fetch_source giflib
    make -C "$SRCDIR" $JOBS libgif.so \
        CC="$CROSS_BINDIR/clang --target=$CROSS_TRIPLE --sysroot=$SYSROOT --ld-path=$CROSS_BINDIR/ld.lld" \
        AR="$AR" CFLAGS="-std=gnu99 -fPIC -Wall -O2 -pipe -DHAVE_REALLOCARRAY"
    make -C "$SRCDIR" install-include install-shared-lib PREFIX=/usr DESTDIR="$COMP_ROOT"
    publish
    soname_check libgif.so libgif.so.7
}

# =============================================================================
# libjpeg-turbo — CMake. libjpeg.so.8 (the jpeg8 ABI FreeBSD and most
# distributions ship); no TurboJPEG API, no tools.
# =============================================================================
build_libjpeg_turbo() {
    comp "libjpeg-turbo [cmake cross]"
    local simd=()
    if [ "$T" = amd64 ]; then
        host_nasm
        simd=(-DCMAKE_ASM_NASM_COMPILER="$NASM")
    fi
    fresh_dirs libjpeg-turbo
    fetch_source libjpeg-turbo
    cross_cmake \
        -DENABLE_SHARED=ON -DENABLE_STATIC=OFF \
        -DWITH_JPEG8=ON -DWITH_TURBOJPEG=OFF \
        -DWITH_TOOLS=OFF -DWITH_TESTS=OFF \
        -DWITH_SIMD=ON -DREQUIRE_SIMD=ON \
        "${simd[@]}"
    rm -rf "$COMP_ROOT/usr/lib/cmake"
    publish
    soname_check libjpeg.so libjpeg.so.8
}

# =============================================================================
# libpng — autotools (the release's generated configure). zlib from base.
# =============================================================================
build_libpng() {
    comp "libpng [autoconf cross]"
    fresh_dirs libpng
    fetch_source libpng
    (
        cd "$COMP_BUILD"
        cross_configure "$SRCDIR" \
            --enable-shared --disable-static \
            --disable-tests --disable-tools
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    rm -rf "$COMP_ROOT/usr/lib/cmake"
    publish
    soname_check libpng16.so libpng16.so.16
    needed_check "$DESTDIR/usr/lib/libpng16.so.16" libz.so
}

# =============================================================================
# gmp — autotools. Fat binary on amd64 (picks the CPU's kernels at run time);
# generic aarch64 assembly on arm64. No C++ binding.
# =============================================================================
build_gmp() {
    comp "gmp [autoconf cross]"
    local fat=()
    [ "$T" = amd64 ] && fat=(--enable-fat)
    fresh_dirs gmp
    fetch_source gmp
    (
        cd "$COMP_BUILD"
        cross_configure "$SRCDIR" \
            --enable-shared --disable-static --disable-cxx \
            "${fat[@]}"
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    publish
    soname_check libgmp.so libgmp.so.10
}

# =============================================================================
# libsndfile — CMake. WAV/AIFF/AU/CAF and the other built-in formats; no
# external codecs (FLAC, Vorbis, Opus, MPEG). gnustep-gui builds NSSound only
# when both libsndfile and libao are present.
# =============================================================================
build_libsndfile() {
    comp "libsndfile [cmake cross]"
    fresh_dirs libsndfile
    fetch_source libsndfile
    # CPU_CLIPS_*: answers for a run test that cannot run here. FALSE selects
    # the portable conversion code, correct on every CPU.
    cross_cmake \
        -DENABLE_EXTERNAL_LIBS=OFF -DENABLE_MPEG=OFF -DENABLE_EXPERIMENTAL=OFF \
        -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_REGTEST=OFF \
        -DENABLE_CPACK=OFF -DENABLE_PACKAGE_CONFIG=OFF -DINSTALL_MANPAGES=OFF \
        -DINSTALL_PKGCONFIG_MODULE=ON \
        -DCPU_CLIPS_POSITIVE=FALSE -DCPU_CLIPS_NEGATIVE=FALSE \
        -DCMAKE_DISABLE_FIND_PACKAGE_ALSA=ON -DCMAKE_DISABLE_FIND_PACKAGE_Sndio=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_SQLite3=ON -DCMAKE_DISABLE_FIND_PACKAGE_Speex=ON
    rm -rf "$COMP_ROOT/usr/lib/cmake" "$COMP_ROOT/usr/share/doc"
    publish
    soname_check libsndfile.so libsndfile.so.1
}

# =============================================================================
# libao — autotools. The OSS output plugin only (/dev/dsp); PulseAudio, ESD,
# aRts, NAS and ALSA are off (PulseAudio would also bring D-Bus, plan D2).
# =============================================================================
build_libao() {
    comp "libao [autoconf cross]"
    fresh_dirs libao
    fetch_source libao
    (
        cd "$COMP_BUILD"
        cross_configure "$SRCDIR" \
            --enable-shared --disable-static \
            --disable-pulse --disable-esd --disable-arts --disable-nas \
            --disable-alsa --disable-alsa-mmap \
            --without-x
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    publish usr/lib/ao
    soname_check libao.so libao.so.4
    [ -f "$DESTDIR/usr/lib/ao/plugins-4/liboss.so" ] || fail "libao's OSS plugin was not staged"
    if find "$DESTDIR/usr/lib/ao/plugins-4" -name '*.so' ! -name liboss.so | grep .; then
        fail "libao plugins other than OSS were staged"
    fi
}

# =============================================================================
# sqlite — the autosetup "autoconf" bundle. The library only (no sqlite3
# shell), with the traditional libsqlite3.so.0 soname. Base keeps its own
# private copy as libprivatesqlite3; this is the public one.
# =============================================================================
build_sqlite() {
    comp "sqlite [autosetup cross]"
    fresh_dirs sqlite
    fetch_source sqlite
    (
        cd "$COMP_BUILD"
        # autosetup builds its bootstrap jimsh with CC_FOR_BUILD.
        cross_configure "$SRCDIR" \
            --disable-static --soname=legacy --disable-rpath \
            --disable-readline \
            --enable-fts4 --enable-fts5 --enable-rtree --enable-column-metadata
        make $JOBS libsqlite3.so
        make install-dll install-headers install-pc DESTDIR="$COMP_ROOT"
    )
    publish
    soname_check libsqlite3.so libsqlite3.so.0
}

# =============================================================================
# libtiff — CMake. JPEG (this repo), zlib and LZMA (base); jbig, lerc,
# libdeflate, zstd and webp off. No tools, tests, docs or C++ API.
# =============================================================================
build_libtiff() {
    comp "libtiff [cmake cross]"
    fresh_dirs libtiff
    fetch_source libtiff
    cross_cmake \
        -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
        -Dtiff-cxx=OFF -Dtiff-opengl=OFF -Dsphinx=OFF \
        -Djpeg=ON -Dold-jpeg=ON -Dzlib=ON -Dpixarlog=ON -Dlzma=ON \
        -Djbig=OFF -Dlerc=OFF -Dlibdeflate=OFF -Dzstd=OFF -Dwebp=OFF
    rm -rf "$COMP_ROOT/usr/lib/cmake" "$COMP_ROOT/usr/share/doc"
    publish
    soname_check libtiff.so libtiff.so.6
    needed_check "$DESTDIR/usr/lib/libtiff.so.6" libjpeg.so.8
    needed_check "$DESTDIR/usr/lib/libtiff.so.6" libz.so
    needed_check "$DESTDIR/usr/lib/libtiff.so.6" liblzma.so
}

# =============================================================================
# nettle — autotools. nettle and hogweed (public-key, over gmp). Fat on both
# arches (run-time CPU detection for AES, SHA, GHASH).
# =============================================================================
build_nettle() {
    comp "nettle [autoconf cross]"
    fresh_dirs nettle
    fetch_source nettle
    (
        cd "$COMP_BUILD"
        cross_configure "$SRCDIR" \
            --enable-shared --disable-static \
            --enable-public-key --enable-fat \
            --disable-openssl --disable-documentation
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    # nettle installs its tools (nettle-hash, pkcs1-conv, ...); not shipped.
    publish
    soname_check libnettle.so libnettle.so.8
    soname_check libhogweed.so libhogweed.so.6
    needed_check "$DESTDIR/usr/lib/libhogweed.so.6" libgmp.so.10
}

# =============================================================================
# GnuTLS — autotools, minimal (plan Q3): nettle/hogweed and gmp from this
# repo, zlib from base, the bundled libtasn1 and libunistring. p11-kit,
# libidn2, TPM, DANE (unbound), brotli, zstd, the C++ and OpenSSL-compat
# libraries, tools, docs and NLS are off. Trusts the same /etc/ssl/certs
# directory as base OpenSSL (certctl), so GNUstep's NSURLConnection (GnuTLS)
# and NSURLSession (curl, OpenSSL) see one CA set.
# =============================================================================
build_gnutls() {
    comp "gnutls [autoconf cross]"
    fresh_dirs gnutls
    fetch_source gnutls
    (
        cd "$COMP_BUILD"
        cross_configure "$SRCDIR" \
            --enable-shared --disable-static \
            --with-included-libtasn1 --with-included-unistring \
            --without-p11-kit --without-idn --without-tpm --without-tpm2 \
            --disable-libdane --without-brotli --without-zstd --with-zlib=link \
            --disable-cxx --disable-openssl-compatibility \
            --disable-doc --disable-manpages --disable-tools --disable-tests \
            --disable-nls --disable-rpath --disable-valgrind-tests \
            --with-default-trust-store-dir=/etc/ssl/certs
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    publish
    soname_check libgnutls.so libgnutls.so.30
    needed_check "$DESTDIR/usr/lib/libgnutls.so.30" libnettle.so.8
    needed_check "$DESTDIR/usr/lib/libgnutls.so.30" libhogweed.so.6
    needed_check "$DESTDIR/usr/lib/libgnutls.so.30" libgmp.so.10
    needed_check "$DESTDIR/usr/lib/libgnutls.so.30" libz.so
    if "$READELF" -d "$DESTDIR/usr/lib/libgnutls.so.30" | grep -E 'NEEDED.*\[(libp11-kit|libidn2|libtasn1|libunistring)'; then
        fail "libgnutls links an external library that should be off or bundled"
    fi
    grep -q '/etc/ssl/certs' "$DESTDIR/usr/lib/libgnutls.so.30" \
        || fail "libgnutls does not carry the /etc/ssl/certs trust store"
    [ -e "$DESTDIR/usr/lib/libgnutls-openssl.so" ] && fail "libgnutls-openssl was staged"
    [ -e "$DESTDIR/usr/lib/libgnutlsxx.so" ] && fail "libgnutlsxx was staged"
    return 0
}

# =============================================================================
# driver
# =============================================================================
# Build order (plan step 9): giflib, jpeg, png, gmp, libsndfile, libao, sqlite;
# then libtiff (jpeg) and nettle (gmp); then GnuTLS (nettle, gmp).
# Add a component: a line in sources.lock, build_<name>() above (hyphens in the
# name become underscores in the function), and <name> here.
COMPONENTS="giflib libjpeg-turbo libpng gmp libsndfile libao sqlite libtiff nettle gnutls"

fresh_sysroot=1
if [ $# -gt 0 ]; then
    for c in "$@"; do
        case " $COMPONENTS " in
            *" $c "*) ;;
            *) fail "unknown component '$c' (known: $COMPONENTS)" ;;
        esac
    done
    COMPONENTS="$*"
    [ -d "$WORKROOT" ] && fresh_sysroot=0
fi

echo "nextbsd-gnustep-support: building [$COMPONENTS] for $T/$TA into $DESTDIR"
if [ "$fresh_sysroot" = 1 ]; then
    note "working sysroot: $WORKROOT (from $BASEROOT)"
    rm -rf "$WORKROOT"
    mkdir -p "$BUILD"
    cp -al "$BASEROOT" "$WORKROOT" 2>/dev/null || { rm -rf "$WORKROOT"; cp -a "$BASEROOT" "$WORKROOT"; }
else
    note "working sysroot: $WORKROOT (reused)"
fi
SYSROOT="$WORKROOT"

# pkgconf only, and only the working sysroot's .pc files: never the runner's.
export SYSROOT CROSS_BINDIR DESTDIR
export PKG_CONFIG=pkgconf
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/libdata/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
unset PKG_CONFIG_PATH

mkdir -p "$DESTDIR"
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done

# Every shipped .pc must resolve against base plus this repo (no missing
# Requires), as it will for a build on the machine.
comp "pkg-config check"
for pc in "$DESTDIR"/usr/libdata/pkgconfig/*.pc; do
    [ -e "$pc" ] || continue
    m=$(basename "$pc" .pc)
    pkgconf --exists --print-errors "$m" || fail "$m.pc does not resolve"
    note "$m: $(pkgconf --modversion "$m")"
done

echo
echo "==> staged into $DESTDIR:"
( cd "$DESTDIR" && find . ! -type d | sort | sed 's#^\.##' )
