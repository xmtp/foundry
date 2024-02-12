FROM debian:stable-slim as go-builder
# defined from build kit
# DOCKER_BUILDKIT=1 docker build . -t ...
ARG TARGETARCH

RUN export DEBIAN_FRONTEND=noninteractive && \
    apt update && \
    apt install -y -q --no-install-recommends \
    git curl gnupg2 build-essential coreutils \
    openssl libssl-dev pkg-config \
    ca-certificates apt-transport-https \
    python3 && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

## Go Lang
ARG GO_VERSION=1.22.0
ADD https://go.dev/dl/go${GO_VERSION}.linux-$TARGETARCH.tar.gz /goinstall/go${GO_VERSION}.linux-$TARGETARCH.tar.gz
RUN echo 'SHA256 of this go source package...'
RUN cat /goinstall/go${GO_VERSION}.linux-$TARGETARCH.tar.gz | sha256sum 
RUN tar -C /usr/local -xzf /goinstall/go${GO_VERSION}.linux-$TARGETARCH.tar.gz
ENV PATH=$PATH:/usr/local/go/bin
RUN go version

## Go Ethereum
WORKDIR /go-ethereum
ARG ETH_VERSION=1.13.12
ADD https://github.com/ethereum/go-ethereum/archive/refs/tags/v${ETH_VERSION}.tar.gz /go-ethereum/go-ethereum-${ETH_VERSION}.tar.gz
RUN echo 'SHA256 of this go-ethereum package...'
RUN cat /go-ethereum/go-ethereum-${ETH_VERSION}.tar.gz | sha256sum 
RUN tar -zxf go-ethereum-${ETH_VERSION}.tar.gz  -C /go-ethereum
WORKDIR /go-ethereum/go-ethereum-${ETH_VERSION}
RUN go mod download 
RUN go run build/ci.go install

FROM debian:stable-slim as foundry-builder
# defined from build kit
# DOCKER_BUILDKIT=1 docker build . -t ...
ARG TARGETARCH
ARG MAXIMUM_THREADS=2
ARG CARGO_INCREMENTAL=0

RUN export DEBIAN_FRONTEND=noninteractive && \
    apt update && \
    apt install -y -q --no-install-recommends \
    git curl gnupg2 build-essential \
    linux-headers-${TARGETARCH} libc6-dev \ 
    openssl libssl-dev pkg-config \
    ca-certificates apt-transport-https \
    python3 && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

RUN useradd --create-home -s /bin/bash xmtp
RUN usermod -a -G sudo xmtp
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

WORKDIR /rustup
## Rust
ADD https://sh.rustup.rs /rustup/rustup.sh
RUN chmod 755 /rustup/rustup.sh

ENV USER=xmtp
USER xmtp
RUN /rustup/rustup.sh -y --default-toolchain stable --profile minimal

## Foundry
WORKDIR /build

# latest https://github.com/foundry-rs/foundry
ENV PATH=$PATH:~xmtp/.cargo/bin

WORKDIR /build/foundry
ENV CARGO_INCREMENTAL=${CARGO_INCREMENTAL:-1}
ENV FOUNDRY_ROOT=/usr/local/foundry
ENV FOUNDRY_BIN=${FOUNDRY_ROOT}/bin
RUN . $HOME/.cargo/env && \
    THREAD_NUMBER=$(cat /proc/cpuinfo | grep -c ^processor) && \
    MAX_THREADS=$(( THREAD_NUMBER > ${MAXIMUM_THREADS} ?  ${MAXIMUM_THREADS} : THREAD_NUMBER )) && \
    echo "building with ${MAX_THREADS} threads" && \
    cargo install --git https://github.com/foundry-rs/foundry --tag nightly \
    --jobs ${MAX_THREADS} --root ${FOUNDRY_ROOT} --profile local \
    --locked forge cast chisel anvil && \
    objdump -j .comment -s ${FOUNDRY_BIN}/forge && \
    strip ${FOUNDRY_BIN}forge && \
    strip ${FOUNDRY_BIN}/cast && \
    strip ${FOUNDRY_BIN}/anvil && \
    strip ${FOUNDRY_BIN}/chisel

FROM debian:stable-slim as node18-slim

RUN export DEBIAN_FRONTEND=noninteractive && \
    apt update && \
    apt install -y -q --no-install-recommends \
    build-essential git gnupg2 curl \
    ca-certificates apt-transport-https && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/local/nvm
ENV NVM_DIR=/usr/local/nvm

ENV NODE_VERSION=v20.11.0

ADD https://raw.githubusercontent.com/creationix/nvm/master/install.sh /usr/local/etc/nvm/install.sh
RUN bash /usr/local/etc/nvm/install.sh && \
    bash -c ". $NVM_DIR/nvm.sh && nvm install $NODE_VERSION && nvm alias default $NODE_VERSION && nvm use default"

ENV NVM_NODE_PATH ${NVM_DIR}/versions/node/${NODE_VERSION}
ENV NODE_PATH ${NVM_NODE_PATH}/lib/node_modules
ENV PATH      ${NVM_NODE_PATH}/bin:$PATH

RUN npm install npm -g
RUN npm install yarn -g

FROM node18-slim
ARG TARGETARCH

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt update && \
  apt install -y -q --no-install-recommends \
    libz3-dev z3 build-essential \
    ca-certificates apt-transport-https \
    sudo ripgrep procps \
    python3 python3-pip python3-dev && \
  apt clean && \
  rm -rf /var/lib/apt/lists/*

RUN echo "building platform $(uname -m)"

RUN useradd --create-home -s /bin/bash xmtp
RUN usermod -a -G sudo xmtp
RUN echo '%xmtp ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# SOLC
COPY --from=ghcr.io/jac18281828/solc:latest /usr/local/bin/solc /usr/local/bin
COPY --from=ghcr.io/jac18281828/solc:latest /usr/local/bin/yul-phaser /usr/local/bin
RUN solc --version

## Rust 
COPY --chown=xmtp:xmtp --from=foundry-builder /home/xmtp/.cargo /home/xmtp/.cargo

# GO LANG
COPY --from=go-builder /usr/local/go /usr/local/go

## GO Ethereum Binaries
ARG ETH_VERSION=1.13.12
COPY --from=go-builder /go-ethereum/go-ethereum-${ETH_VERSION}/build/bin /usr/local/bin

ENV FOUNDRY_ROOT=/usr/local/foundry
# Foundry
COPY --from=foundry-builder ${FOUNDRY_ROOT} ${FOUNDRY_ROOT}

ENV PATH=${FOUNDRY_ROOT}/bin:${PATH}

LABEL org.label-schema.build-date=$BUILD_DATE \
    org.label-schema.name="foundry" \
    org.label-schema.description="Foundry RS Development Container" \
    org.label-schema.url="https://github.com/xmtp/foundry" \
    org.label-schema.vcs-ref=$VCS_REF \
    org.label-schema.vcs-url="git@github.com:xmtp/foundry.git" \
    org.label-schema.vendor="XMTP Labs" \
    org.label-schema.version=$VERSION \
    org.label-schema.schema-version="1.0" \
    org.opencontainers.image.description="Foundry and Ethereum Development Container for Visual Studio Code"
