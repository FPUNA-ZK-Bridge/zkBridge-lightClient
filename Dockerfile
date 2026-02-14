FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    git \
    libgmp-dev \
    libsodium-dev \
    m4 \
    nasm \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

ENV NODE_VERSION=16
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g snarkjs

ARG CIRCOM_VERSION=2.0.8
RUN curl -fsSL "https://github.com/iden3/circom/releases/download/v${CIRCOM_VERSION}/circom-linux-amd64" -o /usr/local/bin/circom \
    && chmod +x /usr/local/bin/circom

RUN useradd -m -s /bin/bash -u 1001 app \
    && mkdir -p /workspace \
    && chown -R app:app /workspace

ENV PATH="/usr/local/bin:${PATH}"
ENV NODE_MEM=16384
WORKDIR /workspace
USER app

CMD ["/bin/sh"]
