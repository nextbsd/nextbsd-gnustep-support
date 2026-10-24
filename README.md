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
| **`nextbsd-gnustep-support`** | **image formats, sound, SQLite, GnuTLS, cairo, flite, FFmpeg** | **`NextBSD-gnustep-support`** |
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
   sonames. Libraries that need X go to `/usr/X11` beside nextbsd-xlibs (cairo,
   nextbsd/nextbsd-gnustep-support#2), with their `.pc` files in
   `/usr/X11/lib/pkgconfig` as xlibs has them.
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
| cairo | 1.18.6 | meson, into `/usr/X11`; xlib, xcb, png, FreeType/fontconfig; no GLib, no LZO | `/usr/X11/lib/libcairo.so.2`, `libcairo-script-interpreter.so.2`, `cairo.pc` and its per-backend `.pc` files | nextbsd/nextbsd-gnustep-support#2 |
| flite | 2.2 | its configure and makefiles, in tree; one voice | `libflite.so.1`, `libflite_cmulex.so.1`, `libflite_usenglish.so.1`, `libflite_cmu_us_kal16.so.1`, `flite/*.h` | nextbsd/nextbsd-gnustep-support#3 |
| FFmpeg | 9.0.2 | its configure, LGPL, decoders only | `libavutil.so.61`, `libavcodec.so.63`, `libavformat.so.63`, `libavdevice.so.63`, `libavfilter.so.12`, `libswscale.so.10`, `libswresample.so.7`, their `.pc` files, `ffmpeg` | nextbsd/nextbsd-gnustep-support#3 |

GnuTLS is minimal (plan Q3): nettle, hogweed and gmp from this repo, zlib from
base, its bundled libtasn1 and libunistring; p11-kit, libidn2, TPM, DANE,
brotli, zstd, the C++ and OpenSSL-compatibility libraries and the tools are
off. It trusts `/etc/ssl/certs`, the directory base OpenSSL uses.

cairo (gnustep-back's cairo backend) needs X, so it installs into `/usr/X11`
(plan Q7), the only component here that does. It builds against
nextbsd-xlibs, whose `continuous` artifact CI unpacks into the sysroot as
build input only (never into this repo's artifact): pixman, freetype,
fontconfig, expat and the X libraries (libX11, libXext, libXrender, libxcb).
libpng comes from this repo and zlib from base. On: the image, xlib (with
XRender), xcb (with SHM), PNG, PDF, PostScript, SVG, script and tee surfaces,
FreeType and fontconfig fonts. Off: GLib (so no cairo-gobject), LZO, xlib-xcb,
Quartz, DirectWrite, libspectre, the bfd symbol lookup, the GTK utilities,
tests (and the poppler, librsvg and ghostscript converters they use) and
gtk-doc. Its `DT_NEEDED` entries are bare sonames in `/lib`, `/usr/lib` and
`/usr/X11/lib` with no `RUNPATH`; at run time `/usr/X11/lib` is found through
the ldconfig hints, as for xlibs' own libraries (nextbsd/nextbsd-overlays#22).
cairo-trace and cairo-fdr, GPL-3.0-or-later debugging tools upstream's meson
always builds, are removed before staging.

flite is trimmed to one voice (plan Q6): **cmu_us_kal16**, the voice
gnustep-gui's speech server registers (`Tools/speech/FliteSpeechEngine.m`; its
configure builds the `speech` and `say` tools only when
`-lflite_cmu_us_kal16` links), with the US English language and CMU lexicon
it needs. Output is OSS. No `flite` programs, static archives or other voices.

FFmpeg is LGPL-2.1-or-later and decoder-only (plan Q6): no `--enable-gpl`,
`--enable-version3` or `--enable-nonfree`, `--disable-autodetect` and
`--disable-iconv` (no external library of any kind, zlib and libc's iconv
included), no network, no hardware
acceleration, no documentation. It has FFmpeg's own decoders, demuxers and
parsers for local playback of the common formats (AAC, AC-3/E-AC-3, ALAC,
FLAC, MP1/2/3, Opus, Vorbis, PCM and IMA/MS ADPCM; H.264, HEVC, VP8, VP9,
MPEG-1/2/4, H.263, MJPEG, Theora; MP4/MOV, Matroska/WebM, Ogg, WAV, AIFF, CAF,
AU, AVI, MPEG-PS/TS and raw audio streams), the `file` and `pipe` protocols,
and the few pieces Whisper's `ffmpeg` command lines need: the raw 32-bit float
PCM encoder and muxer, resampling, and the OSS input device for recording. The
users are gnustep-gui (NSMovie, NSSound), libs-av, Gershwin's Player and
Whisper.

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
listed in it, and a patch without an `Origin:` line. libao and flite carry
patches.

## Build model

`build-gnustep-support.sh` runs inside the `nextbsd-kernel-toolchain`
container (the pinned clang/lld 19.1.7 in `/usr/lib/llvm-19`, meson, ninja,
cmake, pkgconf, autotools) with compat's `continuous` base and nextbsd-xlibs'
`continuous` artifact (`/usr/X11`, for cairo) extracted as the sysroot. The
xlibs files are build input only; they never reach `DESTDIR`. It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged NextBSD base with nextbsd-xlibs; scratch, since each component is installed into it |
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
     environment; giflib's plain Makefile gets its compiler from it; flite's
     configure runs in its source tree, the only place its makefiles build);
   - **FFmpeg's own `configure`** in `--enable-cross-compile` mode, with the
     compiler and LLVM tools from the same file;
   - **CMake** with `cross/cmake/<arch>.cmake`;
   - **meson** (cairo) with two cross files:
     one generated per run with the sysroot and LLVM paths, then
     `cross/meson/<arch>.ini`, which declares `system = 'freebsd'` so
     upstream's FreeBSD code paths apply;
4. checks and tidies the install, then copies it into the sysroot, so later
   components find it, and into `DESTDIR`.

**Checks the build enforces:** everything installs under the component's
prefix (`/usr`, or `/usr/X11` for cairo) and nothing replaces a file of the
compat base or nextbsd-xlibs; no `.la` files, docs or info manuals; `.pc` files
are moved to the prefix's directory (`/usr/libdata/pkgconfig`, or
`/usr/X11/lib/pkgconfig`), have that `prefix=`, and name neither `/usr/local`
nor a build path; every library has its upstream soname and the `DT_NEEDED`
entries it should (cross `readelf -d`); cairo's libraries also have every
`DT_NEEDED` in `/lib`, `/usr/lib` or `/usr/X11/lib` and no `RPATH`/`RUNPATH`;
each `.pc` resolves through pkgconf with its dependencies. pkgconf searches only the sysroot
(`/usr/libdata/pkgconfig`, then `/usr/X11/lib/pkgconfig` for cairo) with
`PKG_CONFIG_SYSROOT_DIR` set, so nothing from the Linux host leaks into a build.

```
./build-gnustep-support.sh            # every component
./build-gnustep-support.sh gnutls     # one component; its dependencies must
                                      # already be in $SYSROOT
```

### Host build tools

Build-time only, never shipped. meson, ninja, cmake, pkgconf and the autotools
come from the toolchain image. **NASM** (libjpeg-turbo's x86-64 SIMD and
FFmpeg's x86-64 assembly) isn't in the image yet, so the script builds it on
the runner from the tarball pinned in `sources.lock`; it can move into the
image later without changing anything else. gperf, which the plan lists, isn't needed by any component here (GnuTLS
ships its generated files).

## CI, artifact, package

The workflow builds both arches on pull requests, pushes to `main` and manual
runs. A push to `main`, or a manual run from `main`, also publishes
`nextbsd-gnustep-support-<arch>.tar.gz` to the `continuous` release, rooted at
`/`: the whole install, headers, `.pc` files and man pages included (Gershwin
builds GNUstep on the machine, plan D10/D11). Pull requests never publish.

Builds run by hand, in order, after the repos they depend on (compat and
nextbsd-xlibs; the rebuild policy): there is no `repository_dispatch` trigger, and this repo dispatches
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
