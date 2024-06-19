FROM golang:latest as go
RUN git clone --depth 1 https://github.com/volatilityfoundation/dwarf2json.git \
    && cd dwarf2json \
    && go build

FROM ghcr.io/panda-re/embedded-toolchains:latest
COPY --from=go /go/dwarf2json/dwarf2json /bin/dwarf2json
RUN apt-get update && apt-get -y install gdb xonsh flex bison libssl-dev

# Get panda for kernelinfo_gdb. Definitely a bit overkill to pull the whole repo
RUN git clone --depth 1 https://github.com/panda-re/panda.git

# Download and build GCC 4.6.2
RUN echo "deb http://dk.archive.ubuntu.com/ubuntu/ xenial main" >>  /etc/apt/sources.list
RUN echo "deb http://dk.archive.ubuntu.com/ubuntu/ xenial universe" >>  /etc/apt/sources.list
RUN apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 40976EAF437D05B5 3B4FE6ACC0B21F32
RUN apt-get update -y
RUN apt-get install -y gcc gcc-4.9 gcc-4.9-aarch64-linux-gnu gcc-4.9-arm-linux-gnueabi g++-4.9-arm-linux-gnueabi build-essential wget libncurses5-dev git vim && \
    update-alternatives --install /usr/bin/arm-linux-gnueabi-gcc arm-linux-gnueabi-gcc /usr/bin/arm-linux-gnueabi-gcc-4.9 60 && \
    update-alternatives --install /usr/bin/arm-linux-gnueabi-g++ arm-linux-gnueabi-g++ /usr/bin/arm-linux-gnueabi-g++-4.9 60 && \
    update-alternatives --install /usr/bin/aarch64-linux-gnu-gcc aarch64-linux-gnu-gcc /usr/bin/aarch64-linux-gnu-gcc-4.9 60