# Multi-stage build for sinhron-server.
#
# Stage 1: Rust builder. Uses the official rust:1.94-bookworm image so
# the toolchain matches what `cargo` developers run locally. Compiles
# `--release` with the workspace's `lto = "thin"` + `strip = "debuginfo"`
# profile (see Cargo.toml `[profile.release]`).
#
# Stage 2: Debian-slim runtime. We need libssl3 for tokio-tungstenite +
# sqlx-postgres (both use rustls in our build, so libssl is NOT strictly
# required — but Debian's base image already ships it, and adding it
# explicitly future-proofs swap-ins like native-tls clients in WU B+
# without rebuilding the base.
#
# Final image: ~80 MB. Operator deploys as `sinhron/server:0.1.0`.

# ─── Stage 1: build ───────────────────────────────────────────────────
FROM rust:1.94-bookworm AS builder

# Build deps:
#   • protobuf-compiler — prost-build needs `protoc` to compile
#     proto/sinhron.proto at cargo-build time.
#   • libpq-dev — sqlx-postgres links against libpq when running queries
#     (runtime only, not build). Included for parity with future native-tls
#     swap-ins.
RUN apt-get update && apt-get install -y --no-install-recommends \
    protobuf-compiler \
    libpq-dev \
    pkg-config \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Cache the dependency graph by copying Cargo.{toml,lock} first and
# building a dummy main.rs. Subsequent `cargo build` calls (after copying
# real sources) only recompile our crate, not the 300+ transitive deps.
COPY Cargo.toml Cargo.lock build.rs ./
RUN mkdir -p src && \
    echo 'fn main() {}' > src/main.rs && \
    echo 'pub fn run() {}' > src/lib.rs && \
    cargo build --release --bin sinhron-server || true

# Copy the actual sources + proto + migrations + examples.
COPY src ./src
COPY proto ./proto
COPY migrations ./migrations

# Touch so cargo notices changes after the dummy build.
RUN touch src/main.rs src/lib.rs

RUN cargo build --release --bin sinhron-server

# ─── Stage 2: runtime ────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Run as a non-root user. UID 10001 matches the docker-compose service
# user; the postgres data volume is mounted by the postgres container
# (different uid namespace) so no chown handshake needed here.
RUN useradd --system --uid 10001 --user-group --no-create-home sinhron
# Encrypted media blobs (ADR-017). Created here so an empty named volume
# mounted at this path inherits sinhron ownership on first start.
RUN mkdir -p /var/lib/sinhron/media && chown -R sinhron:sinhron /var/lib/sinhron
USER sinhron

WORKDIR /app
COPY --from=builder /build/target/release/sinhron-server /app/sinhron-server

EXPOSE 8080
ENV RUST_LOG=info \
    SINHRON_LISTEN=0.0.0.0:8080

# `exec`-form so SIGTERM from `docker stop` reaches the binary directly
# (not bash, which would absorb it and force a 10s grace-period kill).
ENTRYPOINT ["/app/sinhron-server"]
