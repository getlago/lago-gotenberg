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
# The base pin carries chromium 158.0.8127.88 from Lago's melange overlay,
# replacing Wolfi's 149 — which had no fix available and failed the base's
# CVE gate daily. See getlago/lago-packages packages/chromium.yaml.
#
# The two ARGs pin different lago-packages commits on purpose. lago-packages
# publishes a base only when its digest moves, so each image's newest tag is
# the commit that last changed it.

ARG BUILD_IMAGE=ghcr.io/getlago/gotenberg-build:20261128-r2600@sha256:8984cff155451072ed4048516df313215b0ac30c299f1f33869a6e39d910cfc2
ARG RUNTIME_IMAGE=ghcr.io/getlago/gotenberg-base:20261128-r2599@sha256:f5b52b7145fd431a07ae7eba9a7481e265ad657ce0e4de500da3f80cc58ac15e

# Pinned upstream downloads. Renovate moves each *_VERSION (getlago/lago-packages
# renovate/pinned-downloads), and the PR workflow recomputes the matching
# *_SHA256 from the `# sha256:` URL. Each fetch below is verified against
# its sha256 in the same RUN as the curl ("no unverified downloads",
# getlago/lago-packages/CLAUDE.md).
# renovate: datasource=github-releases depName=gotenberg/gotenberg
# sha256: https://github.com/gotenberg/gotenberg/archive/refs/tags/${VERSION}.tar.gz
ARG GOTENBERG_VERSION=v9.10.1
ARG GOTENBERG_SHA256=df2c02eb855abf5bd02db4c04b6c542cdbc8e2c6dcc245182dd5248c745e0f3f
# lok: gotenberg 9 converts office documents through LibreOfficeKit with this
# binary, in place of unoconverter. Upstream publishes checksums.txt with each
# release; bump the version and both per-arch sha256 together, from it.
ARG LOK_VERSION=v0.0.8
ARG LOK_SHA256_AMD64=a2ef770fd36f06dc5f6a329b3722019db18adae82466d4fcb5b5fc470dd8d5a2
ARG LOK_SHA256_ARM64=87c99f6c9fd54d9340cda3de49a7dbfe89746a266d8b195e3dfdf12b2df20539

# ---------------------------------------------------------------------------
# Build stage — go binaries + downloads. One stage instead of upstream's
# four; the lago-packages/gotenberg-build image ships go, git, curl and
# build-base, so there's no reason to split further.
# ---------------------------------------------------------------------------
FROM ${BUILD_IMAGE} AS build

ARG GOTENBERG_VERSION
ARG GOTENBERG_SHA256
ARG LOK_VERSION
ARG LOK_SHA256_AMD64
ARG LOK_SHA256_ARM64
ARG TARGETARCH

WORKDIR /src

# gotenberg + gotenberg-chromium + gotenberg-libreoffice — three
# entrypoints from the same source tree. The chromium module also
# requires `build/chromium-hyphen-data/` at runtime (per-language
# hyphenation dictionaries); we copy it to /out/chromium-hyphen-data
# here and stage it under CHROMIUM_HYPHEN_DATA_DIR_PATH in the
# runtime image below. The `sha256sum -c -` after curl aborts the RUN if
# upstream ever reshuffles the tarball for a released tag.
RUN mkdir gotenberg && cd gotenberg && \
    curl -fsSL "https://github.com/gotenberg/gotenberg/archive/refs/tags/${GOTENBERG_VERSION}.tar.gz" -o gotenberg.tar.gz && \
    echo "${GOTENBERG_SHA256}  gotenberg.tar.gz" | sha256sum -c - && \
    tar --strip-components=1 -xzf gotenberg.tar.gz && \
    go mod download && go mod verify && \
    go build -o /out/gotenberg -ldflags "-s -w -X 'github.com/gotenberg/gotenberg/v9/cmd.Version=${GOTENBERG_VERSION}'" cmd/gotenberg/main.go && \
    go build -o /out/gotenberg-chromium -ldflags "-s -w -X 'github.com/gotenberg/gotenberg/v9/cmd.Version=${GOTENBERG_VERSION}'" cmd/gotenberg-chromium/main.go && \
    go build -o /out/gotenberg-libreoffice -ldflags "-s -w -X 'github.com/gotenberg/gotenberg/v9/cmd.Version=${GOTENBERG_VERSION}'" cmd/gotenberg-libreoffice/main.go && \
    cp -r build/chromium-hyphen-data /out/chromium-hyphen-data

# lok — prebuilt per arch. Upstream installs it with `curl install.sh | sh`;
# here the archive is checked against its pinned sha256 before extraction.
RUN case "${TARGETARCH}" in \
      amd64) sha256="${LOK_SHA256_AMD64}" ;; \
      arm64) sha256="${LOK_SHA256_ARM64}" ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    archive="lok_${LOK_VERSION#v}_linux_${TARGETARCH}.tar.gz" && \
    curl -fsSL -o "${archive}" "https://github.com/gotenberg/lok/releases/download/${LOK_VERSION}/${archive}" && \
    echo "${sha256}  ${archive}" | sha256sum -c - && \
    tar -xzf "${archive}" lok && \
    install -m 0755 lok /out/lok

# ---------------------------------------------------------------------------
# Runtime stage — hardened Wolfi. Every runtime dependency (chromium,
# libreoffice-25.8, dumb-init, Noto/Liberation fonts) is baked into
# lago-packages/gotenberg-base, so this stage only drops in the binaries
# and the custom fonts. Gotenberg 9 handles PDFs in-process: the base's
# JRE, qpdf, exiftool and python are no longer used.
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

# gotenberg 9 refuses to boot without lok, even with the LibreOffice routes
# disabled. The base does not export it yet.
ENV LOK_BIN_PATH=/usr/bin/lok

# The base image ships with USER 65532 as the default. Switch to root so
# the RUN commands below can write to /usr/bin and /usr/local/share/fonts.
# The final USER 65532 line at the bottom is what actually ships.
USER root

COPY --from=build /out/gotenberg            /usr/bin/gotenberg
COPY --from=build /out/gotenberg-chromium   /usr/bin/gotenberg-chromium
COPY --from=build /out/gotenberg-libreoffice /usr/bin/gotenberg-libreoffice
COPY --from=build /out/lok                  /usr/bin/lok

# Chromium hyphenation dictionaries. gotenberg's chromium module needs
# both the env var set above and this directory present on disk; it
# refuses to start if either is missing.
COPY --from=build --chown=65532:65532 /out/chromium-hyphen-data /opt/gotenberg/chromium-hyphen-data

# Custom lago fonts — the only content-carrying change vs upstream
# gotenberg. Preserved from the previous wrapper Dockerfile.
COPY ./fonts/ /usr/local/share/fonts/

USER 65532
WORKDIR /home/nonroot

# Gotenberg's default HTTP port. Matches the upstream Dockerfile so
# nothing on the k8s Service side needs to change.
EXPOSE 3000

# gotenberg-base's entrypoint is `dumb-init --`, so the container ends
# up running `dumb-init -- gotenberg` — zombie chromium/lok
# subprocesses get reaped.
CMD ["gotenberg"]
