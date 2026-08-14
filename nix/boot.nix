# Boot every shipped kernel under qemu and assert it actually starts.
#
# THIS IS THE CHECK THAT WAS MISSING. nixdev_0.1.0 shipped a 4.10/x86_64
# bzImage that compiles, links, packages, has the correct ELF class, byte order
# and machine, is the same 8.1 MB as the Docker build's -- and prints not one
# line before dying. Every existing gate passed it:
#
#   * the build succeeded
#   * shape-check passed (a bzImage's shape says nothing about whether it runs)
#   * the series gate passed (it only proves the patches APPLY)
#   * kernelsmith's own boot.nix passed -- but its k4 cell boots 5.10.229, and
#     the k4 band spans 4.x AND 5.x, so 4.10 had never been booted by anything
#
# It was found by a downstream consumer's integration tests (rehosting/penguin#932),
# which is three repos and one release too late.
#
# The machine/console table is transcribed from penguin's src/penguin/arch_registry.py
# -- deliberately, so this boots each kernel on the machine penguin will actually
# run it on. A kernel that boots under some other qemu model is not the claim
# anyone downstream needs.
{ pkgs }:

let
  inherit (pkgs) lib;

  # target -> how penguin boots it. `null` means "no qemu machine exists",
  # which is DECLARED here rather than silently skipped.
  machines = {
    armel = { system = "arm"; machine = "virt"; console = "ttyAMA0"; };
    arm64 = { system = "aarch64"; machine = "virt"; cpu = "cortex-a57"; console = "ttyAMA0"; };
    mipsel = { system = "mipsel"; machine = "malta"; console = "ttyS0"; };
    mipseb = { system = "mips"; machine = "malta"; console = "ttyS0"; };
    mips64el = { system = "mips64el"; machine = "malta"; cpu = "MIPS64R2-generic"; console = "ttyS0"; };
    mips64eb = { system = "mips64"; machine = "malta"; cpu = "MIPS64R2-generic"; console = "ttyS0"; };
    powerpc64 = { system = "ppc64"; machine = "pseries"; cpu = "power9"; console = "hvc0"; };
    powerpc64le = { system = "ppc64"; machine = "pseries"; cpu = "power9"; console = "hvc0"; };
    riscv64 = { system = "riscv64"; machine = "virt"; console = "ttyS0"; };
    loongarch64 = { system = "loongarch64"; machine = "virt"; cpu = "la464"; console = "ttyS0"; };
    x86_64 = { system = "x86_64"; machine = "pc"; console = "ttyS0"; };

    # 32-bit powerpc: arch_registry.py records qemu_machine=None -- "no QEMU
    # machine was ever configured for 32-bit ppc". Nothing to boot it on, so it
    # is unbootable-by-declaration rather than an oversight. If a machine is
    # ever wired up in penguin, add it here too.
    powerpc = null;
  };

  # The kernel image each target ships, by extension of what kernelsDir copies.
  # Globbed rather than tabulated: the artifact name varies by arch
  # (zImage./bzImage./vmlinux./Image.) and duplicating that table here is one
  # more thing to drift.
  bootTest = { kernel, version, target, spec }:
    pkgs.runCommand "igloo-boot-${version}-${target}"
      {
        nativeBuildInputs = [ pkgs.qemu ];
        meta.description = "boot smoke test for ${version}/${target}";
      } ''
      img=""
      for cand in ${kernel}/bzImage.${target} ${kernel}/zImage.${target} \
                  ${kernel}/Image.${target} ${kernel}/vmlinux.${target}; do
        [ -f "$cand" ] && { img="$cand"; break; }
      done
      if [ -z "$img" ]; then
        echo "no bootable image for ${version}/${target} in ${kernel}" >&2
        ls ${kernel} >&2
        exit 1
      fi
      echo "booting $(basename $img) on qemu-system-${spec.system} -M ${spec.machine}"

      # No rootfs is supplied on purpose. A kernel that starts and then cannot
      # mount root is a SUCCESS for this test -- it proves early boot, console
      # init and the whole pre-userspace path. Supplying a rootfs would test
      # penguin's job, not this one.
      #
      # `timeout` rather than qemu's own exit: a kernel that hangs must fail
      # here, not run until the CI job is killed.
      timeout 120 qemu-system-${spec.system} \
        -M ${spec.machine} \
        ${lib.optionalString (spec ? cpu) "-cpu ${spec.cpu}"} \
        -m 256 -nographic -no-reboot \
        -kernel "$img" \
        -append "console=${spec.console} panic=1" \
        < /dev/null > boot.log 2>&1 || true

      echo "--- captured $(wc -c < boot.log) bytes ---"
      cat boot.log

      # Two assertions, in increasing strength.
      #
      # 1. The kernel banner. This alone is what nixdev_0.1.0's 4.10/x86_64
      #    failed: it decompressed, printed "Booting the kernel.", and went
      #    silent forever.
      if ! grep -q "Linux version" boot.log; then
        echo "FAIL ${version}/${target}: no kernel banner -- it never started" >&2
        exit 1
      fi

      # 2. It got as far as looking for a root filesystem. Without this a kernel
      #    that prints its banner and then dies in early init would still pass,
      #    which is most of the failure surface this test exists for.
      if ! grep -Eq "VFS: Cannot open root|VFS: Unable to mount root|Kernel panic - not syncing|No filesystem could mount root|Attempted to kill init|Requested init" boot.log; then
        echo "FAIL ${version}/${target}: banner printed but never reached the root-fs stage" >&2
        exit 1
      fi

      echo "ok ${version}/${target}" > $out
    '';

in
rec {
  inherit machines;

  # null spec -> a derivation that records WHY it is not boot-tested. Not a
  # silent omission: `nix build .#boot-check` still names it.
  forCell = { kernel, version, target }:
    let spec = machines.${target} or (throw
      "boot.nix: target ${target} has no entry; add it (or an explicit null)");
    in
    if spec == null then
      pkgs.runCommand "igloo-boot-${version}-${target}-skipped" { } ''
        echo "SKIP ${version}/${target}: no qemu machine exists for this target" | tee $out
      ''
    else bootTest { inherit kernel version target spec; };

  # One derivation that boots the whole matrix, for CI.
  all = { cells }:
    pkgs.linkFarm "igloo-boot-check"
      (map (c: {
        name = "${c.version}-${c.target}";
        path = forCell { inherit (c) kernel version target; };
      }) cells);
}
