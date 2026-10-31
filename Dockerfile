# syntax=docker/dockerfile:1.26

# Hardened Wolfi/apko-based gotenberg image. Replaces the previous
# thin wrapper on `gotenberg/gotenberg:8.32.0` (Debian) with a build
# from source on the lago-packages base images, published to GHCR.
# See getlago/lago-packages for the base image definitions.
#
# BASE PIN: `:<YYYYMMDD>-r<run>@sha256:<index digest>`, an immutable
# lago-packages publish. Docker builds from the digest, so a build is
# reproducible. Renovate (getlago/lago-packages renovate/lago-bases) moves tag
# and digest together when a newer base is published; the base refresh
# rebuilds deployed tags with a newer RUNTIME_IMAGE in between.
#
# The base pin carries chromium 156.0.8078.47 from Lago's melange overlay,
# replacing Wolfi's 149 — which had no fix available and failed the base's
# CVE gate daily. See getlago/lago-packages packages/chromium.yaml.
#
# The two ARGs pin different lago-packages commits on purpose. lago-packages
# publishes a base only when its digest moves, so each image's newest tag is
# the commit that last changed it.

ARG BUILD_IMAGE=ghcr.io/getlago/gotenberg-build:20261031-r1145@sha256:ed9fafc6fa8d35884b29edfc03fdd43e532a7589a68eec32a8397ca2b2966569
ARG RUNTIME_IMAGE=ghcr.io/getlago/gotenberg-base:20261031-r1144@sha256:c8a972ec8f362930d1279ab4b7dd257babfa5dc64273dc5fe06474e9d9e25d3e

# Pinned upstream downloads. Renovate moves each *_VERSION (getlago/lago-packages
# renovate/pinned-downloads), and the PR workflow recomputes the matching
# *_SHA256 from the `# sha256:` URL. Each fetch below is verified against
# its sha256 in the same RUN as the curl ("no unverified downloads",
# getlago/lago-packages/CLAUDE.md). gotenberg and unoconverter move
# together: gotenberg passes unoconverter flags.
# renovate: datasource=github-releases depName=gotenberg/gotenberg
# sha256: https://github.com/gotenberg/gotenberg/archive/refs/tags/${VERSION}.tar.gz
ARG GOTENBERG_VERSION=v8.39.0
ARG GOTENBERG_SHA256=11b3ec380dc0cd0e8c6782052bad92adeb7493e61c7852ace606e947efdee142
# renovate: datasource=github-releases depName=pdfcpu/pdfcpu
# sha256: https://github.com/pdfcpu/pdfcpu/archive/refs/tags/${VERSION}.tar.gz
ARG PDFCPU_VERSION=v0.16.3
ARG PDFCPU_SHA256=4864561bb99633c06f917eae780eccbc98b3ede259b4a774e699a893eff2a56e
# renovate: datasource=gitlab-tags depName=pdftk-java/pdftk
# sha256: https://gitlab.com/api/v4/projects/5024297/packages/generic/pdftk-java/${VERSION}/pdftk-all.jar
ARG PDFTK_VERSION=v3.3.3
ARG PDFTK_SHA256=a694d49bd03e1edd4c23b3ba808bc221eb8a8ccfe7bfd2a0a884b2b2fb425188
# renovate: datasource=github-tags depName=gotenberg/unoconverter
# sha256: https://raw.githubusercontent.com/gotenberg/unoconverter/${VERSION}/unoconv
ARG UNOCONVERTER_VERSION=v0.5.0
ARG UNOCONVERTER_SHA256=e9b41e9b64849a2b0c20913635a879c530757472a5111896bcb33edefdd12b0b

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
#
# The base installs openjdk-21-jre but leaves PATH as /usr/local/bin:/usr/bin:
# /bin, so the JVM's own bin directory is unreachable and the shim's bare
# `java` fails at runtime — while gotenberg still advertises pdftk as an
# active engine at boot. Link the JRE into /usr/bin so the shim resolves.
# Hard-fail if no JRE is present: a silently pdftk-less image is exactly
# the failure mode this is fixing.
RUN if ! command -v java >/dev/null 2>&1; then \
        javabin="$(ls -d /usr/lib/jvm/*/bin/java 2>/dev/null | head -1)"; \
        [ -n "$javabin" ] || { echo "ERROR: no JRE found in base image" >&2; exit 1; }; \
        ln -s "$javabin" /usr/bin/java; \
    fi && \
    printf '#!/bin/bash\n\nexec java -jar /usr/bin/pdftk-all.jar "$@"\n' > /usr/bin/pdftk && \
    chmod +x /usr/bin/pdftk && \
    ln -sf /usr/bin/python3.11 /usr/bin/python && \
    java -version && \
    pdftk --version >/dev/null

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
