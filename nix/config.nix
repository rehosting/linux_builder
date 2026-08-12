# .config assembly -- deliberately identical to what _in_container_build.sh does:
#
#   cpp -P -undef configs/<version>/<target>  ->  .config
#   make olddefconfig
#
# configs/ is UNCHANGED by the nix migration. The `#include "arm-common.inc"`
# fragments resolve relative to the including file, so pointing cpp at the
# config inside the copied configs tree is all that's needed.
#
# This is why the linuxManualConfig-vs-nixpkgs-config-machinery design fork
# never arises: we keep our own assembly, and nix only has to run it.
{ pkgs }:

{
  # Just the cpp step. The `olddefconfig` half needs the kernel tree + toolchain,
  # so it happens inside the kernel derivation (see kernel.nix).
  rawConfig =
    { configsSrc, version, target }:
    pkgs.runCommand "igloo-config-${version}-${target}"
      {
        nativeBuildInputs = [ pkgs.stdenv.cc ];
      }
      ''
        if [ ! -f ${configsSrc}/${version}/${target} ]; then
          echo "no config for ${target} at version ${version}" >&2
          exit 1
        fi
        cpp -P -undef ${configsSrc}/${version}/${target} -o $out
      '';
}
