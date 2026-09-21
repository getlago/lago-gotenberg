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
ARG GOTENBERG_VERSION=v8.32.0
ARG PDFCPU_VERSION=v0.12.0
ARG PDFTK_VERSION=v3.3.3
ARG UNOCONVERTER_VERSION=v0.2.0

# ---------------------------------------------------------------------------
# Build stage — go binaries + downloads. One stage instead of upstream's
# four; the lago-packages/gotenberg-build image ships go, git, curl and
# build-base, so there's no reason to split further.
# ---------------------------------------------------------------------------
FROM ${BUILD_IMAGE} AS build

ARG GOTENBERG_VERSION
ARG PDFCPU_VERSION
ARG PDFTK_VERSION
ARG UNOCONVERTER_VERSION

WORKDIR /src

# pdfcpu — bundled Go PDF processor. Built with the same ldflags as
# upstream so `pdfcpu version` returns the pinned version string.
RUN mkdir pdfcpu && cd pdfcpu && \
    curl -fsSL "https://github.com/pdfcpu/pdfcpu/archive/refs/tags/${PDFCPU_VERSION}.tar.gz" -o pdfcpu.tar.gz && \
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
    chmod +x /out/unoconverter

# pdftk-java — pdftk is unmaintained upstream; pdftk-java is the Java
# port everyone uses. Same URL as upstream gotenberg.
RUN curl -fsSL -o /out/pdftk-all.jar \
      "https://gitlab.com/api/v4/projects/5024297/packages/generic/pdftk-java/${PDFTK_VERSION}/pdftk-all.jar" && \
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

# Chromium hyphenation dictionaries. The base image sets
# CHROMIUM_HYPHEN_DATA_DIR_PATH=/opt/gotenberg/chromium-hyphen-data,
# and gotenberg's chromium module refuses to start without the
# directory existing on disk — this copy is what makes it happy.
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
