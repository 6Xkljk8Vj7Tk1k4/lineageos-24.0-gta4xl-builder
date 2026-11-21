# Build environment for LineageOS 24.0 (Android 17) for the Samsung Galaxy Tab S6 Lite LTE (gta4xl).
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# The package list of the LineageOS build guide (the one for Ubuntu 23.10 and newer), plus what
# `--no-install-recommends` leaves out and the build or build.sh uses: ca-certificates, patch,
# xz/zstd/cpio, the process tools on Soong's PATH list, openssl (decrypting the signing keys
# archive) and jq (update server metadata, tools/generate-ota-json.sh).
# No JDK: the Android toolchains (clang, rust, JDK, python, make, ninja, the kernel build tools)
# are prebuilts in the source tree and need only glibc from this image.
# `dist-upgrade` brings in the fixes released after the base image was built; rebuild the image
# once a month with `podman build --pull --no-cache`.
RUN apt-get update && apt-get -y dist-upgrade && apt-get install -y --no-install-recommends \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib git \
    git-lfs gnupg gperf imagemagick protobuf-compiler python3-protobuf \
    lib32readline-dev lib32z1-dev libdw-dev libelf-dev libgnutls28-dev lz4 \
    libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush rsync \
    schedtool squashfs-tools xsltproc xxd zip zlib1g-dev \
    python3 python-is-python3 wget unzip brotli p7zip-full e2fsprogs \
    ca-certificates openssl patch xz-utils zstd cpio file less \
    psmisc lsof procps bsdextrautils \
    jq \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# The build runs as "builder" with uid 1000 (the README gives that uid the source and cache
# folders). Ubuntu images since 23.10 ship a user "ubuntu" with that uid: it goes first.
RUN if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi && \
    useradd -m -u 1000 -s /bin/bash builder
USER builder
WORKDIR /home/builder/android/lineage

RUN mkdir -p /home/builder/bin && \
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > /home/builder/bin/repo && \
    chmod a+x /home/builder/bin/repo

ENV PATH="/home/builder/bin:${PATH}"
ENV USE_CCACHE=1
ENV CCACHE_EXEC=/usr/bin/ccache
ENV CCACHE_DIR=/home/builder/ccache

RUN git config --global user.email "builder@localhost" && \
    git config --global user.name "LineageOS builder" && \
    git config --global color.ui false && \
    # bind-mounted trees are owned by a different uid than "builder"
    git config --global --add safe.directory "*"

# The image is only the environment: build.sh, patches/, tools/ and vendor_blobs/ come from the
# checkout bind-mounted at /home/builder/repo, so `git pull` needs no image rebuild.
ENTRYPOINT ["/home/builder/repo/build.sh"]
