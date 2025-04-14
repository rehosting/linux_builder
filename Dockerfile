FROM golang:latest AS go
RUN git clone --depth 1 https://github.com/volatilityfoundation/dwarf2json.git \
    && cd dwarf2json \
    && go build

FROM ghcr.io/rehosting/embedded-toolchains:latest
COPY --from=go /go/dwarf2json/dwarf2json /bin/dwarf2json
RUN apt-get update && apt-get -y install gdb xonsh flex bison libssl-dev libelf-dev pigz
RUN apt-get -y install bsdmainutils zstd cpio gcc-riscv64-linux-gnu

# Get panda for kernelinfo_gdb. Definitely a bit overkill to pull the whole repo
RUN mkdir /extract_kernelinfo && \
    wget https://raw.githubusercontent.com/panda-re/panda-ng/refs/heads/main/plugins/osi_linux/utils/kernelinfo_gdb/extract_kernelinfo.py -O /extract_kernelinfo/extract_kernelinfo.py && \
    wget https://raw.githubusercontent.com/panda-re/panda-ng/refs/heads/main/plugins/osi_linux/utils/kernelinfo_gdb/run.sh -O /extract_kernelinfo/run.sh && \
    chmod +x /extract_kernelinfo/run.sh