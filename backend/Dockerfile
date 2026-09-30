# The Haskell API and seed command, built into a small image.
#
# Build from the repository root, because cabal.project lives there:
#   docker build -f backend/Dockerfile .
# (docker compose does this for you.)
#
# Two stages: "build" has the compiler and everything needed to compile;
# the final image gets only the two finished programs and the libraries
# they load at runtime. The compiler never ships.

# --- Build stage ------------------------------------------------------------
FROM debian:bookworm-slim AS build

# C tools and libraries GHC needs, plus libpq (the Postgres client library,
# for postgresql-simple).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git libffi-dev libgmp-dev \
      libncurses-dev libpq-dev pkg-config xz-utils zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# GHC 9.4.8 and cabal via ghcup, the same tool used for local development.
# The official haskell:9.4.8 images are based on Debian 10, which is past
# end of life (its package servers are gone), so we install GHC ourselves
# on a current Debian.
ENV GHCUP_INSTALL_BASE_PREFIX=/opt \
    PATH=/opt/.ghcup/bin:$PATH
RUN curl -sSfL "https://downloads.haskell.org/~ghcup/$(uname -m)-linux-ghcup" -o /usr/local/bin/ghcup \
 && chmod +x /usr/local/bin/ghcup \
 && ghcup install ghc 9.4.8 --set \
 && ghcup install cabal 3.12.1.0 --set \
 && ghcup gc --profiling-libs --share-dir --tmpdirs

WORKDIR /src

# Dependencies first, in their own layer: this slow step only re-runs when
# the cabal file changes, not on every code change. The migrations come
# along because the cabal file lists them.
# cabal.project.freeze pins every dependency to the exact version used in
# development and CI, so the image builds the same code.
COPY cabal.project cabal.project.freeze ./
COPY backend/double-entry-ledger.cabal backend/
COPY backend/db/migrations backend/db/migrations
RUN cabal update \
 && cabal build --only-dependencies all

# Now our own code.
COPY backend/ backend/
RUN cabal build exe:ledger-api exe:ledger-seed \
 && mkdir -p /out \
 && cp "$(cabal list-bin ledger-api)" "$(cabal list-bin ledger-seed)" /out/

# --- Runtime stage ----------------------------------------------------------
FROM debian:bookworm-slim

# Only the shared libraries the programs load: GMP (GHC's big integers),
# libpq (Postgres), and CA certificates for TLS connections to Postgres.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libgmp10 libpq5 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/ledger-api /out/ledger-seed /usr/local/bin/

# Don't run as root inside the container.
RUN useradd --system --no-create-home ledger
USER ledger

ENV PORT=8080
EXPOSE 8080
CMD ["ledger-api"]
