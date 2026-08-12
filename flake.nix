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
  };

  outputs =
    { self, nixpkgs, kernelsmith }:
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

      # kernelsmith's arch table covers 12 arches; these two are ours and not
      # yet in it. Listed explicitly rather than silently dropped -- see draft 34
      # Slice 2, which lands them upstream instead of forking the table.
      kernelsmithMissing = [ "loongarch64" "riscv64" ];

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

    in
    {
      packages.${system} = cells // {
        default = cells."kernel-6.13-armel";

        # Everything buildable today, in one derivation, for CI.
        all = pkgs.linkFarm "igloo-kernels-all"
          (lib.mapAttrsToList (n: v: { name = n; path = v; }) cells);
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
