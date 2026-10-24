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
   `sources.lock`. No FreeBSD packages, ports or ports tools. NextBSD's changes
   are a patch series in `patches/<name>/`, never edits to a vendored tree.
3. **Upstream build systems** (autotools, CMake, meson, plain make) driven in
   cross mode with the files in `cross/`; no reach-over makefiles.
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
| nettle | 3.10.2 | autotools, fat | `libnettle.so.8`, `libhogweed.so.6` | nextbsd/nextbsd-gnustep-support#1 |
| GnuTLS | 3.8.13 | autotools, minimal | `libgnutls.so.30`, `gnutls.pc` | nextbsd/nextbsd-gnustep-support#1 |

GnuTLS is minimal (plan Q3): nettle, hogweed and gmp from this repo, zlib from
base, its bundled libtasn1 and libunistring; p11-kit, libidn2, TPM, DANE,
brotli, zstd, the C++ and OpenSSL-compatibility libraries and the tools are
off. It trusts `/etc/ssl/certs`, the directory base OpenSSL uses.

Licences are per component; see `NOTICE.md`. The top-level `LICENSE` (BSD-2)
covers only the harness in this repo.

## Layout

```
build-gnustep-support.sh     cross-build driver: every component, or some by name
sources.lock                 <name> <version> <sha256> <url> for every tarball
patches/<name>/NNNN-*.patch  NextBSD's changes to a component, applied in order
cross/cross-<arch>.cmake     CMake toolchain files (amd64, arm64)
cross/cross-<arch>.ini       meson cross files (amd64, arm64; system = 'freebsd')
.github/workflows/build.yml  CI: build both arches, publish `continuous` from main
NOTICE.md                    per-component provenance and licence
```

Each patch starts with a header saying where it comes from (upstream commit,
bug report, or "NextBSD") and why it's needed, and applies with `patch -p1`
from the top of the unpacked tarball. A component with no changes has no
`patches/` directory.

## Build model

`build-gnustep-support.sh` runs inside the `nextbsd-kernel-toolchain`
container with the compat `continuous` base staged as the cross sysroot, the
same setup as `nextbsd-contrib`. It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged compat base (never written to) |
| `CROSS_BINDIR` | the toolchain's clang, lld and LLVM binutils (set by the container image) |
| `DESTDIR` | where to stage; default `/stage` |

For each component the script downloads the tarball (cached in
`.build/dist/`), checks its SHA-256 against `sources.lock`, unpacks it, applies
`patches/<name>/`, and runs the upstream build out of tree with
`--host=<triple>` (autotools) or the `cross/` files (CMake, meson). Configure
checks that would run a test program get their answers as cache variables,
commented where they're set.

The components build on each other, so each one is installed twice:

- **in full into a working sysroot**, `.build/sysroot-<arch>`, a hard-linked
  copy of `$SYSROOT`. Later components find its headers, libraries and `.pc`
  files there. pkgconf reads only that sysroot's `/usr/libdata/pkgconfig`,
  never the runner's;
- **the shipped subset into `$DESTDIR`**: the shared libraries and their
  development links, headers and `.pc` files (Gershwin builds GNUstep on the
  machine, so the development files ship), stripped and mode 0444 as FreeBSD
  base installs them. No static libraries, libtool archives, programs, docs or
  man pages.

The script fails if a shipped path already exists in the compat base, if a
library's soname differs from upstream's, if a `.pc` file names a build path
or `/usr/local`, or if a shipped `.pc` doesn't resolve with pkgconf.

```
./build-gnustep-support.sh            # every component, fresh working sysroot
./build-gnustep-support.sh gnutls     # one component, reusing the working sysroot
```

Nothing here links against nextbsd-userland: these components need only the
compat base. Components that need X (cairo) will stage nextbsd-xlibs'
`continuous` artifact into the sysroot as well.

### Host build tools

Build-time only, never shipped. meson, ninja, cmake, pkgconf and the autotools
come from the toolchain image. **NASM** (libjpeg-turbo's x86-64 SIMD) isn't in
the image yet, so the script builds it on the runner from the pinned tarball
in `sources.lock`; it can move into the image later without changing anything
else. gperf, which the plan lists, isn't needed by any component here yet
(GnuTLS ships its generated files).

## CI, artifact, package

The workflow builds both arches on every pull request. A push to `main`, or a
manual run on `main`, also publishes `nextbsd-gnustep-support-<arch>.tar.gz`
to the `continuous` release, rooted at `/`. Pull requests never publish.

Builds run by hand, in order, after the repos they depend on (the rebuild
policy): there is no `repository_dispatch` trigger, and this repo dispatches
nothing to any other repo. `nextbsd-pkg` repackages the tarball as
`NextBSD-gnustep-support` when it is run by hand (nextbsd/nextbsd-pkg#27).

## Adding a component

1. A line in `sources.lock`: name, version, the tarball's SHA-256, its URL.
2. `build_<name>()` in `build-gnustep-support.sh` (hyphens become
   underscores), registered in `COMPONENTS` in build order. End it with
   `publish` and `soname_check`/`needed_check` for what it installs.
3. Patches, if any, in `patches/<name>/` with a provenance header each.
4. A row in `NOTICE.md` and in the table above.
5. Turn off every D-Bus, Avahi or GLib option the component has, and
   say so in the function's comment.
