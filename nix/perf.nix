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

  # NB: deliberately NO powerpc family collapsing here, unlike kernel.nix.
  #
  # kernel.nix routes all four powerpc variants through one biarch powerpc64 BE
  # toolchain, which is correct for a kernel: it is built -nostdinc
  # -ffreestanding, and arch/powerpc/Makefile derives -m32/-m64 and the
  # endianness from Kconfig, so one compiler yields four different kernels.
  #
  # perf has no Kconfig and links -static against a TARGET LIBC, so neither of
  # those holds. Collapsing the family here produced four BYTE-IDENTICAL
  # big-endian 64-bit binaries for powerpc, powerpcle, powerpc64 and
  # powerpc64le -- three of which cannot run on their guest at all. It fails
  # silently: every cell builds, `perf` exists, and only the ELF header shows
  # the damage.
  #
  # Using each variant's own toolchain also gets the matching 32-bit/LE musl,
  # which a 64-bit BE sysroot simply does not contain.
  toolchainArch = target: target;

  # perf resolves its tools headers with -I$(srctree)/tools/arch/$(ARCH)/include/uapi,
  # using ARCH verbatim rather than the SRCARCH that kbuild derives from it. The
  # kernel build takes ARCH=x86_64 and normalises it to x86 internally; perf does
  # not, and tools/arch/x86_64/ does not exist, so 4.10 fails with
  #   tools/include/uapi/linux/mman.h:4: fatal error: uapi/asm/mman.h: No such file
  # which names the generic header rather than the missing arch directory.
  # tools/arch/x86/ is correct for every kernel version, so map it here.
  perfArch = a: if a == "x86_64" then "x86" else a;

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

  # perf probes for optional libc features by compiling test programs under
  # tools/build/feature. Cross-compiling makes several of those tests fail for
  # reasons that have nothing to do with whether the feature exists, and perf
  # responds by defining its own fallback -- which then collides with the real
  # declaration the target libc does provide:
  #
  #   bench/bench.h:66      conflicting types for 'pthread_attr_setaffinity_np'
  #   builtin-record.c:207  static declaration of 'gettid' follows non-static
  #
  # Both symbols are present in glibc, so the honest fix is to tell perf the
  # truth rather than silence the warning. Only the glibc target needs this;
  # the musl/kernel-only toolchains really do lack them, and there perf's
  # fallback is correct.
  glibcFeatureFlags = lib.concatStringsSep " " [
    "-DHAVE_PTHREAD_ATTR_SETAFFINITY_NP"
    "-DHAVE_GETTID"
  ];

in
{ version, target, src, arch }:

let
  isLoong = target == "loongarch64";

  # loongarch64: nixpkgs glibc cross (has a libc). Everything else: the same
  # kernelsmith toolchain that built the kernel.
  loongCross = pkgs.pkgsCross.loongarch64-linux;

  # Use the WRAPPED cross cc, not the bare gcc: the wrapper is what puts the
  # target glibc on the include and library search paths. With the bare gcc the
  # compile succeeds and the link fails on -lpthread/-lrt/-lm/-ldl, which reads
  # like a missing dependency but is really a missing sysroot.
  toolchain =
    if isLoong then loongCross.stdenv.cc
    else kernelsmith.toolchainFor version (toolchainArch target);

  # -static needs the archive halves of glibc, which nixpkgs splits into a
  # separate `static` output.
  loongLibs = lib.optionals isLoong [
    loongCross.buildPackages.binutils
    loongCross.stdenv.cc.libc.static
  ];

  crossPrefix =
    if isLoong then loongCross.stdenv.cc.targetPrefix
    else "${toolchain.target}-";

  ldFlag = extraLdFlags.${target} or "";

in
pkgs.stdenv.mkDerivation {
  name = "igloo-perf-${version}-${target}";
  dontUnpack = true;
  enableParallelBuilding = true;

  nativeBuildInputs = [ toolchain ] ++ loongLibs ++ (with pkgs; [
    gnumake bison flex perl python3 pkg-config which
  ]);

  buildPhase = ''
    runHook preBuild
    cp -r ${src} linux && chmod -R u+w linux
    patchShebangs linux/scripts linux/tools 2>/dev/null || true

    # Same sandbox breakage kernel.nix hits, in a different file: 4.10-era
    # tools/scripts/Makefile.include validates OUTPUT with `cd $dir && /bin/pwd`,
    # and there is no /bin/pwd here. It reports it as
    #   *** output directory "/build/out/" does not exist.  Stop.
    # which points at the wrong thing entirely -- the directory is right there.
    # Not an IGLOO change, so it is fixed in the builder, not the patch series.
    find linux/tools linux/Makefile -name 'Makefile*' -o -name '*.mk' 2>/dev/null \
      | xargs -r sed -i 's|/bin/pwd|pwd|g'
    sed -i 's|/bin/pwd|pwd|g' linux/Makefile

    mkdir -p out
${lib.optionalString (ldFlag != "") ''
    # mips64: the musl toolchain's ld defaults to the n32 emulation
    # (elf32-ntradlittlemips) while the objects are n64, so relocatable links
    # inside libapi fail with "ABI is incompatible with that of the selected
    # emulation".
    #
    # Passing LD="ld -m elf64ltsmip" on the make command line is not enough:
    # tools/perf/Makefile does `unexport MAKEFLAGS`, so command-line variables
    # do NOT reach the nested tools/lib/* builds, and those are exactly where
    # the failure is. A PATH shim survives that, because every one of those
    # builds resolves $(CROSS_COMPILE)ld through PATH.
    #
    # A shim rather than LDEMULATION= because the environment variable would
    # also be picked up by the HOST ld that builds fixdep.
    mkdir -p ldshim
    cat > ldshim/${crossPrefix}ld <<EOF
#!${pkgs.runtimeShell}
exec $(command -v ${crossPrefix}ld)${ldFlag} "\$@"
EOF
    chmod +x ldshim/${crossPrefix}ld
    export PATH="$PWD/ldshim:$PATH"
''}

    # Drop the dlfilters from the build. They are dlopen plugins -- dead weight
    # in a -static perf, which cannot usefully dlopen anything -- and we never
    # ship them, since installPhase copies only out/perf. On loongarch64 they
    # are worse than dead weight: linking a .so against a static-only glibc
    # segfaults binutils 2.41.
    #
    # Done by editing ALL_PROGRAMS rather than by naming $(OUTPUT)perf as the
    # goal, because Makefile.perf re-invokes itself through a sub-make that
    # rewrites OUTPUT, and an absolute-path goal does not survive the round trip
    # ("No rule to make target '/build/out/libapi/libapi.a'").
    sed -i 's|^ALL_PROGRAMS = $(PROGRAMS) $(SCRIPTS) $(DLFILTERS)|ALL_PROGRAMS = $(PROGRAMS) $(SCRIPTS)|' \
      linux/tools/perf/Makefile.perf

    make -C linux/tools/perf \
      ARCH=${perfArch arch} \
      CROSS_COMPILE=${crossPrefix} \
      CC="${crossPrefix}gcc" \
      LD="${crossPrefix}ld" \
      OUTPUT=$PWD/out/ \
      LDFLAGS="-static" \
      WERROR=0 \
      EXTRA_CFLAGS="${extraCFlags}${lib.optionalString isLoong " ${glibcFeatureFlags}"}" \
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
