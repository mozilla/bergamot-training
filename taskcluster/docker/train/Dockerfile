FROM $DOCKER_IMAGE_PARENT
LABEL maintainer="Mozilla Release Engineering <release+docker@mozilla.com>"

RUN apt-get update -qq \
    && apt-get install -y python3-numpy \
                          python3-fasttext \
                          parallel \
                          zstd \
                          bc \
                          libhunspell-1.7-0 \
                          libboost-program-options1.74.0 \
                          libboost-filesystem1.74.0 \
                          libboost-iostreams1.74.0 \
                          pigz \
                          curl \
                          wget \
                          pkg-config \
                          libicu-dev \
                          software-properties-common \
    && apt-get clean

# Install the same cuda version that the worker host uses
# See https://github.com/mozilla-platform-ops/worker-images/blob/main/scripts/linux/ubuntu-2404-amd64-headless/fxci/05-nvidia-gcp-driver-cudnn.sh
RUN curl -sSO https://developer.download.nvidia.com/compute/cudnn/9.6.0/local_installers/cudnn-local-repo-ubuntu2204-9.6.0_1.0-1_amd64.deb \
    && dpkg -i cudnn-local-repo-ubuntu2204-9.6.0_1.0-1_amd64.deb \
    && cp /var/cudnn-local-repo-ubuntu2204-9.6.0/cudnn-*-keyring.gpg /usr/share/keyrings/ \
    && apt-get update -qq \
    && apt-get install -y cudnn

VOLUME /builds/worker/checkouts
VOLUME /builds/worker/.cache
