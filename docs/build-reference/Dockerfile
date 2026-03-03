FROM debian:bookworm

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Add Debian source repos
RUN echo "deb-src https://deb.debian.org/debian bookworm main" \
    > /etc/apt/sources.list.d/debian-src.list

# Add Raspberry Pi OS archive with signed-by keyring
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl gpg ca-certificates && \
    curl -fsSL https://archive.raspberrypi.com/debian/raspberrypi.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/raspberrypi-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] https://archive.raspberrypi.com/debian/ bookworm main" \
        > /etc/apt/sources.list.d/raspi.list && \
    echo "deb-src [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] https://archive.raspberrypi.com/debian/ bookworm main" \
        >> /etc/apt/sources.list.d/raspi.list && \
    apt-get update

# Install libcec build dependencies and RPi firmware headers
RUN apt-get build-dep -y libcec && \
    apt-get install -y --no-install-recommends libraspberrypi-dev dpkg-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy patch file
COPY patches/enable-rpi-cec.patch /build/patches/

# Copy build script
COPY build.sh /build/

WORKDIR /build

RUN chmod +x /build/build.sh

CMD ["/build/build.sh"]
