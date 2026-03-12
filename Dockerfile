ARG REGISTRY="docker.io"
ARG TARGET="latest"
FROM ${REGISTRY}/rehosting/embedded-toolchains:${TARGET}

RUN apt-get update && apt-get install -y pkg-config

# Get panda for kernelinfo_gdb. Definitely a bit overkill to pull the whole repo
RUN mkdir /extract_kernelinfo && \
    wget https://raw.githubusercontent.com/panda-re/panda-ng/refs/heads/main/plugins/osi_linux/utils/kernelinfo_gdb/extract_kernelinfo.py -O /extract_kernelinfo/extract_kernelinfo.py && \
    wget https://raw.githubusercontent.com/panda-re/panda-ng/refs/heads/main/plugins/osi_linux/utils/kernelinfo_gdb/run.sh -O /extract_kernelinfo/run.sh && \
    chmod +x /extract_kernelinfo/run.sh

