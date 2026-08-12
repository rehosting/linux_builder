# The build matrix: kernel version -> targets.
#
# Targets are the linux_builder TARGET names (which are also kernelsmith's arch
# keys, deliberately -- they were already aligned). Sourced from configs/<v>/,
# excluding *.inc (fragments) and *.unused (retired targets).
#
# NOTE 4.10 is 7 targets, not 13: every powerpc* config is .unused, and
# loongarch64/riscv64 don't exist for that version. The full matrix is 20 cells,
# not the 26 a naive 2x13 suggests.
{
  "4.10" = [
    "armel"
    "arm64"
    "mipseb"
    "mipsel"
    "mips64eb"
    "mips64el"
    "x86_64"
  ];

  "6.13" = [
    "armel"
    "arm64"
    "mipseb"
    "mipsel"
    "mips64eb"
    "mips64el"
    "powerpc"
    "powerpcle"
    "powerpc64"
    "powerpc64le"
    "loongarch64"
    "riscv64"
    "x86_64"
  ];
}
