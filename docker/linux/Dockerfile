# syntax=docker/dockerfile:1
# ===========================================================================
# FLASHIda local CI -- the Linux lane.
#
# Toolchain ONLY. No repository source is baked into this image: the workspace
# arrives at run time as a read-only bind mount at /work, the build tree and
# the ccache arrive as named volumes. Nothing here is licensed, secret, or
# machine-specific, so the image is reproducible on any dev machine.
#
# WHAT THIS LANE IS AUTHORITATIVE FOR (design doc section 1):
#   "does it compile under gcc"                    -> authoritative
#   "does the C++ logic behave"                    -> strong, not authoritative
#   "is sizeof(ScanCommand) == 2048 still true"    -> yes
#   "is this float value right"                    -> NEVER. Ask CI.
#   "may this golden be committed"                 -> NEVER. This lane cannot
#                                                     capture or promote one.
#
# ---------------------------------------------------------------------------
# BUILD -- the context is docker/linux/, NOT the repo root (which is ~1.6 GB):
#
#   docker build -f docker/linux/Dockerfile -t flashida-linux:<tag> docker/linux
#
# The only COPY is entrypoint.sh, so the context transfer is two small files.
#
# ---------------------------------------------------------------------------
# RUN -- the mount contract (design doc section 3 and 6). Every path below is
# a container path; <repo> is resolved by the caller from its own location,
# never hard-coded.
#
#   docker run --rm --network none \
#     -v <repo>:/work:ro \
#     -v flashida-build-linux-rel:/work/OpenMS/cmake-build-linux-release \
#     -v flashida-ccache-linux:/ccache \
#     -e CCACHE_DIR=/ccache -e CCACHE_BASEDIR=/work -e CCACHE_MAXSIZE=30G \
#     -e OPENMS_DATA_PATH=/work/OpenMS/share/OpenMS \
#     flashida-linux:<tag> all
#
# The nesting is LOAD-BEARING and is why the build dir must sit at
# /work/OpenMS/cmake-build-<...>:
#   * add_test(... WORKING_DIRECTORY ${CMAKE_BINARY_DIR}) -- so every test's
#     CWD is the build dir;
#   * the class tests hard-code "../../FlashIDA/test-data/..." (17 distinct
#     literals), which resolves only when the build dir is exactly two levels
#     above <repo>/FlashIDA/.
# Renaming the build dir, or mounting the repo anywhere but /work, breaks the
# fixtures. entrypoint.sh asserts all of this before it runs anything.
#
# THE CALLER MUST `mkdir -p <repo>/OpenMS/cmake-build-linux-release` FIRST:
# Docker cannot create a mount point inside a read-only bind. That name is
# already covered by OpenMS/.gitignore's `cmake-build-*`, so no .gitignore
# change is needed in either submodule.
#
# `--network none` is required for `configure` and asserted by the entrypoint:
# ENABLE_TDL defaults ON and tdl-config.cmake falls back to a configure-time
# FetchContent clone of github.com/jbeder/yaml-cpp when yaml-cpp >= 0.8.0 is
# not found. Noble ships 0.8.0 (jammy ships 0.7.0) -- that, and nothing else,
# is why this image is 24.04 and not 22.04. Running offline turns a silently
# vendored yaml-cpp into a loud configure failure.
#
# --network none also means the image must never need the network at run time.
# ===========================================================================

# Pinned by digest so every dev machine resolves the same base layer.
# Digest verified present locally as ubuntu:24.04 (Ubuntu 24.04.4 LTS).
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---------------------------------------------------------------------------
# The dependency set. Every name below resolves on noble (verified with
# `apt-get install -s` against the noble/noble-updates/noble-security indexes),
# and this exact set is the one the design doc records as producing a green
# offline configure of this fork.
#
#   build-essential g++ make git ca-certificates  toolchain + submodule tooling
#   cmake ninja-build ccache                      the build system CI also uses
#   rsync                                         tree copies inside the volume
#   gawk                                          docker/ci-lists.awk host-side parity
#   mawk                                          already in the base image; named
#                                                 explicitly because installing gawk
#                                                 takes over the /usr/bin/awk
#                                                 alternative, and the ci-lists
#                                                 parser must stay provably
#                                                 mawk-clean (no gensub, no
#                                                 length(array)). Verified: gawk
#                                                 and mawk coexist, no Remv.
#   qt6-base-dev libeigen3-dev                    OpenMS core deps
#   libboost-{date-time,regex,iostreams,math,random}-dev
#   libxerces-c-dev                               mzML parsing
#   zlib1g-dev libbz2-dev liblzma-dev libzstd-dev the BOOST_USE_STATIC link closure
#   libsvm-dev coinor-libcoinmp-dev               OpenMS math deps
#   libyaml-cpp-dev                               0.8.0 -- see the --network none note
#
# NOT installed on purpose: no Qt from aqt, no contrib tarball (that archive is
# contrib_build-Windows.tar.gz), no CMAKE_PREFIX_PATH/Eigen3_DIR juggling --
# on Linux apt puts every config file where CMake already looks.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential g++ make git ca-certificates \
      cmake ninja-build ccache rsync gawk mawk \
      qt6-base-dev libeigen3-dev \
      libboost-date-time-dev libboost-regex-dev libboost-iostreams-dev \
      libboost-math-dev libboost-random-dev \
      libxerces-c-dev zlib1g-dev libbz2-dev liblzma-dev libzstd-dev \
      libsvm-dev coinor-libcoinmp-dev libyaml-cpp-dev \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Give /usr/bin/awk back to mawk.
#
# Installing gawk takes the `awk` update-alternatives link (gawk's priority is
# higher than mawk's), so without this line the image's default `awk` IS gawk.
# That matters because docker/ci-lists.sh defaults to `${FLCI_AWK:-awk}`, and
# the design doc's section 5 makes the container the place where the workflow
# parser is proven mawk-clean: gawk silently strips CR where mawk does not, so
# a CRLF workflow parses to 26 targets under gawk and ZERO under mawk. Running
# the self-test under gawk here would validate the one implementation that
# cannot see that bug.
#
# gawk stays installed and callable as `gawk` for host-parity comparisons.
RUN update-alternatives --set awk /usr/bin/mawk \
 && [ "$(readlink -f "$(command -v awk)")" = /usr/bin/mawk ] \
 || (echo "FATAL: /usr/bin/awk is not mawk; the ci-lists self-test would run under gawk" >&2; exit 1)

COPY entrypoint.sh /entrypoint.sh

# The repo is checked out on a host with core.autocrlf=true. A root
# .gitattributes pins docker/** to LF, but strip CR here too so a checkout
# made before that file existed cannot produce `bad interpreter: /bin/bash^M`
# inside the image.
RUN sed -i 's/\r$//' /entrypoint.sh && chmod 0755 /entrypoint.sh

LABEL org.opencontainers.image.title="flashida-linux" \
      org.opencontainers.image.description="gcc/ninja/ctest lane for FLASHIda local CI: builds libOpenMS.so and the FLASH class tests. Toolchain only, no source." \
      flashida.lane="linux" \
      flashida.base="ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517" \
      flashida.authoritative-for="gcc compilation" \
      flashida.never="float values, golden capture, golden promotion, C#/P-Invoke"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["help"]
