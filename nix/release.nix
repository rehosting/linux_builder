# The release seam: reassemble the two tarballs penguin already consumes, so a
# nix-built linux_builder is a drop-in for the Docker one.
#
#   kernels-latest.tar.gz    entries under `kernels/<version>/`
#                            (penguin untars it into /igloo_static/, and
#                            src/penguin/utils.py globs /igloo_static/kernels/*/)
#   kernel-devel-all.tar.gz  entries under `./<target>.<version>/`
#
# Tarballs are built reproducibly (sorted, epoch mtimes, numeric root owner,
# gzip -n). The Docker build stamps `Built by linux_builder on $(date)` into
# README.txt, which alone would make every archive byte-different; the date is
# dropped rather than faked, and the provenance that matters -- the store path
# each artifact came from -- is recorded instead.
#
# perf.<target> is built for EVERY cell -- see nix/perf.nix. build.sh swallows
# perf build failures, so rehosting/penguin:latest ships perf for only 3 of 13
# targets (armel, loongarch64, mips64el) without that ever being a decision.
# Here a failing arch fails the build instead.
{ pkgs }:

let
  inherit (pkgs) lib;

  # tar flags that make an archive a function of its contents only.
  reproTar = "--sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner";

in
rec {
  # One version's worth of /kernels/<version>: boot artifacts + analysis output.
  kernelsDir = { version, cells }:
    pkgs.runCommand "igloo-kernels-dir-${version}" { } ''
      mkdir -p $out
      ${lib.concatMapStringsSep "\n"
        (c: ''
          # Boot artifacts (zImage./bzImage./Image./vmlinuz.efi./vmlinux.<t>).
          # Module.symvers is a build input, not a shipped artifact -- skip it.
          for f in ${c.kernel}/*; do
            b=$(basename "$f")
            [ "$b" = "Module.symvers" ] && continue
            cp -a "$f" $out/"$b"
          done
          cp ${c.osi} $out/osi.${c.target}.config
          cp ${c.cosi} $out/cosi.${c.target}.json.xz
          cp ${c.perf}/perf.${c.target} $out/perf.${c.target}
        '')
        cells}

      # Aggregate profile, concatenated in a STABLE order. The shell relies on
      # glob order, which is locale-dependent; sort explicitly.
      for f in $(ls $out/osi.*.config | sort); do cat "$f" >> $out/osi.config; done
    '';

  # The tarball's payload as a plain directory: `<version>/<artifacts>`, which is
  # exactly the layout penguin lays down at /igloo_static/kernels/.
  #
  # Exposed separately so a Nix consumer can take the tree directly instead of
  # the archive. penguin's flake currently pins the release TARBALL
  # (`inputs.kernels`, flake = false) and relies on Nix unpacking it; going
  # through kernelsTarball from another flake would mean tar-then-untar of
  # ~335 MB to reproduce a directory this already has. Same contents either way
  # -- kernelsTarball is defined in terms of this.
  kernelsTree = { versions }:
    pkgs.runCommand "igloo-kernels" { } ''
      mkdir -p $out
      ${lib.concatMapStringsSep "\n"
        (v: ''cp -a ${v.dir} $out/${v.version}'')
        versions}
      chmod -R u+w $out

      # Deliberately not the Docker build's `Built by linux_builder on $(date)`:
      # a timestamp would make the archive non-reproducible for no benefit.
      # Written with printf rather than a heredoc so the Nix indentation of this
      # file does not end up inside the shipped file.
      printf '%s\n' \
        'Built by linux_builder (nix + patch series).' \
        "" \
        'Provenance is the store path of each input, not a build date -- these' \
        'artifacts are a pure function of the pinned kernel tarball, the patch' \
        'series in patches/, the config in configs/, and the kernelsmith toolchain.' \
        > $out/README.txt
    '';

  kernelsTarball = { versions }:
    pkgs.runCommand "kernels-latest.tar.gz" { nativeBuildInputs = [ pkgs.gzip ]; } ''
      mkdir -p stage
      cp -a ${kernelsTree { inherit versions; }} stage/kernels
      chmod -R u+w stage
      tar ${reproTar} -cf - -C stage kernels | gzip -9n > $out
    '';

  develTarball = { cells }:
    pkgs.runCommand "kernel-devel-all.tar.gz" { nativeBuildInputs = [ pkgs.gzip ]; } ''
      mkdir -p stage
      ${lib.concatMapStringsSep "\n"
        # The Docker layout is <target>.<version>, not <version>/<target>.
        (c: ''cp -a ${c.kernel.dev} stage/${c.target}.${c.version}'')
        cells}
      chmod -R u+w stage
      tar ${reproTar} -cf - -C stage . | gzip -9n > $out
    '';
}
