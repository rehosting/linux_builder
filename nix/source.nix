# Kernel source = PRISTINE UPSTREAM TARBALL + the IGLOO patch series.
#
# This is the change that removes the submodules. Previously the source was two
# long-lived fork branches of rehosting/linux, pinned by SHA in .gitmodules --
# and .gitmodules named the WRONG branches (it declared main_6.7 for linux/6.13
# while the pin was actually main_6.13, a tree 89,775 commits apart). Basing on
# a real upstream tag makes that class of drift unrepresentable.
#
# Each version's series file lists patch paths relative to patches/, so core
# patches and per-version adapters can interleave in a defined order:
#
#   patches/6.13/series
#     core/0001-add-hypercall.h.patch
#     6.13/0001-syscall_wrapper-add-x86-support.patch
{ pkgs }:

let
  inherit (pkgs) lib;

  # "4.10" -> "v4.x", "6.13" -> "v6.x"
  seriesDir = version: "v${lib.versions.major version}.x";

  # Read a series file into an ordered list of patch paths, ignoring blank lines
  # and # comments (quilt convention).
  readSeries =
    patchesRoot: version:
    let
      file = "${patchesRoot}/${version}/series";
      lines = lib.splitString "\n" (builtins.readFile file);
      keep = l: l != "" && !(lib.hasPrefix "#" l);
    in
    map (l: "${patchesRoot}/${l}") (builtins.filter keep (map lib.trim lines));

in
{
  inherit readSeries;

  # bases: { "4.10" = { tag = "4.10"; hash = "sha256-..."; }; ... }
  kernelSource =
    { patchesRoot, version, base }:
    pkgs.applyPatches {
      name = "linux-${base.tag}-igloo";
      src = pkgs.fetchurl {
        url = "https://cdn.kernel.org/pub/linux/kernel/${seriesDir base.tag}/linux-${base.tag}.tar.xz";
        inherit (base) hash;
      };
      patches = readSeries patchesRoot version;
    };
}
