# One IGLOO kernel cell: (version, target) -> vmlinux + boot image + kernel-devel.
#
# This is a faithful port of _in_container_build.sh's per-target build, with the
# toolchain resolved by kernelsmith instead of an unpinned musl.cc download.
#
# Three outputs:
#   out     -- the arch's boot artifact, Module.symvers, and (mips*/powerpc*
#              only, matching build.sh) a STRIPPED vmlinux
#   dev     -- the kernel-devel tree out-of-tree modules build against
#   vmlinux -- the UNSTRIPPED vmlinux, for osi/cosi extraction
#
# The vmlinux split is not tidiness. _in_container_build.sh runs the osi/cosi
# extractors against the build-tree vmlinux and only THEN strips the copy it
# ships -- an ordering a derivation cannot reproduce, because by the time
# anything downstream sees the kernel it is already realised. Stripping in place
# would leave the analysis derivations reading a vmlinux with no debug info, on
# exactly the mips*/powerpc* targets that ship one.
#
# Named `vmlinux` and not `debug`: `debug` is a name nixpkgs' multiple-outputs
# machinery attaches meaning to, and this file already lost a day to `dev` vs
# `devel` (see below).
#
# The dev output MUST be called "dev": nixpkgs' multiple-outputs setup hook
# relocates include/ to `outputDev`, which falls back to "out" when no output is
# literally named "dev". Naming it "devel" therefore silently moved include/
# into $out and produced a devel tree that could not build a module.
#
# The `dev` output is the point of the whole exercise: igloo_driver consumes
# it as a DERIVATION INPUT, so a different kernel is a different hash and a
# stale-CRC .ko cannot be produced. Note kernelsmith's own buildKernel installs
# `headers_install` output as kernel-devel -- those are UAPI headers, NOT the
# modules_prepare build tree. Hence this builds its own (see draft 34, Slice 3:
# upstream a build-tree output + buildModule to kernelsmith).
{ pkgs, kernelsmith }:

let
  inherit (pkgs) lib;

  # linux_builder TARGET -> kernel ARCH=, matching _in_container_build.sh's
  # short_arch derivation (strip trailing el/eb, then collapse families).
  shortArch = {
    armel = "arm";
    arm64 = "arm64";
    mipseb = "mips";
    mipsel = "mips";
    mips64eb = "mips";
    mips64el = "mips";
    powerpc = "powerpc";
    powerpcle = "powerpc";
    powerpc64 = "powerpc";
    powerpc64le = "powerpc";
    loongarch64 = "loongarch";
    riscv64 = "riscv";
    x86_64 = "x86_64";
  };

  # Extra make target beyond vmlinux, and where the artifact lands / ships as.
  # arm64 deliberately ships Image.gz under the name zImage.arm64 -- preserving
  # the existing consumer-visible naming, quirk and all.
  bootArtifact = {
    armel = { target = "zImage"; src = "arch/arm/boot/zImage"; dst = "zImage"; };
    arm64 = { target = "Image.gz"; src = "arch/arm64/boot/Image.gz"; dst = "zImage"; };
    x86_64 = { target = "bzImage"; src = "arch/x86/boot/bzImage"; dst = "bzImage"; };
    loongarch64 = { target = "vmlinuz.efi"; src = "arch/loongarch/boot/vmlinuz.efi"; dst = "vmlinuz.efi"; };
    riscv64 = { target = "Image"; src = "arch/riscv/boot/Image"; dst = "Image"; };
  };

  # vmlinux is the deliverable boot artifact for these families.
  deliversVmlinux = target: lib.hasPrefix "mips" target || lib.hasPrefix "powerpc" target;

  # Which arch's TOOLCHAIN a target builds with, where that differs from the
  # target itself.
  #
  # The whole powerpc family builds with ONE biarch powerpc64 big-endian
  # compiler, exactly as _in_container_build.sh's get_cc does (every powerpc*
  # target there resolves to powerpc64-linux-musl-, or powerpc64-linux-gnu- on
  # 4.10). Bitness and endianness come from the kernel's own arch Makefile
  # driven by Kconfig -- NOT from the triple.
  #
  # This is not cosmetic. kernelsmith models the four powerpc variants as four
  # independent arches with four separate toolchains, and the per-variant
  # powerpc64LE toolchain is 64-bit only:
  #
  #   powerpc64   (BE, Bootlin power8):  -m32 OK  -m64 OK  -mlittle/-mbig OK
  #   powerpc64le (LE, Bootlin power8):  -m32 FAIL
  #
  # 6.13/powerpc64le sets CONFIG_COMPAT, so kbuild builds a 32-bit vDSO
  # (VDSO32A ... sigtramp32-32.o) and the LE-only compiler dies with
  # "cc1: error: '-m32' not supported in this configuration". Aligning the
  # family to powerpc64 fixes that and drops a from-source musl-cross-make
  # build for powerpcle, which Bootlin has no toolchain for at all.
  #
  # TODO(kernelsmith): this belongs upstream as a kernel-specific resolver
  # (`kernelToolchainFor`), NOT as a change to `toolchainFor` -- userland musl
  # for powerpc64le should still be the powerpc64le triple. Kept local until
  # that API exists.
  toolchainArch = target:
    if lib.hasPrefix "powerpc" target then "powerpc64" else target;

in
{ version, target, src, config }:

