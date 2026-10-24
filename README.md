# nextbsd-gnustep-support

The libraries GNUstep needs on NextBSD, built from pinned upstream source into
base. Gershwin builds and installs GNUstep itself (into `/System`, E24 plan D10);
this repo provides what that build and the running desktop link against.

Plan: [E24 GNUstep & Gershwin requirements](https://github.com/nextbsd/nextbsd-userland/wiki/E24-GNUstep-Gershwin-Requirements-Direction),
epic nextbsd/nextbsd#574.

| Repo | What it holds | Package |
|---|---|---|
| `nextbsd-userland` | Darwin sources, plus Apple's libxml2, libxslt, libffi and curl, and ICU 76.1 | `NextBSD-userland` |
| `nextbsd-xlibs` | the X client libraries, pixman, freetype, fontconfig | `NextBSD-xlibs` |
| **`nextbsd-gnustep-support`** | **image formats, sound, SQLite, GnuTLS; later cairo, flite, FFmpeg** | **`NextBSD-gnustep-support`** |
| `nextbsd-gershwin-support` | what only Gershwin uses (wget, lcms2, xdotool, squashfs) | `NextBSD-gershwin-support` |

## The rules for what goes here

1. **What GNUstep itself needs** (libs-base, libs-gui, libs-back and the
   libraries they load), and that neither Apple's sources (nextbsd-userland)
   nor the FreeBSD base already provide. Gershwin-only libraries go to
   nextbsd-gershwin-support.
2. **Pinned upstream release tarballs only**, each with its URL and SHA-256 in
   `sources.lock`, downloaded at build time. No FreeBSD packages, ports or
   ports tools. NextBSD's changes are a patch series in `patches/<name>/`.
3. **Upstream build systems** (autotools, CMake, meson; giflib's own
   Makefile) driven in cross mode with the files in `cross/`; no hand-written
   replacement makefiles.
4. **Installed into `/usr`** (plan Q7): libraries in `/usr/lib`, headers in
   `/usr/include`, `.pc` files in `/usr/libdata/pkgconfig`, with upstream
   sonames. Libraries that need X go to `/usr/X11` (cairo, nextbsd/nextbsd-gnustep-support#2).
   Never `/usr/local`, which belongs to packages a user adds.
5. **No D-Bus, no Avahi** (plan D2): every option that would pull either in is
   off. mDNSResponder's `dns_sd` is NextBSD's DNS-SD. pkgconf, never
   freedesktop's `pkg-config` (D1).
6. **It ships no `/etc`.** Configuration, if any, comes from `nextbsd-overlays`.

## Components

Built in this order (plan step 9):

| Component | Version | Build | Installs | Ticket |
|---|---|---|---|---|
| giflib | 6.1.3 | make (library only) | `libgif.so.7`, `gif_lib.h` | nextbsd/nextbsd-gnustep-support#1 |
| libjpeg-turbo | 3.2.0 | CMake, jpeg8 ABI, SIMD (NASM on amd64) | `libjpeg.so.8`, `libjpeg.pc` | nextbsd/nextbsd-gnustep-support#1 |
| libpng | 1.6.59 | autotools | `libpng16.so.16`, `libpng16.pc`, `libpng.pc` | nextbsd/nextbsd-gnustep-support#1 |
| gmp | 6.3.0 | autotools, fat on amd64 | `libgmp.so.10`, `gmp.pc` | nextbsd/nextbsd-gnustep-support#1 |
| libsndfile | 1.2.2 | CMake, no external codecs | `libsndfile.so.1`, `sndfile.pc` | nextbsd/nextbsd-gnustep-support#1 |
| libao | 1.2.0 | autotools, OSS plugin only | `libao.so.4`, `ao/plugins-4/liboss.so`, `ao.pc` | nextbsd/nextbsd-gnustep-support#1 |
| sqlite | 3.54.1 | autosetup, library only | `libsqlite3.so.0`, `sqlite3.pc` | nextbsd/nextbsd-gnustep-support#1 |
| libtiff | 4.7.2 | CMake: jpeg, zlib, lzma | `libtiff.so.6`, `libtiff-4.pc` | nextbsd/nextbsd-gnustep-support#1 |
| nettle | 3.10.2 | autotools, fat | `libnettle.so.8`, `libhogweed.so.6`, its small tools (`nettle-hash`, `pkcs1-conv`, `sexp-conv`, ...) | nextbsd/nextbsd-gnustep-support#1 |
| GnuTLS | 3.8.13 | autotools, minimal | `libgnutls.so.30`, `gnutls.pc` | nextbsd/nextbsd-gnustep-support#1 |

GnuTLS is minimal (plan Q3): nettle, hogweed and gmp from this repo, zlib from
base, its bundled libtasn1 and libunistring; p11-kit, libidn2, TPM, DANE,
brotli, zstd, the C++ and OpenSSL-compatibility libraries and the tools are
off. It trusts `/etc/ssl/certs`, the directory base OpenSSL uses.

Licences are per component; see `NOTICE.md`. The top-level `LICENSE` (BSD-2)
covers only the harness in this repo.

## Layout

Same layout as nextbsd-xlibs (wiki: Source-Repo-Conventions):

```
build-gnustep-support.sh     cross-build driver: every component, or some by name
sources.lock                 name, version, SHA-256, URL of every upstream tarball
patches/<name>/series        the patches for <name>, in the order applied
patches/<name>/*.patch       one change each, with an Origin: header
cross/meson/<arch>.ini       meson cross files (host_machine system = 'freebsd')
cross/autotools/<arch>.site  autotools CONFIG_SITE files (cross compiler, pkgconf,
cross/autotools/common.site    cache answers for checks that would run a program)
cross/cmake/<arch>.cmake     CMake toolchain files (libjpeg-turbo, libsndfile, libtiff)
.github/workflows/build.yml  CI: build both arches, publish `continuous`
NOTICE.md                    per-component provenance and licence
```

Nothing upstream is committed. `build-gnustep-support.sh` downloads into
`.build/dl/`, unpacks into `.build/src/` and builds out of tree under `.build/`.
The build refuses a patch directory without a `series` file, a `*.patch` not
listed in it, and a patch without an `Origin:` line. No component needs a
patch yet.

## Build model

`build-gnustep-support.sh` runs inside the `nextbsd-kernel-toolchain`
container (the pinned clang/lld 19.1.7 in `/usr/lib/llvm-19`, meson, ninja,
cmake, pkgconf, autotools) with compat's `continuous` base extracted as the
sysroot. It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged NextBSD base; scratch, since each component is installed into its `/usr` |
| `CROSS_BINDIR` | the toolchain's clang, lld and LLVM binutils (set by the container image) |
| `DESTDIR` | where to stage the artifact; default `/stage` |

For each component, in `COMPONENTS` order, it:

1. downloads the tarball named in `sources.lock`, refuses it unless the SHA-256
   matches, and unpacks it;
2. applies `patches/<name>/series`;
3. runs the upstream build out of tree and installs it with `DESTDIR`:
   - **autotools** in `--host=<triple>` mode with
     `CONFIG_SITE=cross/autotools/<arch>.site`, `--with-sysroot`, shared only
     (sqlite's autosetup `configure` gets the same file sourced into its
     environment; giflib's plain Makefile gets its compiler from it);
   - **CMake** with `cross/cmake/<arch>.cmake`;
   - **meson** (cairo, nextbsd/nextbsd-gnustep-support#2) with two cross files:
     one generated per run with the sysroot and LLVM paths, then
     `cross/meson/<arch>.ini`, which declares `system = 'freebsd'` so
     upstream's FreeBSD code paths apply;
4. checks and tidies the install, then copies it into the sysroot, so later
   components find it, and into `DESTDIR`.

**Checks the build enforces:** everything installs under `/usr` and nothing
replaces a file of the compat base; no `.la` files, docs or info manuals; `.pc`
files are moved to `/usr/libdata/pkgconfig`, have `prefix=/usr`, and name
neither `/usr/local` nor a build path; every library has its upstream soname
and the `DT_NEEDED` entries it should (cross `readelf -d`); each `.pc` resolves
through pkgconf with its dependencies. pkgconf searches only the sysroot
(`/usr/libdata/pkgconfig`, then `/usr/X11/lib/pkgconfig` for cairo) with
`PKG_CONFIG_SYSROOT_DIR` set, so nothing from the Linux host leaks into a build.

```
./build-gnustep-support.sh            # every component
./build-gnustep-support.sh gnutls     # one component; its dependencies must
                                      # already be in $SYSROOT/usr
```

### Host build tools

Build-time only, never shipped. meson, ninja, cmake, pkgconf and the autotools
come from the toolchain image. **NASM** (libjpeg-turbo's x86-64 SIMD) isn't in
the image yet, so the script builds it on the runner from the tarball pinned in
`sources.lock`; it can move into the image later without changing anything
else. gperf, which the plan lists, isn't needed by any component here (GnuTLS
ships its generated files).

## CI, artifact, package

The workflow builds both arches on pull requests, pushes to `main` and manual
runs. A push to `main`, or a manual run from `main`, also publishes
`nextbsd-gnustep-support-<arch>.tar.gz` to the `continuous` release, rooted at
`/`: the whole install, headers, `.pc` files and man pages included (Gershwin
builds GNUstep on the machine, plan D10/D11). Pull requests never publish.

Builds run by hand, in order, after the repos they depend on (the rebuild
policy): there is no `repository_dispatch` trigger, and this repo dispatches
nothing to any other repo. `nextbsd-pkg` repackages the tarball as
`NextBSD-gnustep-support` when it is run by hand (nextbsd/nextbsd-pkg#27).

## Adding a component

1. A line in `sources.lock`: name, version, the tarball's SHA-256, its URL.
2. `build_<name>()` in `build-gnustep-support.sh` (hyphens become
   underscores), registered in `COMPONENTS` in build order. End it with
   `stage` and `soname_check`/`needed_check`/`pc_check` for what it installs.
3. Patches, if any, in `patches/<name>/`, listed in `patches/<name>/series`,
   each with an `Origin:` header (upstream commit or MR, a FreeBSD port file
   used as a reference, or `NextBSD`).
4. A row in `NOTICE.md` and in the table above.
5. Turn off every D-Bus, Avahi or GLib option the component has, and
   say so in the function's comment.
