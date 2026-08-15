# The build matrix: kernel version -> targets.
#
# Targets are the linux_builder TARGET names (which are also kernelsmith's arch
# keys, deliberately -- they were already aligned). Sourced from configs/<v>/,
# excluding *.inc (fragments) and *.unused (retired targets).
#
# NOTE 4.10 is 7 targets, not 12: every powerpc* config is .unused, and
# loongarch64/riscv64 don't exist for that version. The full matrix is 19 cells,
# not the 24 a naive 2x12 suggests.
#
# powerpcle is retired on BOTH versions. CPU_LITTLE_ENDIAN depends on
# PPC_BOOK3S_64, so a 32-bit little-endian powerpc kernel is not expressible in
# mainline Linux; the config's request was silently dropped and the cell built a
# byte-identical copy of `powerpc`. See configs/6.13/powerpcle.unused.
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
    "powerpc64"
    "powerpc64le"
    "loongarch64"
    "riscv64"
    "x86_64"
  ];
}
