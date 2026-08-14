{
  description = "IGLOO kernels: pristine upstream tarball + IGLOO patch series, cross-built by kernelsmith";

  nixConfig = {
    extra-substituters = [ "https://rehosting-tools.cachix.org" ];
    extra-trusted-public-keys = [
      "rehosting-tools.cachix.org-1:iNKSaFwG7MfGn6Fk7oTmIcLHqfffQ+cQIE5gWc6MlY0="
    ];
  };

  inputs = {
    # Provides the (kernel version, arch) -> cross toolchain resolver. Replaces
    # the embedded-toolchains Docker image, whose toolchains were unversioned
    # `wget https://musl.cc/*-cross.tgz` downloads -- i.e. today's shipped
    # kernels have no recorded compiler identity.
    kernelsmith.url = "github:rehosting/kernelsmith";
    nixpkgs.follows = "kernelsmith/nixpkgs";

    # Source only -- igloo_driver has no flake of its own yet. This is here to
    # ACCEPTANCE-TEST the kernel `dev` output (see nix/driver.nix): a build tree
    # that cannot build the one module we care about is broken, and this repo is
    # where that should be caught. It is not a claim about which repo should own
    # the driver build long-term.
    igloo_driver = {
      url = "github:rehosting/igloo_driver";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, kernelsmith, igloo_driver }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;

      # Upstream bases. These are REAL RELEASE TAGS -- the point of the patchset
      # migration. Previously linux/6.13 was pinned to a tree based on v6.13~5
      # with three upstream commits cherry-picked forward, which no one would
      # choose deliberately; those three are now simply present in the tarball.
      bases = {
        "4.10" = {
          tag = "4.10";
          hash = "sha256-PJXZ8Em9CF5cNG0sd/BjuEJfGRRg/NOun+fpTgR33Es=";
        };
        "6.13" = {
          tag = "6.13";
          hash = "sha256-553Mbrhmlca6v7B8KGGRK2NdUHXGzRzQVn0eoVX4DW4=";
        };
      };

      matrix = import ./nix/matrix.nix;
      configLib = import ./nix/config.nix { inherit pkgs; };
      sourceLib = import ./nix/source.nix { inherit pkgs; };
      mkKernel = import ./nix/kernel.nix { inherit pkgs kernelsmith; };

      # Arches kernelsmith cannot resolve a toolchain for yet. Listed explicitly
      # rather than silently dropped, so `nix build .#all` never quietly ships a
      # smaller matrix than build.sh does.
      #
      # Now empty: riscv64 landed as a Bootlin k6 pin, and loongarch64 as a
      # kernel-only gcc 13.3 (no libc toolchain exists for it from any source --
      # see kernelsmith's matrix.k6LoongarchKernel). Kept as a mechanism rather
      # than deleted, so a future arch gap is declared here instead of silently
      # shrinking `nix build .#all` below what build.sh covers.
      kernelsmithMissing = [ ];

      buildable = version: builtins.filter (t: !(builtins.elem t kernelsmithMissing)) matrix.${version};

      kernelSrcFor = version: sourceLib.kernelSource {
        patchesRoot = ./patches;
        inherit version;
        base = bases.${version};
      };

      # Memoise per version: one patched source tree feeds every target.
      sources = lib.genAttrs (builtins.attrNames matrix) kernelSrcFor;

      cellFor = version: target: mkKernel {
        inherit version target;
        src = sources.${version};
        config = configLib.rawConfig {
          configsSrc = ./configs;
          inherit version target;
        };
      };

      cells = lib.listToAttrs (lib.concatMap
        (version: map
          (target: lib.nameValuePair "kernel-${version}-${target}" (cellFor version target))
          (buildable version))
        (builtins.attrNames matrix));

      # ---- the release seam ---------------------------------------------
      # Keep emitting the two tarballs penguin consumes today, so switching
      # linux_builder to nix does not require touching penguin at all. Moving
      # penguin to a flake input is a separate, later change.
      analysisLib = import ./nix/analysis.nix { inherit pkgs; };
      releaseLib = import ./nix/release.nix { inherit pkgs; };
      mkPerf = import ./nix/perf.nix { inherit pkgs kernelsmith; };
      mkDriver = import ./nix/driver.nix { inherit pkgs kernelsmith; };

      # Per-cell record carrying everything the assembly needs.
      cellRecords = version: map
        (target:
          let kernel = cells."kernel-${version}-${target}"; in {
            inherit version target kernel;
            osi = analysisLib.osiConfig { inherit kernel version target; };
            cosi = analysisLib.cosiJson { inherit kernel version target; };
            perf = mkPerf {
              inherit version target;
              src = sources.${version};
              inherit (kernel) arch;
            };
            driver = mkDriver {
              inherit kernel version target;
              src = igloo_driver;
            };
          })
        (buildable version);

      allRecords = lib.concatMap cellRecords (builtins.attrNames matrix);

      # Per-cell analysis/perf outputs, individually addressable. Without these
      # a broken perf can only be reached through the whole release tarball,
      # which rebuilds everything to show you one compiler error.
      perCellOutputs = lib.listToAttrs (lib.concatMap
        (r: [
          (lib.nameValuePair "perf-${r.version}-${r.target}" r.perf)
          (lib.nameValuePair "driver-${r.version}-${r.target}" r.driver)
          (lib.nameValuePair "osi-${r.version}-${r.target}" r.osi)
          (lib.nameValuePair "cosi-${r.version}-${r.target}" r.cosi)
        ])
        allRecords);

    in
    {
      packages.${system} = cells // perCellOutputs // {
        default = cells."kernel-6.13-armel";

        # Everything buildable today, in one derivation, for CI.
        all = pkgs.linkFarm "igloo-kernels-all"
          (lib.mapAttrsToList (n: v: { name = n; path = v; }) cells);

        # The same payload as kernels-latest, but as a directory. This is the
        # seam for Nix consumers: penguin stages `<version>/...` straight into
        # /igloo_static/kernels/, so handing it the tree avoids packing an
        # archive purely for the consumer to unpack again.
        kernels = releaseLib.kernelsTree {
          versions = map
            (version: {
              inherit version;
              dir = releaseLib.kernelsDir { inherit version; cells = cellRecords version; };
            })
            (builtins.attrNames matrix);
        };

        # Drop-in replacements for the Docker build's release artifacts.
        kernels-latest = releaseLib.kernelsTarball {
          versions = map
            (version: {
              inherit version;
              dir = releaseLib.kernelsDir { inherit version; cells = cellRecords version; };
            })
            (builtins.attrNames matrix);
        };
        kernel-devel-all = releaseLib.develTarball { cells = allRecords; };

        # Catches the failure class where a cell builds fine and produces an
        # artifact whose ELF class or endianness disagrees with its target name.
        # See nix/shape.nix -- two such bugs shipped undetected on this branch.
        shape-check = (import ./nix/shape.nix { inherit pkgs; }) { cells = allRecords; };

        # The analysis tools, pinned. Exposed so their provenance is inspectable
        # and so igloo_driver can reuse dwarf2json for its own ISF (it runs the
        # same fork over igloo.ko) instead of re-deriving the pin.
        inherit (analysisLib) dwarf2json extractKernelinfo;
      };

      # The patched source trees, so `nix build .#sources.x86_64-linux."6.13"`
      # gives you exactly what the kernel builds from -- useful for inspecting
      # what the series produces without a full kernel build.
      inherit sources;

      # Cells we cannot build until kernelsmith gains these arches.
      missingArches = kernelsmithMissing;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ gnumake bc bison flex openssl elfutils git ];
        shellHook = ''
          echo "linux_builder (nix-patchset)"
          # NB: cell names contain a '.', which nix would parse as an attrpath
          # separator -- quote the attribute or the build fails to resolve.
          echo '  nix build .#packages.x86_64-linux."kernel-6.13-armel"   one cell'
          echo "  nix build .#all                                        every buildable cell"
          echo "  ./scripts/verify-series.sh ...                         prove a series matches its fork branch"
        '';
      };
    };
}
