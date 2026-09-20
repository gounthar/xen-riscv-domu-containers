FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential flex bison bc libssl-dev libelf-dev gcc-riscv64-linux-gnu cpio kmod \
    python3 xz-utils ca-certificates curl gzip && rm -rf /var/lib/apt/lists/*
