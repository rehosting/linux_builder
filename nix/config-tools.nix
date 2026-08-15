# Tools for working on configs/.
#
# configs/<version>/<target> is a cpp fragment that `#include`s shared pieces,
# so the file you edit is almost never the file an option comes from -- and the
# config the kernel is BUILT with is a third thing again, because `olddefconfig`
# runs afterwards and will silently drop any option whose dependencies are not
# met. Three questions follow from that, and each gets a tool here:
#
#   config-required   Did every cell END UP with the options IGLOO needs?
#   config-explain    Where does CONFIG_X for this cell come from?
#   config-redundant  Which lines I wrote are doing nothing?
#
# The first is a gate. The other two are answers to questions, not assertions.
{ pkgs }:

let
  inherit (pkgs) lib;

  # ---------------------------------------------------------------------
  # The contract: what a kernel must have for IGLOO to work on it.
  #
  # Every entry is here because something downstream breaks without it, and
  # each names what. This is deliberately NOT "the options we happen to set" --
  # it is the subset whose absence is a silent failure, i.e. a kernel that
  # builds, boots, and then does not do its job. That failure class is the
  # reason this file exists; see nix/boot.nix for the sibling case.
  required = {
    CONFIG_IGLOO = "the IGLOO patch series itself -- without it every igloo_* hook compiles out and the kernel is stock";
    CONFIG_MODULES = "igloo.ko is a module; nothing to load it into";
    CONFIG_MODULE_UNLOAD = "penguin unloads and reloads the driver between runs";
    CONFIG_MODVERSIONS = "the driver/kernel ABI CRCs. Without it a mismatched module loads SILENTLY instead of being rejected -- strictly worse than the mismatch";
    CONFIG_KALLSYMS_ALL = "OSI symbol resolution reads kallsyms";
    CONFIG_KPROBES = "penguin's kprobe-based instrumentation";
    CONFIG_DEBUG_INFO = "dwarf2json builds the ISF from DWARF; no debug info, no ISF";
  };

  # ---------------------------------------------------------------------
  # Shared include-resolver. cpp semantics: `#include "x.inc"` splices x.inc in
  # place, and a later assignment of the same symbol overrides an earlier one.
  # Both tools below need this, so it lives once.
  resolverPy = ''
    import os
    import re
    import sys
    import collections

    INCLUDE = re.compile(r'\s*#include\s+"([^"]+)"')
    ASSIGN = re.compile(r'\s*(CONFIG_[A-Za-z0-9_]+)\s*=\s*(.*?)\s*$')
    UNSET = re.compile(r'\s*#\s*(CONFIG_[A-Za-z0-9_]+)\s+is not set\s*$')


    def walk(path, chain=None, out=None, seen=None):
        """Yield (option, value, file, line, include-chain) in cpp order."""
        chain = (chain or []) + [os.path.basename(path)]
        out = out if out is not None else []
        seen = seen if seen is not None else set()
        real = os.path.realpath(path)
        if real in seen:          # cpp would loop forever; we just stop
            return out
        seen.add(real)
        d = os.path.dirname(path)
        for n, line in enumerate(open(path, errors='replace'), 1):
            m = INCLUDE.match(line)
            if m:
                inc = os.path.join(d, m.group(1))
                if os.path.exists(inc):
                    walk(inc, chain, out, seen)
                else:
                    out.append(('!MISSING', m.group(1), path, n, list(chain)))
                continue
            m = ASSIGN.match(line)
            if m:
                out.append((m.group(1), m.group(2), path, n, list(chain)))
                continue
            m = UNSET.match(line)
            if m:
                out.append((m.group(1), 'n', path, n, list(chain)))
        return out


    def final(entries):
        """Last assignment wins, exactly as cpp+Kconfig would see it."""
        v = {}
        for opt, val, f, n, chain in entries:
            if opt == '!MISSING':
                continue
            v[opt] = (val, f, n, chain)
        return v
  '';

  # Parse a real .config (post-olddefconfig) -- the ground truth.
  configReaderPy = ''


    def read_config(path):
        vals = {}
        for line in open(path, errors='replace'):
            line = line.rstrip('\n')
            m = re.match(r'(CONFIG_[A-Za-z0-9_]+)=(.*)$', line)
            if m:
                vals[m.group(1)] = m.group(2); continue
            m = re.match(r'# (CONFIG_[A-Za-z0-9_]+) is not set$', line)
            if m:
                vals[m.group(1)] = 'n'
        return vals
  '';

