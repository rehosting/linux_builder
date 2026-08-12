# The two analysis artifacts shipped alongside each kernel:
#
#   osi.<target>.config   -- PANDA osi_linux kernel profile (struct offsets),
#                            extracted by running gdb over the DEBUGGABLE vmlinux
#   cosi.<target>.json.xz -- volatility-style symbol table from the same vmlinux
#
# Both read the UNSTRIPPED build-tree vmlinux. That is why kernel.nix exposes a
# separate `vmlinux` output and does not strip in place: _in_container_build.sh
# gets away with it only by ordering (extract first, strip the shipped copy
# afterwards), which a derivation cannot reproduce once the kernel is realised.
#
# PROVENANCE NOTE -- both tools are fetched unpinned today.
#
#  * extract_kernelinfo: the Dockerfile wgets it from `refs/heads/main` of
#    panda-re/panda-ng at image-build time, from a repo the stack is actively
#    retiring (CLAUDE.md: panda-ng is on the way out, new work goes to qemu/).
#  * dwarf2json: embedded-toolchains' Dockerfile does `git clone --depth 1` of
#    the DEFAULT BRANCH of rehosting/dwarf2json -- a FORK, not upstream
#    volatilityfoundation. nixpkgs ships the upstream tool under that name; using
#    it would silently produce different ISFs, and penguin consumes them at
#    runtime (pyplugins/apis/kffi.py reads cosi.<arch>.json.xz). So build the
#    fork from a pinned rev.
#
# Every osi.config and cosi ISF shipped to date was produced by "whatever the
# default branch said that day". Both are pinned to commits here.
{ pkgs }:

let
  inherit (pkgs) lib;

  # rehosting/dwarf2json @ main. Sole dependency is spf13/pflag, so the vendor
  # tree is tiny -- but it must still be a fixed-output vendor derivation.
  dwarf2json = pkgs.buildGoModule {
    pname = "dwarf2json";
    version = "unstable-2026-rehosting-fork";
    src = pkgs.fetchFromGitHub {
      owner = "rehosting";
      repo = "dwarf2json";
      rev = "45f9343560b7ece6be23415695fe4d0c2678759d";
      hash = "sha256-cFIXDmVv58DBtj89Wb77ZjtK6vz5LTF/wKPpEd88t9M=";
    };
    vendorHash = "sha256-3PnXB8AfZtgmYEPJuh0fwvG38dtngoS/lxyx3H+rvFs=";
    meta.description = "rehosting fork of dwarf2json (produces the COSI ISFs penguin loads)";
  };

  # panda-re/panda-ng, plugins/osi_linux/utils/kernelinfo_gdb.
  # Last touched 2025-04-14 ("try pcpu_hot"); pinned rather than tracking main.
  kernelinfoRev = "1764d2efe73712944996647b582862522f36efc9";
  kernelinfoUrl = f:
    "https://raw.githubusercontent.com/panda-re/panda-ng/${kernelinfoRev}/plugins/osi_linux/utils/kernelinfo_gdb/${f}";

  extractKernelinfo = pkgs.runCommand "extract-kernelinfo-${lib.substring 0 8 kernelinfoRev}"
    {
      py = pkgs.fetchurl {
        url = kernelinfoUrl "extract_kernelinfo.py";
        hash = "sha256-CO9UYvk+WwZHo2zGVNYwHgy6TUR9D7Ysn/FYNH/yGfA=";
      };
      sh = pkgs.fetchurl {
        url = kernelinfoUrl "run.sh";
        hash = "sha256-Df4GI32UmioUc5/830XglQ8Er50Kj4md1y6uyOAt2ZU=";
      };
    } ''
    mkdir -p $out
    cp $py $out/extract_kernelinfo.py
    cp $sh $out/run.sh
    chmod +x $out/run.sh
    # run.sh is `#!/bin/bash`, which does not exist in the sandbox -- the same
    # class of breakage as 4.10's `/bin/pwd` in kernel.nix. Unpatched it fails
    # with the deeply unhelpful "cannot execute: required file not found".
    patchShebangs $out/run.sh
  '';

in
rec {
  inherit extractKernelinfo dwarf2json;

  # gdb reads a foreign-arch vmlinux fine: nixpkgs builds it --enable-targets=all,
  # so no per-arch gdb is needed (the Docker build relies on Ubuntu's multiarch
  # gdb for the same reason, just without saying so).
  osiConfig = { kernel, version, target }:
    pkgs.runCommand "igloo-osi-${version}-${target}"
      {
        nativeBuildInputs = [ pkgs.gdb pkgs.bash ];
        meta.description = "PANDA osi_linux profile for ${version}/${target}";
      } ''
      vmlinux=${kernel.vmlinux}/vmlinux.${target}
      test -f "$vmlinux" || { echo "no unstripped vmlinux at $vmlinux"; exit 1; }

      # Faithful to _in_container_build.sh: the [target] section header is
      # written FIRST, then the extractor's output is appended to it.
      echo "[${target}]" > $out
      ${extractKernelinfo}/run.sh "$vmlinux" profile.out
      test -s profile.out || { echo "extract_kernelinfo produced nothing"; exit 1; }
      cat profile.out >> $out
    '';

  cosiJson = { kernel, version, target }:
    pkgs.runCommand "igloo-cosi-${version}-${target}"
      {
        # NOT pkgs.dwarf2json -- that is upstream volatility's, not our fork.
        nativeBuildInputs = [ dwarf2json pkgs.xz ];
        meta.description = "COSI symbol table for ${version}/${target}";
      } ''
      vmlinux=${kernel.vmlinux}/vmlinux.${target}
      test -f "$vmlinux" || { echo "no unstripped vmlinux at $vmlinux"; exit 1; }
      dwarf2json linux --elf "$vmlinux" | xz -c > $out
    '';
}
