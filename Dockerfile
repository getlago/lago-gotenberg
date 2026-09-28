# syntax=docker/dockerfile:1.26

# Hardened Wolfi/apko-based gotenberg image. Replaces the previous
# thin wrapper on `gotenberg/gotenberg:8.32.0` (Debian) with a build
# from source on the lago-packages base images, published to GHCR.
# See getlago/lago-packages for the base image definitions.
#
# TAG PIN: both ARGs below default to `:latest`, which the daily
# rebuild of lago-packages keeps within ~24h of upstream Wolfi. For
# reproducible / air-gapped builds, override to an immutable
# `:<lago-packages-commit-sha>` tag at build time or edit here.

ARG BUILD_IMAGE=ghcr.io/getlago/gotenberg-build:985088eecde297e711e0847dcf7a17e1216b8659
ARG RUNTIME_IMAGE=ghcr.io/getlago/gotenberg-base:985088eecde297e711e0847dcf7a17e1216b8659

# Pinned upstream versions — match the previous
# `gotenberg/gotenberg:8.32.0` bundle so behaviour stays identical.
#
# Every network fetch below is verified against its pinned sha256 in
# the same RUN as the curl, per the "no unverified downloads" rule in
# getlago/lago-packages/CLAUDE.md. Bumping any *_VERSION means
# re-hashing the corresponding artifact and updating the matching
# *_SHA256 line — do both in the same commit, or the build fails fast.
ARG GOTENBERG_VERSION=v8.32.0
ARG GOTENBERG_SHA256=f0fa9830fbb26b92cc3a148491235225e157e9e48ec6662f8a05f9d376c879f1
ARG PDFCPU_VERSION=v0.15.0
ARG PDFCPU_SHA256=69924a7363ea19b4f3d4799ebf78bcabfec75a735c9569983a6e2834b5e8c6b3
ARG PDFTK_VERSION=v3.3.3
ARG PDFTK_SHA256=a694d49bd03e1edd4c23b3ba808bc221eb8a8ccfe7bfd2a0a884b2b2fb425188
ARG UNOCONVERTER_VERSION=v0.2.0
ARG UNOCONVERTER_SHA256=c44c4a86ef68c1f34ee7a026e5ee8334346d1012a52e451cbffd25576cee97cf

# ---------------------------------------------------------------------------
# Build stage — go binaries + downloads. One stage instead of upstream's
# four; the lago-packages/gotenberg-build image ships go, git, curl and
# build-base, so there's no reason to split further.
# ---------------------------------------------------------------------------
FROM ${BUILD_IMAGE} AS build

ARG GOTENBERG_VERSION
ARG GOTENBERG_SHA256
ARG PDFCPU_VERSION
ARG PDFCPU_SHA256
ARG PDFTK_VERSION
ARG PDFTK_SHA256
ARG UNOCONVERTER_VERSION
ARG UNOCONVERTER_SHA256

WORKDIR /src

# pdfcpu — bundled Go PDF processor. Built with the same ldflags as
# upstream so `pdfcpu version` returns the pinned version string.
# The `sha256sum -c -` after curl aborts the RUN if upstream ever
# reshuffles the tarball for a released tag — the build never sees
# unverified bytes.
RUN mkdir pdfcpu && cd pdfcpu && \
    curl -fsSL "https://github.com/pdfcpu/pdfcpu/archive/refs/tags/${PDFCPU_VERSION}.tar.gz" -o pdfcpu.tar.gz && \
    echo "${PDFCPU_SHA256}  pdfcpu.tar.gz" | sha256sum -c - && \
    tar --strip-components=1 -xzf pdfcpu.tar.gz && \
    go mod download && go mod verify && \
    go build -o /out/pdfcpu \
      -ldflags "-s -w -X 'main.version=${PDFCPU_VERSION}' -X 'github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model.VersionStr=${PDFCPU_VERSION}' -X main.builtBy=lago-gotenberg" \
      ./cmd/pdfcpu

# gotenberg + gotenberg-chromium + gotenberg-libreoffice — three
# entrypoints from the same source tree. The chromium module also
# requires `build/chromium-hyphen-data/` at runtime (per-language
# hyphenation dictionaries); we copy it to /out/chromium-hyphen-data
# here and stage it under CHROMIUM_HYPHEN_DATA_DIR_PATH in the
# runtime image below.
RUN mkdir gotenberg && cd gotenberg && \
    curl -fsSL "https://github.com/gotenberg/gotenberg/archive/refs/tags/${GOTENBERG_VERSION}.tar.gz" -o gotenberg.tar.gz && \
    echo "${GOTENBERG_SHA256}  gotenberg.tar.gz" | sha256sum -c - && \
    tar --strip-components=1 -xzf gotenberg.tar.gz && \
    go mod download && go mod verify && \
    go build -o /out/gotenberg -ldflags "-s -w -X 'github.com/gotenberg/gotenberg/v8/cmd.Version=${GOTENBERG_VERSION}'" cmd/gotenberg/main.go && \
    go build -o /out/gotenberg-chromium -ldflags "-s -w -X 'github.com/gotenberg/gotenberg/v8/cmd.Version=${GOTENBERG_VERSION}'" cmd/gotenberg-chromium/main.go && \
    go build -o /out/gotenberg-libreoffice -ldflags "-s -w -X 'github.com/gotenberg/gotenberg/v8/cmd.Version=${GOTENBERG_VERSION}'" cmd/gotenberg-libreoffice/main.go && \
    cp -r build/chromium-hyphen-data /out/chromium-hyphen-data

