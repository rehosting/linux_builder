# Assert that what a cell actually produced matches what its target name claims.
#
# Two bugs on this branch were invisible to every other check because the build
# succeeded and the artifact existed:
#
#   - perf inherited kernel.nix's powerpc family collapse and emitted four
#     BYTE-IDENTICAL big-endian 64-bit binaries for powerpc, powerpcle,
#     powerpc64 and powerpc64le. Three cannot run on their guest.
#
#   - configs/6.13/powerpcle asks for CONFIG_CPU_LITTLE_ENDIAN=y, which
#     arch/powerpc/platforms/Kconfig.cputype makes conditional on PPC_BOOK3S_64.
#     olddefconfig drops it without complaint and the kernel comes out
#     big-endian, byte-identical to powerpc's.
#
# Both are the same shape of failure: an ELF whose class or endianness silently
# disagrees with its name. The kernel build cannot catch it (Kconfig resolved
# "correctly" by its own rules) and neither can a smoke test that only checks a
# file exists. Reading the ELF header does catch it, costs nothing, and is the
# check that would have found both.
#
# Deliberately NOT derived from the toolchain or the config -- those are the
# things being checked. The expectation comes from the target name, which is
# what every consumer downstream believes.
{ pkgs }:

let
  inherit (pkgs) lib;

  # target -> (ELF class, byte order), as the NAME promises.
  expect = {
    armel = { bits = 32; endian = "LSB"; };
    arm64 = { bits = 64; endian = "LSB"; };
    mipsel = { bits = 32; endian = "LSB"; };
    mipseb = { bits = 32; endian = "MSB"; };
    mips64el = { bits = 64; endian = "LSB"; };
    mips64eb = { bits = 64; endian = "MSB"; };
    powerpc = { bits = 32; endian = "MSB"; };
    powerpc64 = { bits = 64; endian = "MSB"; };
    powerpc64le = { bits = 64; endian = "LSB"; };
    loongarch64 = { bits = 64; endian = "LSB"; };
    riscv64 = { bits = 64; endian = "LSB"; };
    x86_64 = { bits = 64; endian = "LSB"; };

    # No powerpcle entry, and none is needed: the target is retired (see
    # configs/6.13/powerpcle.unused) precisely because no honest expectation
    # could be written for it. If it ever comes back without real upstream
    # ppc32-LE support, it lands in the SKIP branch below rather than passing
    # quietly -- which is the point.
  };

in
{ cells }:

pkgs.runCommand "igloo-shape-check"
{
  nativeBuildInputs = [ pkgs.file ];
} ''
  fail=0
  report() { printf '%-24s %-9s %s\n' "$1" "$2" "$3"; }

  ${lib.concatMapStringsSep "\n"
    (c:
      let e = expect.${c.target} or null; in
      if e == null then ''
        report "${c.version}/${c.target}" "SKIP" "no honest expectation for this target name"
      '' else ''
        # The kernel comes from the `vmlinux` output, not `out`. Only some
        # targets deliver a vmlinux in $out (the rest ship zImage/bzImage/Image,
        # which are compressed blobs `file` cannot read a class or byte order
        # from), so checking $out would silently skip armel, arm64, loongarch64,
        # riscv64 and x86_64 -- five of thirteen, and exactly the kind of
        # partial coverage this check exists to prevent.
        for f in ${c.kernel.vmlinux}/vmlinux.${c.target} ${c.perf}/perf.${c.target}; do
          [ -f "$f" ] || { report "${c.version}/${c.target}" "MISSING" "$f"; fail=1; continue; }
          desc=$(file -b "$f")
          case "$desc" in
            *"${toString e.bits}-bit ${e.endian}"*) report "${c.version}/${c.target}" "ok" "$(basename $f)" ;;
            *)
              report "${c.version}/${c.target}" "MISMATCH" "$(basename $f): want ${toString e.bits}-bit ${e.endian}, got: $desc"
              fail=1 ;;
          esac
        done
      '')
    cells}

  if [ $fail -ne 0 ]; then
    echo "shape check FAILED: an artifact's ELF class/endianness disagrees with its target name" >&2
    exit 1
  fi
  echo "shape check passed" > $out
''
