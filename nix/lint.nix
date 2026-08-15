# Config linting -- the nix replacement for `./build.sh --config-only`.
#
# What the Docker path did: cpp-assemble configs/<version>/<target>, run
# `savedefconfig` against the kernel tree, drop the result at
# config_<version>_<target>.linted, and print a diff. That diff was always
# non-empty and its exit status was discarded (`|| true`) -- savedefconfig
# prunes options that are already the default and de-duplicates, so a config
# and its savedefconfig form never match. It was an ADVISORY tool for the
# author of a config change, never a gate, and it is kept as one here.
#
# What it is good for: seeing which lines in a config fragment are redundant
# (already the arch default) or duplicated, before committing them.
#
# Deliberately NOT wired into `nix flake check`. Making it a gate would mean
# asserting that our configs equal their savedefconfig form, which is false for
# every config in this repo by construction, and "fixing" that would mean
# replacing readable fragments with savedefconfig output and losing the
# #include structure that makes configs/ maintainable.
{ pkgs }:

let
  inherit (pkgs) lib;
in
rec {
  # One cell's lint. Reuses the kernel's own tree and toolchain via passthru,
  # so the linted output comes from exactly the compiler and source that build
  # the shipped kernel -- savedefconfig's answer depends on both.
  forCell =
    { kernel, config, src, version, target }:
    pkgs.runCommand "igloo-config-lint-${version}-${target}"
      {
        nativeBuildInputs = with pkgs; [
          # stdenv.cc is the HOST compiler, and it is required: Kbuild builds
          # scripts/basic/fixdep and the Kconfig binaries natively before it
          # touches a single target file. `runCommand` is stdenvNoCC in current
          # nixpkgs, so without this the lint dies on "gcc: command not found"
          # long before reaching savedefconfig. The cross toolchain below is
          # prefixed (${kernel.passthru.crossPrefix}gcc), so the two never clash.
          stdenv.cc
          kernel.passthru.toolchain
          gnumake bc bison flex perl python3 rsync which openssl elfutils
        ];
        meta.description = "savedefconfig lint for ${version}/${target}";
      }
      ''
        export ARCH=${kernel.passthru.arch}
        export CROSS_COMPILE=${kernel.passthru.crossPrefix}
        cp -r ${src} linux && chmod -R u+w linux
        mkdir -p build out

        # Same two sandbox fixups the kernel build needs; see nix/kernel.nix.
        sed -i 's|/bin/pwd|pwd|g' linux/Makefile
        patchShebangs linux/scripts linux/tools 2>/dev/null || true

        cp ${config} build/.config
        make -C linux O=$PWD/build olddefconfig >/dev/null
        make -C linux O=$PWD/build savedefconfig >/dev/null

        mkdir -p $out
        cp build/defconfig $out/config_${version}_${target}.linted

        # Advisory, exactly as the Docker path had it: report, never fail.
        {
          echo "=== ${version}/${target}: assembled .config vs savedefconfig ==="
          echo "Lines only in the assembled config are redundant or defaulted."
          diff -u <(sort build/.config) \
                  <(sort build/defconfig | sed '/^[ #]/d') || true
        } > $out/config_${version}_${target}.diff
        cat $out/config_${version}_${target}.diff
      '';

  # Every cell's lint in one tree, so a config sweep is a single build.
  all = { cells }:
    pkgs.linkFarm "igloo-config-lint"
      (map
        (c: {
          name = "${c.version}-${c.target}";
          path = forCell {
            inherit (c) kernel config src version target;
          };
        })
        cells);
}
