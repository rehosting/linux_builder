linux\_builder
====

The IGLOO kernels: pristine upstream release tarballs plus an explicit IGLOO
patch series, cross-built by [kernelsmith][ks] for every target penguin
emulates.

Two kernel versions (`4.10`, `6.13`) across up to eleven targets — 19 buildable
cells in all. Each cell ships a boot image, a `vmlinux`, a minimal kernel-devel
tree, `perf`, and the OSI/COSI analysis artifacts penguin needs.

[ks]: https://github.com/rehosting/kernelsmith

## Quick start

Everything is a Nix flake output. There is no container to build first.

```sh
nix build .#packages.x86_64-linux."kernel-6.13-armel"   # one cell
nix build .#all                                          # every buildable cell
nix build .#kernels                                      # the payload as a tree
nix build .#kernels-latest                               # ...and as a tarball
```

Cell names contain a `.`, which Nix parses as an attribute-path separator, so
**the quoting above is mandatory** — `.#kernel-6.13-armel` does not resolve.

## Where the source comes from

Not from a submodule. `patches/` carries the IGLOO delta as an ordered series
applied to a pristine kernel.org tarball, pinned by hash in `patches/base.json`.
See [`patches/README.md`](patches/README.md) for the layout, how much is really
shared between versions, and how to add or refresh a patch.

To prove a series still reproduces the fork branch it replaced:

```sh
./scripts/verify-series.sh 4.10 <tarball> <fork-ref> <git-dir>
```

`scripts/import-series.sh` and `scripts/export-series.sh` move patches between
this repo and a fork branch.

## Checks

| command | what it proves |
|---|---|
| `nix build .#boot-check` | **every kernel actually boots** under the qemu machine penguin runs it on |
| `nix build .#shape-check` | each artifact's ELF class, byte order and machine match its target name |
| `nix build .#config-required` | every kernel ended up with the options IGLOO needs (see [Modifying configs](#modifying-configs)) |
| `nix flake check` | the above, plus evaluation of every output |

`boot-check` is the one that matters most, and it is newer than the rest.
`nixdev_0.1.0` shipped a `4.10/x86_64` kernel that compiled, linked, packaged,
had the correct ELF shape and was the same size as the Docker build's — and
printed nothing before dying. Every other gate passed it; it was caught three
repos downstream in penguin's integration tests. Booting it is the only check
that would have said so. See [`nix/boot.nix`](nix/boot.nix).

32-bit `powerpc` is boot-tested as an explicit SKIP: penguin's
`arch_registry.py` records no qemu machine for it, so it is unbootable by
declaration rather than by oversight.

## Modifying configs

Configs live in `configs/<version>/<target>`, with shared fragments pulled in by
`#include` (`all-common.inc`, `arm-common.inc`, ...). They are assembled with
`cpp -P -undef` and then `olddefconfig`.

**The file you edit is almost never the file an option comes from,** and the
config the kernel is *built* with is a third thing again — `olddefconfig` runs
last and drops anything whose dependencies are unmet. Three tools follow from
that, one per question:

| question | command |
|---|---|
| Did every cell **end up** with what IGLOO needs? | `nix build .#config-required` |
| Where does `CONFIG_X` for this cell **come from**? | `nix run .#config-explain -- 6.13 x86_64 CONFIG_IGLOO` |
| Which lines am I writing that **do nothing**? | `nix build .#config-redundant` |

`config-required` is a **gate**, and it reads the shipped `.config` rather than
the fragments — that distinction is the entire point. It asserts the options
whose absence is *silent*: a kernel that builds, boots, and then does not do
its job. `CONFIG_MODVERSIONS` is the sharpest of them; without it a mismatched
`igloo.ko` loads quietly instead of being rejected, which is strictly worse
than the mismatch. See `nix/config-tools.nix`, where every entry says what
breaks without it.

`config-explain` builds no kernel, so it is instant. It exists because grep
does not answer the question: `CONFIG_IGLOO` is set in `all-common.inc` and no
target sets it directly, so grepping `configs/6.13/x86_64` finds nothing.

```
$ nix run .#config-explain -- 6.13 armel CONFIG_MODULES
  CONFIG_MODULES=y
      configs/6.13/all-common.inc:159
      via armel -> arm-common.inc -> all-common.inc
* CONFIG_MODULES=y
      configs/6.13/all-common.inc:162
      via armel -> arm-common.inc -> all-common.inc

  2 assignments; the one marked * wins (cpp: last wins).
```

`config-redundant` separates two things that look alike and are not: an option
assigned **twice** (always a bug — only the last has effect) and an option that
**did not survive olddefconfig** (usually a dependency you did not notice). It
currently reports 595 duplicate assignments across the matrix.

And the raw savedefconfig lint, per cell or across the matrix:

```sh
nix build .#packages.x86_64-linux."config-lint-6.13-armel"   # one cell
nix build .#config-lint                                       # every cell
```

Each produces `config_<version>_<target>.linted` (the `savedefconfig` form) and
a `.diff` against the assembled config. **This is advisory, not a gate.**
`savedefconfig` prunes options that are already the arch default and
de-duplicates, so a readable config fragment and its savedefconfig form never
match — the diff tells you which of your lines were redundant, and that is all
it is for. Turning it into an assertion would mean replacing the `#include`
structure with savedefconfig output, which is a bad trade.

This replaces `./build.sh --config-only`, which did the same thing and likewise
discarded its own exit status.

## Releases

Pushing a `nixdev_*` tag runs the full 19-cell matrix, boot-tests it, publishes
`kernels-latest.tar.gz` + `kernel-devel-all.tar.gz` as a **prerelease**, and
pushes every cell to the `rehosting-tools` Cachix — which is what lets
downstream repos substitute these kernels instead of cross-building them.

```sh
git tag -a nixdev_0.1.2 -m "..." && git push origin nixdev_0.1.2
```

The tag glob is anchored, so `nixdev_*` and the old `dev_*` never collide.

## Consumers

- **penguin** takes this repo as a *flake input* and stages `.#kernels`
  directly. The tarball is kept for other consumers, but the flake is the seam
  that records **which compiler built these kernels** — a tarball pin cannot.
- **igloo_driver** builds `igloo.ko` against the kernel *derivations* here, so
  a mismatched (kernel, module) pair is not expressible. Note that a nix-built
  `kernel-devel-all.tar.gz` is **not** usable from a non-nix container: it ships
  host tools linked against `/nix/store`.

## History: the Docker path

This repo used to build inside `rehosting/embedded-toolchains` via `build.sh`,
`_in_container_build.sh` and a `Dockerfile`, with the kernel source arriving as
two git submodules. All of that is removed; it lives in git history.

Comments throughout `nix/` name `_in_container_build.sh` where the Nix code is a
faithful port of a specific step in it. Those references are deliberate
provenance — they say *why* a piece of the build looks the way it does — and
point at the file as it existed before its removal.

Two things worth knowing about what that path did, because both were silent:

- Its toolchains were unversioned `wget musl.cc/*-cross.tgz` downloads, so
  **every kernel this repo has ever released has no recorded compiler
  identity.** kernelsmith exists to fix that.
- It hard-coded a hand-built `x86_64-legacy` toolchain for `(x86_64, 4.10)`
  alone, pinning binutils 2.30. The reason was never written down. It is that
  binutils ≥ 2.31 emits `R_X86_64_PLT32`, which Linux only learned in 4.16 —
  and that omission is exactly what shipped a dead kernel in `nixdev_0.1.0`.
  It is now a resolver decision in kernelsmith with the reason attached.
