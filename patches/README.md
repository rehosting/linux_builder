# The IGLOO kernel patch series

The IGLOO kernel delta, carried as an explicit patch series applied to pristine
upstream release tarballs — replacing the two long-lived fork branches of
`rehosting/linux` that used to arrive as git submodules.

## Layout

```
base.json            upstream base tag + tarball hash per version
core/                patches byte-identical across every version (5)
4.10/  6.13/         per-version patches + the `series` file
```

Each `series` file lists patch paths relative to `patches/`, in apply order, so
core patches and version-specific ones interleave where the ordering requires.
Blank lines and `#` comments are ignored (quilt convention).

| version | base | patches | of which shared |
|---|---|---|---|
| 4.10 | `v4.10` | 38 | 5 |
| 6.13 | `v6.13` | 33 | 5 |

## How much is really shared — read this before assuming

Of the 23 patches that carry the **same subject** in both versions, only **5 are
byte-identical**. Those 5 are precisely the ones that add *new files*
(`include/hypercall.h`, `include/igloo.h`, `include/igloo_syscall_macros.h`).
Every patch that modifies existing kernel code differs between 4.10 and 6.13,
because the surrounding code differs.

So the series does **not** collapse the two versions into one maintained copy.
What it does deliver:

- **Additive work is written once.** New files under `drivers/igloobase/` and
  `include/` go in `core/` and apply to every version — this is the class that
  igloo_driver #918 falls into.
- **Hook-site work stays per-version**, as it must; it is now visibly per-version
  instead of silently duplicated across two branches.
- The old failure mode — fixing a bug on one branch and forgetting the other —
  becomes a visible diff between two series rather than an invisible omission.
  (It happened: the same fix shipped as PR #29 on 4.10 and #30 on 6.13.)

## Two things the migration uncovered

**The 6.13 fork was not based on a release.** `main_6.13` branched five commits
before `v6.13` and then cherry-picked four of them back — `x86: Disable
EXECMEM_ROX support`, `x86/fred: …`, `x86/asm: Make serialize() always_inline`,
and the `Linux 6.13` version commit. All four are upstream, so basing on the
`v6.13` tarball reproduces the same tree with none of them carried locally.

**`.gitmodules` named the wrong branches.** It declared `branch = main_6.7` for
`linux/6.13` while the pin was actually the head of `main_6.13` — trees 89,775
commits apart. `git submodule update --remote` would have silently regressed the
kernel. Basing on a tag makes that class of drift unrepresentable.

## Working on the kernel

```bash
./scripts/import-series.sh 6.13 /tmp/k613     # tarball + series -> a git tree
cd /tmp/k613 && git commit ...                # develop normally
./scripts/export-series.sh 6.13 /tmp/k613     # write the series back
./scripts/verify-series.sh 6.13 <tarball> refs/remotes/origin/main_6.13 <clone>
```

`verify-series.sh` is the gate: it applies the series to the pristine tarball and
asserts the result matches the fork branch. Note release tarballs are `git
archive` output and honour `export-ignore`, so they legitimately lack
`.gitattributes`, `.get_maintainer.ignore`, and two `arch/sh` linker scripts —
the check allows exactly those paths and fails on anything else.
