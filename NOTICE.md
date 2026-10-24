# Upstream sources & licences

`nextbsd-gnustep-support` builds third-party libraries from pinned upstream
release tarballs (`sources.lock`), each **under its own upstream licence**. The
licence files inside each tarball are authoritative; this table records
provenance and does not relicense anything. NextBSD's changes, if any, are in
`patches/<name>/` and are under the licence of the component they change.

The top-level **`LICENSE` (BSD 2-Clause)** covers only what this repo authors:
`build-gnustep-support.sh`, `sources.lock`, `cross/`, `.github/workflows/`, this `NOTICE.md`
and `README.md`.

## Shipped in `NextBSD-gnustep-support`

| Component | Upstream | Version | Licence (file in the tarball) |
|---|---|---|---|
| giflib | sourceforge.net/projects/giflib | 6.1.3 | MIT (`COPYING`) |
| libjpeg-turbo | github.com/libjpeg-turbo/libjpeg-turbo | 3.2.0 | IJG License and BSD 3-Clause; some modules under the less restrictive zlib License, subsumed by those two (`LICENSE.md`, `README.ijg`) |
| libpng | libpng.sourceforge.io (pnggroup) | 1.6.59 | PNG Reference Library License version 2 (`LICENSE`) |
| gmp | gmplib.org | 6.3.0 | LGPL-3.0-or-later or GPL-2.0-or-later, dual (`COPYING.LESSERv3`, `COPYINGv2`, `README`) |
| libsndfile | github.com/libsndfile/libsndfile | 1.2.2 | LGPL-2.1-or-later (`COPYING`) |
| libao | xiph.org | 1.2.0 | **GPL-2.0-or-later** (`COPYING`, `src/*.c` headers) |
| sqlite | sqlite.org (amalgamation, `sqlite-autoconf-3540100`) | 3.54.1 | Public domain (`sqlite3.h`, `sqlite3.c` headers) |
| libtiff | gitlab.com/libtiff/libtiff (download.osgeo.org) | 4.7.2 | libtiff License, BSD-like (`LICENSE.md`) |
| nettle (with hogweed) | gnu.org/software/nettle | 3.10.2 | LGPL-3.0-or-later or GPL-2.0-or-later, dual (`COPYING.LESSERv3`, `COPYINGv2`, `README`) |
| GnuTLS | gnutls.org | 3.8.13 | LGPL-2.1-or-later for `libgnutls` (`COPYING.LESSERv2`, `README.md`); the tools, tests and `libgnutls-openssl`, which are GPL-3.0-or-later, aren't built |
| ↳ libtasn1 (bundled in GnuTLS, `lib/minitasn1`) | gnu.org/software/libtasn1 | as bundled in GnuTLS 3.8.13 | LGPL-2.1-or-later (file headers) |
| ↳ libunistring (bundled in GnuTLS, `lib/unistring`) | gnu.org/software/libunistring | as bundled in GnuTLS 3.8.13 | LGPL-3.0-or-later or GPL-2.0-or-later (file headers) |
| flite | github.com/festvox/flite (tag `v2.2`) | 2.2 | CMU Flite licence: BSD-style, with the conditions that modifications be marked as such and that authors' names not be removed or used for endorsement; a few files (`src/cg/cst_mlpg.*`, `src/regex/*`, `src/speech/rateconv.c`, `src/speech/g72*`, parts of `lang/usenglish`) under similar permissive terms of their own (`COPYING`). NextBSD's changes are marked in `patches/flite/` |
| FFmpeg | ffmpeg.org | 9.0.2 | LGPL-2.1-or-later (`LICENSE.md`, `COPYING.LGPLv2.1`). Built without `--enable-gpl`, `--enable-version3` or `--enable-nonfree`, so no GPL or (L)GPLv3 code is compiled in; configure reports "LGPL version 2.1 or later" and the build checks it |

**libao is GPL-2.0-or-later,** not LGPL. Anything that links it (gnustep-gui's
`AudioOutput` sound bundle, Gershwin's Player) is a combined work under the GPL
when distributed. The plan (E24, audit 2) keeps libao because gnustep-gui only
builds NSSound with both libsndfile and libao.

## Build-time only (never shipped)

| Tool | Upstream | Version | Licence |
|---|---|---|---|
| NASM | nasm.us | 3.02 | BSD 2-Clause (`LICENSE`) |
