# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for dateutils, built ON TOP of the org C/C++ base.
# The base provides clang/llvm + libFuzzer + the build-contract ENV
# (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/STANDALONE_FUZZ_MAIN/SRC).
FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# dateutils' autotools build needs a few extra host tools that the base does not
# ship: gperf (generates lib/fmt-special.c), libtool + libltdl-dev (LT_INIT and
# the ltdl m4 macros referenced by configure.ac). Baked as a layer so the
# air-gapped PATCH re-run needs no network.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        gperf libtool libltdl-dev \
 && rm -rf /var/lib/apt/lists/*
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
