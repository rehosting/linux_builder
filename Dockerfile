ARG REGISTRY="docker.io"
ARG TARGET="latest"
FROM ${REGISTRY}/golang:latest AS go
RUN git clone --depth 1 https://github.com/volatilityfoundation/dwarf2json.git \
    && cd dwarf2json \
    && go build

FROM ${REGISTRY}/rehosting/embedded-toolchains:${TARGET}

# Get panda for kernelinfo_gdb. Definitely a bit overkill to pull the whole repo
RUN mkdir /extract_kernelinfo && \
    wget https://raw.githubusercontent.com/panda-re/panda-ng/refs/heads/main/plugins/osi_linux/utils/kernelinfo_gdb/extract_kernelinfo.py -O /extract_kernelinfo/extract_kernelinfo.py && \
    wget https://raw.githubusercontent.com/panda-re/panda-ng/refs/heads/main/plugins/osi_linux/utils/kernelinfo_gdb/run.sh -O /extract_kernelinfo/run.sh && \
    chmod +x /extract_kernelinfo/run.sh
COPY --from=go /go/dwarf2json/dwarf2json /bin/dwarf2json