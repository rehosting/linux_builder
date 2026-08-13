# perf.<target> -- the statically-linked guest perf binary shipped in
# kernels-latest.tar.gz.
#
# A faithful port of _in_container_build.sh's perf step, with ONE deliberate
# behavioural change: this fails loudly.
#
# The shell runs the build with `|| echo "Warning: Failed to build perf ..."`
# and then guards the copy with `[ -f "$PERF_SRC" ]`, so an arch whose perf does
# not compile silently ships without one. The result is that
# rehosting/penguin:latest carries perf for exactly 3 of 13 targets (armel,
# loongarch64, mips64el) and nobody had to notice. Here a broken arch breaks the
# build, so "this arch has no perf" has to be a decision someone writes down
# rather than a build-day accident.
#
# perf links -static against a TARGET LIBC, which is why loongarch64 cannot use
# the kernel-only gcc that builds its kernel (see kernelsmith's
# matrix.k6LoongarchKernel -- kernel-only means no libc at all). It uses the
# nixpkgs glibc cross instead, whose triple
# (loongarch64-unknown-linux-gnu-) is byte-identical to the hand-installed
# /opt/cross toolchain the Docker image reaches for. So loongarch64 is the one
# arch where the kernel and its perf are built by different compilers -- exactly
# as in production, just written down.
{ pkgs, kernelsmith }:

let
  inherit (pkgs) lib;

  # Same family collapsing as kernel.nix: one biarch powerpc64 toolchain builds
  # every powerpc variant, matching get_cc.
  toolchainArch = target:
    if lib.hasPrefix "powerpc" target then "powerpc64" else target;

  # mips64 needs an explicit output-format flag or ld picks the wrong ABI.
  extraLdFlags = {
    mips64el = " -m elf64ltsmip";
    mips64eb = " -m elf64btsmip";
  };

  # The NO_* soup, verbatim from the shell. perf pulls in a large optional
  # dependency surface; every one of these is off in the shipped build, so a
  # difference here would be a silently different binary.
  noFlags = [
    "NO_LIBELF" "NO_LIBUNWIND" "NO_LIBNUMA" "NO_LIBAUDIT"
    "NO_LIBBIONIC" "NO_LIBPYTHON" "NO_LIBPERL" "NO_SLANG" "NO_LZMA"
    "NO_ZLIB" "NO_LIBBPF" "NO_JVMTI" "NO_LIBCRYPTO" "NO_LIBZSTD"
    "NO_LIBTRACEEVENT" "NO_AUXTRACE" "NO_CORESIGHT"
  ];

  extraCFlags = lib.concatStringsSep " " [
    "-Wno-error" "-fcommon" "-D__always_inline=inline"
    "-Wno-redundant-decls" "-Wno-format-truncation"
    "-Wno-format-overflow" "-Wno-array-bounds"
  ];

in
{ version, target, src, arch }:

let
  isLoong = target == "loongarch64";

  # loongarch64: nixpkgs glibc cross (has a libc). Everything else: the same
  # kernelsmith toolchain that built the kernel.
  loongCross = pkgs.pkgsCross.loongarch64-linux;
  toolchain = if isLoong then loongCross.buildPackages.gcc else kernelsmith.toolchainFor version (toolchainArch target);
  binutils = lib.optional isLoong loongCross.buildPackages.binutils;
  crossPrefix =
    if isLoong then loongCross.stdenv.cc.targetPrefix
    else "${toolchain.target}-";

  ldFlag = extraLdFlags.${target} or "";

in
pkgs.stdenv.mkDerivation {
  name = "igloo-perf-${version}-${target}";
  dontUnpack = true;
  enableParallelBuilding = true;

  nativeBuildInputs = [ toolchain ] ++ binutils ++ (with pkgs; [
    gnumake bison flex perl python3 pkg-config which
  ]);

  buildPhase = ''
    runHook preBuild
    cp -r ${src} linux && chmod -R u+w linux
    patchShebangs linux/scripts linux/tools 2>/dev/null || true
    mkdir -p out

    make -C linux/tools/perf \
      ARCH=${arch} \
      CROSS_COMPILE=${crossPrefix} \
      CC="${crossPrefix}gcc" \
      LD="${crossPrefix}ld${ldFlag}" \
      OUTPUT=$PWD/out/ \
      LDFLAGS="-static" \
      WERROR=0 \
      EXTRA_CFLAGS="${extraCFlags}" \
      HOSTCFLAGS="-Wno-error" \
      ${lib.concatMapStringsSep " " (f: "${f}=1") noFlags} \
      -j$NIX_BUILD_CORES

    # Deliberately NOT the shell's silent `[ -f ]` guard -- see header.
    test -f out/perf || { echo "FAIL: perf did not build for ${target}"; exit 1; }
    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out
    cp out/perf $out/perf.${target}
    ${crossPrefix}strip $out/perf.${target} || true
  '';

  meta.description = "static guest perf for ${version}/${target}";
}