let
  arch = shortArch.${target} or (throw "kernel.nix: no ARCH mapping for target ${target}");
  boot = bootArtifact.${target} or null;
  toolchain = kernelsmith.toolchainFor version (toolchainArch target);
  crossPrefix = "${toolchain.target}-";

  # Trailing -Wno-error beats any -Werror the tree injects, at any depth.
  # Same technique kernelsmith's kernel.nix uses; it subsumes the ad-hoc
  # KCFLAGS/HOSTCFLAGS juggling _in_container_build.sh does for 4.10/powerpc.
  ccShim = pkgs.runCommand "igloo-ccshim-${target}" { } ''
    mkdir -p $out/bin
    for n in gcc cc; do
      if [ -x ${toolchain}/bin/${crossPrefix}$n ]; then
        printf '#!%s\nexec %s/bin/%s%s "$@" -Wno-error\n' \
          ${pkgs.runtimeShell} ${toolchain} ${crossPrefix} "$n" > $out/bin/${crossPrefix}$n
        chmod +x $out/bin/${crossPrefix}$n
      fi
    done
  '';

in
pkgs.stdenv.mkDerivation {
  pname = "igloo-kernel-${version}";
  inherit version;
  name = "igloo-kernel-${version}-${target}";

  outputs = [ "out" "dev" "vmlinux" ];
  dontUnpack = true;
  enableParallelBuilding = true;

  nativeBuildInputs = with pkgs; [
    ccShim toolchain
    gnumake bc bison flex perl python3 rsync cpio kmod which
    openssl elfutils pkg-config ubootTools util-linux zstd
  ];

  buildPhase = ''
    runHook preBuild
    export ARCH=${arch}
    export CROSS_COMPILE=${crossPrefix}
    export KBUILD_BUILD_TIMESTAMP="@0"
    export KBUILD_BUILD_USER=nix
    export KBUILD_BUILD_HOST=nix

    cp -r ${src} linux && chmod -R u+w linux
    mkdir -p build

    # Old trees vs. the Nix sandbox. Both of these work in the Docker build only
    # because an Ubuntu image happens to have the paths; neither is an IGLOO
    # change, so they are fixed here in the builder rather than in the patch
    # series (which must stay a faithful description of the fork branch).
    #
    # 4.10's Makefile validates KBUILD_OUTPUT with `cd $dir && /bin/pwd`, and
    # there is no /bin/pwd in the sandbox -- it fails with the profoundly
    # unhelpful "failed to create output directory".
    sed -i 's|/bin/pwd|pwd|g' linux/Makefile
    # Kbuild helpers carry shebangs like #!/usr/bin/awk that don't exist here;
    # unpatched they fail "not found" and cascade into Kconfig syntax errors.
    patchShebangs linux/scripts linux/tools 2>/dev/null || true

    echo ">>> .config (cpp-assembled fragment + olddefconfig)"
    cp ${config} build/.config
    make -C linux O=$PWD/build olddefconfig

    echo ">>> vmlinux ${lib.optionalString (boot != null) boot.target}"
    make -C linux O=$PWD/build vmlinux ${lib.optionalString (boot != null) boot.target} -j$NIX_BUILD_CORES

    echo ">>> modules_prepare + modules (Module.symvers)"
    make -C linux O=$PWD/build modules_prepare
    make -C linux O=$PWD/build modules -j$NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out

    # The unstripped vmlinux always goes to its own output -- osi/cosi need the
    # debug info, and nothing downstream can un-strip it later.
    mkdir -p $vmlinux
    cp build/vmlinux $vmlinux/vmlinux.${target}

    # $out gets a vmlinux ONLY where it is the deliverable boot artifact, which
    # is what build.sh does; every other target ships just its boot image.
    ${lib.optionalString (deliversVmlinux target) ''
      cp build/vmlinux $out/vmlinux.${target}
      ${crossPrefix}strip $out/vmlinux.${target} || true
    ''}
    ${lib.optionalString (boot != null) ''
      cp build/${boot.src} $out/${boot.dst}.${target}
    ''}
    cp build/Module.symvers $out/

    # --- kernel-devel: the modules_prepare result, source+build merged -------
    # Port of _in_container_build.sh's minimal-devel staging. An out-of-tree
    # build (make -C $KDIR M=$PWD modules) needs Makefile/.config/Module.symvers,
    # headers, arch Makefiles and scripts/ host tools -- not boot images or the
    # bulk of tools/.
    D=$dev
    mkdir -p $D
    cp build/.config build/Module.symvers $D/
    cp linux/Makefile linux/Kconfig $D/ || true
    cp -r linux/include $D/ 2>/dev/null || true
    cp -r build/include $D/ 2>/dev/null || true
    mkdir -p $D/arch
    for a in ${arch} ${lib.optionalString (arch == "x86_64") "x86"}; do
      cp -r linux/arch/$a $D/arch/ 2>/dev/null || true
      cp -r build/arch/$a $D/arch/ 2>/dev/null || true
    done
    cp -r linux/scripts $D/ 2>/dev/null || true
    cp -r build/scripts $D/ 2>/dev/null || true
    cp -r linux/tools $D/ 2>/dev/null || true
    cp -r build/tools $D/ 2>/dev/null || true

    chmod -R u+w $D
    # Slim: boot images and realmode are never read by a module build.
    rm -rf $D/arch/*/boot $D/arch/*/realmode || true
    # Keep tools/objtool (kbuild may run it on module objects); drop the rest.
    if [ -d $D/tools ]; then
      find $D/tools -mindepth 1 -maxdepth 1 ! -name objtool -exec rm -rf {} + || true
    fi
    runHook postInstall
  '';

  passthru = { inherit toolchain crossPrefix arch target version; };

  meta = {
    description = "IGLOO kernel ${version} for ${target} (kernelsmith toolchain, patch-series source)";
    platforms = [ "x86_64-linux" ];
  };
}