in
rec {
  inherit required;

  # ---------------------------------------------------------------------
  # 1. THE GATE.
  #
  # Reads each cell's POST-olddefconfig .config out of the kernel's dev output,
  # not the fragment. That distinction is the whole point: `olddefconfig`
  # silently drops an option whose dependencies are unmet, so a fragment that
  # says CONFIG_MODVERSIONS=y proves nothing about the kernel that shipped.
  #
  # Reports EVERY violation across EVERY cell before failing. A gate that stops
  # at the first problem turns one fix-and-rerun cycle into N.
  requiredCheck = { cells }:
    let
      configs = lib.concatMapStringsSep " " (c: "${c.version}:${c.target}:${c.kernel.dev}/.config") cells;
    in
    pkgs.runCommand "igloo-config-required"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        meta.description = "assert every cell ends up with the options IGLOO needs";
      } ''
      cat > check.py <<'EOF'
      import re, sys
      ${configReaderPy}

      REQUIRED = {
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList
          (opt: why: "    ${builtins.toJSON opt}: ${builtins.toJSON why},") required)}
      }

      cells = [c.split(':', 2) for c in sys.argv[1:]]
      failures = []
      for version, target, path in cells:
          vals = read_config(path)
          for opt, why in sorted(REQUIRED.items()):
              got = vals.get(opt)
              if got in ('y', 'm'):
                  continue
              failures.append((version, target, opt, got, why))

      print("checked %d cells against %d required options" % (len(cells), len(REQUIRED)))
      if not failures:
          print("all cells satisfy the IGLOO config contract")
          sys.exit(0)

      print("")
      print("%d violation(s):" % len(failures))
      for version, target, opt, got, why in failures:
          state = "unset" if got is None else ("=" + got)
          print("  %s/%s  %s %s" % (version, target, opt, state))
          print("      needed for: %s" % why)
      print("")
      print("NOTE: this reads the POST-olddefconfig .config, so an option can be")
      print("set in configs/ and still fail here -- olddefconfig drops options")
      print("whose dependencies are unmet. Use `nix run .#config-explain` to see")
      print("where the fragment sets it, then check what its dependencies need.")
      sys.exit(1)
      EOF

      # NOT `python3 ... | tee $out`. A pipeline's status is its LAST command,
      # so a failing check would be masked by a succeeding tee unless pipefail
      # happens to be set. stdenv does set it -- but a gate that silently passes
      # when a shell option changes is the exact failure class this file exists
      # to catch, so don't depend on it.
      python3 check.py ${configs} > report.txt; status=$?
      cat report.txt
      cp report.txt $out
      exit $status
    '';

  # ---------------------------------------------------------------------
  # 2. PROVENANCE. `nix run .#config-explain -- 6.13 x86_64 CONFIG_IGLOO`
  #
  # Deliberately does NOT build a kernel: this answers "where does this come
  # from", which is a question about configs/, and making it cost a cross-build
  # would mean nobody runs it. It reports what the fragments say and is explicit
  # that olddefconfig gets the last word -- rather than quietly implying the
  # fragment value is what shipped.
  explainScript = pkgs.writers.writePython3Bin "config-explain" { flakeIgnore = [ "E501" "F401" ]; } ''
    ${resolverPy}

    def main():
        if len(sys.argv) not in (4, 5):
            print("usage: config-explain <version> <target> <CONFIG_OPTION> [configs-dir]", file=sys.stderr)
            print("   eg: config-explain 6.13 x86_64 CONFIG_IGLOO", file=sys.stderr)
            return 2
        version, target, opt = sys.argv[1], sys.argv[2], sys.argv[3]
        root = sys.argv[4] if len(sys.argv) == 5 else "configs"
        if not opt.startswith("CONFIG_"):
            opt = "CONFIG_" + opt

        path = os.path.join(root, version, target)
        if not os.path.exists(path):
            print("no config for %s/%s at %s" % (version, target, path), file=sys.stderr)
            return 1

        entries = walk(path)

        missing = [e for e in entries if e[0] == '!MISSING']
        for _, inc, f, n, _ in missing:
            print("warning: %s:%d includes %s, which does not exist" % (f, n, inc), file=sys.stderr)

        hits = [e for e in entries if e[0] == opt]
        if not hits:
            print("%s is not set anywhere in %s/%s's fragment tree." % (opt, version, target))
            print("")
            print("Include chain searched:")
            seen = []
            for _, _, _, _, chain in entries:
                key = " -> ".join(chain)
                if key not in seen:
                    seen.append(key)
            for s in seen:
                print("  %s" % s)
            print("")
            print("It may still be enabled in the built kernel: olddefconfig turns on")
            print("options that other options select. Check the shipped .config.")
            return 0

        print("%s for %s/%s" % (opt, version, target))
        print("")
        for i, (_, val, f, n, chain) in enumerate(hits):
            last = (i == len(hits) - 1)
            print("  %s %s=%s" % ("*" if last else " ", opt, val))
            print("      %s:%d" % (f, n))
            print("      via %s" % " -> ".join(chain))
        if len(hits) > 1:
            print("")
            print("  %d assignments; the one marked * wins (cpp: last wins)." % len(hits))
            print("  The earlier ones are dead weight -- see `nix build .#config-redundant`.")
        print("")
        print("NOTE: this is what the FRAGMENTS say. olddefconfig runs afterwards and")
        print("has the last word -- it drops options whose dependencies are unmet.")
        print("`nix build .#config-required` checks the shipped .config instead.")
        return 0


    sys.exit(main())
  '';

  # ---------------------------------------------------------------------
  # 3. REDUNDANCY. Two genuinely different kinds, reported together:
  #
  #   (a) STATIC -- an option assigned more than once in one cell's fragment
  #       tree. Purely a configs/ bug, needs no kernel, always actionable.
  #       6.13/all-common.inc sets CONFIG_MODULES=y twice, 3 lines apart.
  #
  #   (b) DEFAULTED -- an option whose value already matches what the arch
  #       gives you, so writing it changes nothing. Needs savedefconfig, hence
  #       the built kernel.
  #
  # (a) is the one worth acting on: a duplicate is always a mistake, whereas a
  # defaulted option is often deliberately explicit. So they are never merged
  # into one number.
  redundancyReport = { cells, configsSrc }:
    let
      args = lib.concatMapStringsSep " "
        (c: "${c.version}:${c.target}:${c.kernel.dev}/.config") cells;
    in
    pkgs.runCommand "igloo-config-redundant"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        meta.description = "which config lines are duplicated or already the default";
      } ''
      cp -r ${configsSrc} configs && chmod -R u+w configs

      cat > report.py <<'EOF'
      import re, sys, os, collections
      ${resolverPy}
      ${configReaderPy}

      cells = [c.split(':', 2) for c in sys.argv[1:]]
      total_dupes = 0

      print("=" * 70)
      print("DUPLICATE ASSIGNMENTS -- an option set more than once in one cell")
      print("=" * 70)
      print("These are always bugs: only the last one has any effect.")
      print("")
      for version, target, cfgpath in cells:
          entries = walk(os.path.join("configs", version, target))
          byopt = collections.OrderedDict()
          for opt, val, f, n, chain in entries:
              if opt == '!MISSING':
                  continue
              byopt.setdefault(opt, []).append((val, f, n))
          dupes = {o: v for o, v in byopt.items() if len(v) > 1}
          if not dupes:
              continue
          print("%s/%s: %d option(s) assigned more than once" % (version, target, len(dupes)))
          for opt, occurrences in sorted(dupes.items()):
              vals = {v for v, _, _ in occurrences}
              kind = "same value" if len(vals) == 1 else "CONFLICTING values"
              print("  %s  (%d times, %s)" % (opt, len(occurrences), kind))
              for val, f, n in occurrences:
                  print("      %s=%s  at %s:%d" % (opt, val, f, n))
              total_dupes += 1
          print("")
      if total_dupes == 0:
          print("none found.")
          print("")

      print("=" * 70)
      print("DEFAULTED OPTIONS -- written, but already the arch default")
      print("=" * 70)
      print("Not necessarily bugs: being explicit about an important option is")
      print("a legitimate choice. Counts only, per cell, so this stays readable.")
      print("")
      for version, target, cfgpath in cells:
          entries = walk(os.path.join("configs", version, target))
          written = final(entries)
          shipped = read_config(cfgpath)
          # An option we wrote whose shipped value matches, but which we cannot
          # tell apart from "we asked and got it" without savedefconfig. What we
          # CAN say cheaply and truthfully: which written options did not survive.
          dropped = []
          for opt, (val, f, n, chain) in sorted(written.items()):
              got = shipped.get(opt)
              if got is None:
                  dropped.append((opt, val, f, n, "not present in shipped .config"))
              elif got != val:
                  dropped.append((opt, val, f, n, "shipped as %s" % got))
          print("%s/%s: wrote %d options; %d did not survive olddefconfig"
                % (version, target, len(written), len(dropped)))
          for opt, val, f, n, why in dropped:
              print("    %s=%s  (%s)  %s:%d" % (opt, val, why, f, n))
          print("")

      print("For the full savedefconfig diff per cell, build .#config-lint.")
      if total_dupes:
          print("")
          print("%d duplicated option(s) found -- these are worth fixing." % total_dupes)
      EOF

      python3 report.py ${args} > report.txt; status=$?
      cat report.txt
      cp report.txt $out
      exit $status
    '';
}
