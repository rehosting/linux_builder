FROM ubuntu:latest

RUN apt-get update && \
    apt-get -y  install --no-install-recommends\
      bc \
      build-essential \
      ca-certificates \
      gdb \
      git \
      golang-go \
      libncurses-dev \
      wget

# Get panda for kernelinfo_gdb. Definitely a bit overkill to pull the whole repo.
# Also get dwarf2json and build it
RUN git clone --depth 1 https://github.com/panda-re/panda.git && \
    git clone --depth 1 https://github.com/volatilityfoundation/dwarf2json.git && \
    cd dwarf2json && \
    go build 

#Latest mips and mipsel toolchains break on building old kernels so we use these with gcc 5.3.0
#mips64 toolchain built using https://github.com/richfelker/musl-cross-make
#BINUTILS_VER = 2.25.1
#GCC_VER = 6.5.0
#MUSL_VER = git-v1.1.24
#GMP_VER = 6.1.0
#MPC_VER = 1.0.3
#MPFR_VER = 3.1.4
#GCC_CONFIG += --enable-languages=c
#It's a bit nutty to symlink all of these, but easier to keep track of what's needed for the future

# Download all our cross compilers and set up symlinks
RUN mkdir -p /opt/cross && \
    wget https://musl.cc/i686-linux-musl-cross.tgz -O - | tar -xz -C /opt/cross && \
    ln -s /opt/cross/i686-linux-musl-cross /opt/cross/i686-linux-musl && \
    wget https://musl.cc/x86_64-linux-musl-cross.tgz -O - | tar -xz -C /opt/cross && \
    ln -s /opt/cross/x86_64-linux-musl-cross /opt/cross/x86_64-linux-musl && \
    wget http://panda.re/secret/mipseb-linux-musl_gcc-5.3.0.tar.gz -O - | tar -xz -C /opt/cross && \
    wget http://panda.re/secret/mipsel-linux-musl_gcc-5.3.0.tar.gz -O - | tar -xz -C /opt/cross && \
    wget https://musl.cc/mips64el-linux-musl-cross.tgz -O -  | tar -xz -C /opt/cross && \
    ln -s /opt/cross/mips64el-linux-musl-cross /opt/cross/mips64el-linux-musl  && \
    wget https://musl.cc/arm-linux-musleabi-cross.tgz -O - | tar -xz -C /opt/cross && \
    ln -s /opt/cross/arm-linux-musleabi-cross /opt/cross/arm-linux-musleabi && \
    wget https://musl.cc/aarch64-linux-musl-cross.tgz -O - | tar -xz -C /opt/cross && \
    ln -s /opt/cross/aarch64-linux-musl-cross /opt/cross/aarch64-linux-musl && \
    wget http://panda.re/secret/mips64-linux-musl-cross_gcc-6.5.0.tar.gz -O - | tar -xz -C /opt/cross && \
    ln -s /opt/cross/mips64-linux-musl-cross /opt/cross/mips64eb-linux-musl && \ 
    ln -s /opt/cross/mips64eb-linux-musl/bin/mips64-linux-musl-gcc /opt/cross/mips64eb-linux-musl/bin/mips64eb-linux-musl-gcc && \
    ln -s /opt/cross/mips64eb-linux-musl/bin/mips64-linux-musl-ld /opt/cross/mips64eb-linux-musl/bin/mips64eb-linux-musl-ld && \
    ln -s /opt/cross/mips64eb-linux-musl/bin/mips64-linux-musl-objdump /opt/cross/mips64eb-linux-musl/bin/mips64eb-linux-musl-objdump && \
    ln -s /opt/cross/mips64eb-linux-musl/bin/mips64-linux-musl-objcopy /opt/cross/mips64eb-linux-musl/bin/mips64eb-linux-musl-objcopy && \
    ln -s /opt/cross/mips64eb-linux-musl/bin/mips64-linux-musl-ar /opt/cross/mips64eb-linux-musl/bin/mips64eb-linux-musl-ar && \
    ln -s /opt/cross/mips64eb-linux-musl/bin/mips64-linux-musl-nm /opt/cross/mips64eb-linux-musl/bin/mips64eb-linux-musl-nm

COPY . /app