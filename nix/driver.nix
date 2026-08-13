# igloo.ko per cell, built against this flake's kernel derivation.
#
# This exists here rather than in igloo_driver's own repo for one reason: it is
# the acceptance test for kernelsmith's `buildModule` and for the `dev` (build
# tree) output. If a module cannot be built from a linux_builder cell without
# unpacking a tarball, the devel output is wrong, and it is better to find that
# out in this repo's CI than in igloo_driver's.
#
# The CRC property is the point. `_in_container_build.sh` extracts
# kernel-devel-all.tar.gz to a scratch directory and builds against whatever is
# there, so nothing structurally prevents building a module against a different
# kernel than the one it will be inserted into -- the failure mode is a module
# that loads and then misbehaves, or refuses to load with a version magic
# mismatch, depending on how far the drift went. Here the kernel derivation is
# an input, so a mismatched pair is not representable.
{ pkgs, kernelsmith }:

{ kernel, src, version, target }:

kernelsmith.buildModule {
  name = "igloo-${version}-${target}";
  inherit version src kernel;

  # igloo_driver's Makefile is not a bare `obj-m :=` file. Its default target
  # generates two headers (portal_tramp_gen.h, ffi_stubs_generated.h) with
  # python3 and only then re-enters kbuild. Driving kbuild directly would skip
  # the codegen and fail on the missing headers.
  entry = "wrapper";

  nativeBuildInputs = [ pkgs.python3 ];

  # The upstream Makefile lives in src/; everything it references is relative to
  # it ($(src)/portal, $(src)/../scripts).
  preBuild = "cd src";

  # NB: 32-bit powerpc needs arch/powerpc/lib/crtsavres.o staged into the module
  # build directory. That is handled generically in kernelsmith's buildModule --
  # it is a property of ppc32 kbuild, not of this module. _in_container_build.sh
  # carries the same workaround, plus an EXTRA_LDFLAGS="-L…" that does nothing:
  # KBUILD_LDFLAGS_MODULE names the object positionally, and -L only affects -l.
}