# unoconverter — Python script (LibreOffice UNO bridge). Same source URL as
# upstream gotenberg's downloader-stage.
RUN curl -fsSL -o /out/unoconverter \
      "https://raw.githubusercontent.com/gotenberg/unoconverter/${UNOCONVERTER_VERSION}/unoconv" && \
    echo "${UNOCONVERTER_SHA256}  /out/unoconverter" | sha256sum -c - && \
    chmod +x /out/unoconverter

# pdftk-java — pdftk is unmaintained upstream; pdftk-java is the Java
# port everyone uses. Same URL as upstream gotenberg.
RUN curl -fsSL -o /out/pdftk-all.jar \
      "https://gitlab.com/api/v4/projects/5024297/packages/generic/pdftk-java/${PDFTK_VERSION}/pdftk-all.jar" && \
    echo "${PDFTK_SHA256}  /out/pdftk-all.jar" | sha256sum -c - && \
    chmod +x /out/pdftk-all.jar


# ---------------------------------------------------------------------------
# Runtime stage — hardened Wolfi. Every runtime dependency (chromium,
# libreoffice-25.8, openjdk-21-jre, qpdf, exiftool, python-3.11, dumb-init,
# Noto/Liberation fonts) is baked into lago-packages/gotenberg-base, so
# this stage only drops in the binaries + custom fonts + the pdftk shim.
# ---------------------------------------------------------------------------
FROM ${RUNTIME_IMAGE}

# GHCR reads this from the image manifest annotations to link the published
# package back to its source repository — makes provenance visible on the
# package page and lets repo permissions govern the package.
LABEL org.opencontainers.image.source="https://github.com/getlago/lago-gotenberg"
LABEL org.opencontainers.image.description="Hardened Wolfi-based gotenberg image for Lago"
LABEL org.opencontainers.image.licenses="MIT"

# gotenberg's chromium module refuses to boot without this env var. It
# belongs at the base, but gotenberg-base never exported it (the fix,
# lago-packages#3, is still open), so the consumer image has to own it.
# Keep it even once the base ships it: it costs nothing and keeps the
# image self-sufficient against a base rebuild that re-strips the var.
ENV CHROMIUM_HYPHEN_DATA_DIR_PATH=/opt/gotenberg/chromium-hyphen-data

# The base image ships with USER 65532 as the default. Switch to root so
# the RUN commands below can write to /usr/bin and /usr/local/share/fonts.
# The final USER 65532 line at the bottom is what actually ships.
USER root

COPY --from=build /out/pdfcpu               /usr/bin/pdfcpu
COPY --from=build /out/gotenberg            /usr/bin/gotenberg
COPY --from=build /out/gotenberg-chromium   /usr/bin/gotenberg-chromium
COPY --from=build /out/gotenberg-libreoffice /usr/bin/gotenberg-libreoffice
COPY --from=build /out/unoconverter         /usr/bin/unoconverter
COPY --from=build /out/pdftk-all.jar        /usr/bin/pdftk-all.jar

# Chromium hyphenation dictionaries. gotenberg's chromium module needs
# both the env var set above and this directory present on disk; it
# refuses to start if either is missing.
COPY --from=build --chown=65532:65532 /out/chromium-hyphen-data /opt/gotenberg/chromium-hyphen-data

# pdftk shim — upstream gotenberg wraps pdftk-java in a one-line bash
# script so callers can `pdftk foo.pdf …` without invoking `java -jar`.
# unoconverter references `python`, which Wolfi exposes as `python3.11`.
RUN printf '#!/bin/bash\n\nexec java -jar /usr/bin/pdftk-all.jar "$@"\n' > /usr/bin/pdftk && \
    chmod +x /usr/bin/pdftk && \
    ln -sf /usr/bin/python3.11 /usr/bin/python

# Custom lago fonts — the only content-carrying change vs upstream
# gotenberg. Preserved from the previous wrapper Dockerfile.
COPY ./fonts/ /usr/local/share/fonts/

USER 65532
WORKDIR /home/nonroot

# Gotenberg's default HTTP port. Matches the upstream Dockerfile so
# nothing on the k8s Service side needs to change.
EXPOSE 3000

# gotenberg-base's entrypoint is `dumb-init --`, so the container ends
# up running `dumb-init -- gotenberg` — zombie chromium/soffice
# subprocesses get reaped.
CMD ["gotenberg"]
