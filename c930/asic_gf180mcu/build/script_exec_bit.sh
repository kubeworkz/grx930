#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# script_exec_bit.sh [REPO] [--fix]
#
# The exec-bit gate: every shell script tracked in this repository must be mode
# 100755 in the index.
#
# WHY THE MODE IS WORTH A GATE
#
#   A .sh here is named directly -- `./run_cache_index_alias.sh` in its own usage
#   line, `./run_v8.sh` in the notes -- and read by an interpreter -- `bash
#   build/chip_gates.sh`, `sh wafer_space_integration/run_adapter_lint.sh`. Only
#   the first of those needs the exec bit, and only on Linux does it need it: the
#   index says 100644, a checkout gives a file with no exec bit, and the shell
#   answers "Permission denied". This box cannot see that, twice over. Its git
#   runs with core.filemode=false, so the working-tree bit is not tracked here and
#   `chmod +x` is not what gets recorded; and MSYS reads the bit off the file's own
#   `#!` line rather than off the mode, so ./run_x.sh runs here whatever the index
#   says (measured: a 100644 script and a 100755 script both show -rwxr-xr-x,
#   while a file with no shebang does not). The mistake is therefore invisible
#   where the scripts are written and fatal where they run -- which is what a gate
#   is for.
#
#   The repo has already paid for this class once. The three cache gates were
#   100644 in the index, CI failed at `./run_cache_index_alias.sh: Permission
#   denied` (exit 126, three steps wide) on the revision before the fix, and the
#   fix was to name the interpreter in the gate table. That fix stays -- naming
#   `bash` is more robust than depending on a mode -- but it protected those three
#   scripts only. The next `./x.sh` a person types, or writes into a chain, would
#   discover its own mode the same way. This gate checks the class instead of the
#   instance.
#
# WHY THE INDEX, AND NOT THE WORKING TREE
#
#   The index is what a checkout materializes: a clone on Linux gets an executable
#   file only because the index, and then the commit, says 100755. So the index is
#   the truth about "will this run where the flows run". It is also the one thing
#   that can be fixed from Windows: registering the entry's own blob with mode
#   100755 needs no Unix filesystem, while `chmod +x` on this box records nothing
#   at all. --fix does both, so the local copy is executable for whoever runs it
#   here and the committed mode is the one CI and the flow box materialize. Only
#   the mode moves: the content stays whatever the index already had, because a
#   fixer that stages an unstaged edit is worse than the fault it repairs.
#
# WHAT COUNTS AS A SHELL SCRIPT: TWO ARMS
#
#   * name arm: the path ends in .sh or .bash. It needs no file content, so it
#     holds even where the file is not in the working tree.
#   * content arm: otherwise, the file's FIRST LINE names a shell. This is the arm
#     that catches .githooks/pre-push, which is a bash script with no extension.
#
#   First line, not any line, and that is not fussiness: this repo's own fixtures
#   put shebangs inside heredocs -- build/gate_selftest.sh writes four stub scripts
#   in the middle of itself, three of them starting with `#!` -- so a search that
#   did not anchor to line 1 would call a file a shell script on the strength of a
#   line inside it. The candidate set is therefore deliberately over-broad (one
#   `git grep` over the index for a `#!` at the start of any line) and the
#   decision is made by reading line 1.
#
# THE INTERPRETER LIST, AND THE BOUNDARY
#
#   sh bash dash ash ksh mksh zsh, as an absolute path or through `env`. The name
#   has to stand alone -- preceded by `/` or whitespace, followed by whitespace or
#   the end of the line -- which is why `python3`, `node`, `perl` and the word
#   "shell" in a trailing comment do not match.
#
#   Python and the rest are NOT covered, on purpose. They are scripts with
#   shebangs, but a `python3` shebang is not evidence that the file is ever named
#   directly: tools/gen_bootrom.py is imported by its own selftest, and ~40 more
#   like it are delivered or imported rather than run. Extending the rule to them
#   would change ~40 more entries and is a decision about the repo's conventions,
#   not a defect this gate found. Arm [E] holds the boundary open by checking both
#   sides of it (.githooks/pre-push is in, c930/sw/bin2hex.py is out).
#
# THE ENVIRONMENT THIS RUNS IN
#
#   Git exports GIT_DIR to hooks, and GIT_DIR outranks -C: `git -C X ...` then
#   runs in X but against GIT_DIR's repository. In a plain checkout that is this
#   repo and the difference is invisible; in a linked worktree it is the
#   worktree's own gitdir, and then the difference between "which repository" and
#   "where the command runs" is the difference between the throwaway fixture and
#   the repository being pushed. This file is the only one here that both builds
#   git repositories and runs from the pre-push hook, so it is the only one that
#   can damage a repository that way. It did, once: on 2026-10-14 a hook-run
#   fixture wrote nine of its entries into the index of the worktree being pushed
#   and turned the real repository's core.bare on. Every git call below goes
#   through the `git` function defined at the top of the code, which removes
#   those variables before git sees them, and arm [E] keeps it that way.
#
# THE ARMS: THE GATE TESTS ITSELF FIRST
#
#   A gate whose matching is dead reports no violations, and "no violations" is
#   what a passing gate says -- so its verdict cannot be the evidence that it
#   works. Each arm below is a fixture with a known answer and runs before the
#   repo is audited; one arm failing fails the run whatever the repo looks like:
#
#   [A] the interpreter pattern, accept and reject, line by line: `env -S bash -e`
#       and `busybox sh` are shells; python3, node, perl, fish, a comment and an
#       empty line are not
#   [B] line 1 is what is read, and only line 1: a shebang on line 2 is not a
#       shell script, a 900-byte first line is read bounded (never a whole file
#       into a variable) and not claimed as one, and a file with no trailing
#       newline still reads
#   [C] end to end in a throwaway repository whose index has a known answer: the
#       audit must FAIL and name exactly seven violations -- by name, by .bash, by
#       first line, by a path with a space, and by files with no trailing newline
#       and with an unstaged edit -- while a 100755 script, a python script and a
#       file whose shebang is on line 2 are not violations, and a symlink and a
#       gitlink are counted and skipped; then --fix turns exactly those seven into
#       100755 in the index, in the working tree and in a commit, leaving the
#       unstaged edit unstaged and the skip-worktree flag in place, and the same
#       audit then passes
#   [D] this repo's real index: the content arm finds .githooks/pre-push (bash, no
#       extension) and does not claim c930/sw/bin2hex.py
#   [E] the environment cannot redirect the fixture: with GIT_DIR exported the way
#       git exports it to a hook in a linked worktree, the arm-C fixture still
#       builds in its own directory, and a stand-in repository with a linked
#       worktree -- the shape of the repo a push comes from -- comes out of it
#       with its index unchanged and still not bare
#
# WHAT THIS GATE DOES NOT PROVE
#
#   That a script works, or that anything calls it. It answers one question: what
#   mode will a Linux checkout give this tracked shell script. It reads the index,
#   so an untracked x.sh is out of scope by design -- nothing has been committed
#   to be executable yet.
#
# USAGE
#
#   bash c930/asic_gf180mcu/build/script_exec_bit.sh               # this repo
#   bash c930/asic_gf180mcu/build/script_exec_bit.sh --fix          # and fix it
#   bash c930/asic_gf180mcu/build/script_exec_bit.sh /path/to/repo   # another one
#
#   The repo audited defaults to the one this file lives in, not to the current
#   directory: which repo gets checked should not depend on where a person happens
#   to be standing.
#
# EXIT STATUS
#
#   0 only when every arm holds and the audited repo has no violation. 2 is a
#   usage error (unknown flag, two repos, not a git repository): a run that could
#   not check must not read as a run that checked and found nothing.
set -u

# ---------------------------------------------------------------------------
# the environment this runs in, before anything else
# ---------------------------------------------------------------------------

# Git exports GIT_DIR (and friends) to hooks, and GIT_DIR outranks -C: a command
# spelled `git -C "$d" ...` runs in $d's working directory but against GIT_DIR's
# repository. That is invisible in a plain checkout, where the inherited GIT_DIR
# IS this repo, and wrong in a linked worktree, where it is the worktree's own
# gitdir and the audit then reads -- and the fixture writes -- the repo being
# pushed instead of the throwaway one.
#
# This gate is the one file here that both builds git repositories and runs from
# the pre-push hook, so it is the one that can do that damage. It did, on
# 2026-10-14: a hook-run fixture wrote nine of its entries into the index of the
# worktree being pushed, left one behind (hidden by the skip-worktree flag the
# fixture itself sets), and turned the real repo's core.bare on, because
# `git init` obeys GIT_DIR too. Arm [E] is the regression test for exactly this.
#
# `git` below is therefore not git: it is git with the variables that can point
# it at another repository removed. Unsetting beats neutralizing -- there is no
# value of GIT_DIR that means "no, really, use -C". GIT_CONFIG_* are cleared for
# a smaller reason: the fixture pins the identity, branch and autocrlf it needs
# per call, and an ambient GIT_CONFIG_COUNT would be a way for a surrounding
# environment to change what the fixture commits. GIT_CEILING_DIRECTORIES is
# kept -- it only bounds discovery upward and cannot redirect it.
#
git() {
  # `env ... git`, not `command git`: env resolves the name itself and cannot see
  # a shell function, so the lookup finds the real git and cannot come back here.
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
      -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE \
      -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
      git "$@"
}

# ---------------------------------------------------------------------------
# the rule
# ---------------------------------------------------------------------------

# A shebang line naming a shell: `#!`, anything, then the interpreter preceded by
# a character that cannot be part of its name (`/` for a path, whitespace for
# `env`) and followed by whitespace or the end of the line. POSIX ERE has no \b,
# hence the character class. `python3`, `node` and `perl` cannot match: no shell
# name is a word in them.
RE_SHELL='^#!.*[^[:alnum:]_.+-](sh|bash|dash|ash|ksh|mksh|zsh)([[:space:]]|$)'

is_shell_line() {   # $1 = a first line -> 0 when it names a shell
  [[ $1 =~ $RE_SHELL ]]
}

is_shell_name() {   # $1 = path in the index -> 0 when the extension alone decides
  case "$1" in
    *.sh|*.bash) return 0 ;;
    *) return 1 ;;
  esac
}

# FIRST_LINE is set by first_line() rather than printed, so that the audit does
# not fork a subshell per file: this runs over every tracked file that has a
# shebang anywhere in the index (~127 of them at the time of writing) and, on
# Windows, a fork is not cheap.
FIRST_LINE=""
first_line() {      # $1 = repo root, $2 = path within it
  local f="$1/$2" line=""
  if [ -f "$f" ]; then
    # Bounded on purpose: a tracked binary can go megabytes without a newline,
    # and an unbounded `read` would pull all of it into a shell variable.
    IFS= read -r -n 400 line < "$f" 2>/dev/null || true
    line=${line%%$'\n'*}
  elif git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
    # Not in the working tree -- a partial or filtered checkout. The index still
    # has the content, so the line comes from there.
    line=$(git -C "$1" show ":$2" 2>/dev/null | head -1 || true)
  fi
  FIRST_LINE=$line
}

index_modes() {     # $1 = repo -> "mode<TAB>path" for every tracked entry
  # -z, then tab, then the path whole: a tracked path can contain a space
  # (`Claude outputs/...`) and the listing must not split it.
  git -C "$1" ls-files -s -z 2>/dev/null | tr '\0' '\n' |
    awk '{ if (match($0, /^[0-7]+ [0-9a-f]+ [0-9]+\t/)) print substr($0, 1, 6) "\t" substr($0, RLENGTH + 1) }'
}

shebang_paths() {   # $1 = repo -> tracked paths whose FIRST line names a shell
  local p
  # `^#!` anywhere is a filter, nothing more: it comes from the index (blobs, so
  # no CRLF translation and no working-tree dependency) and it is over-broad by
  # design. Whether the file IS a shell script is decided on its first line.
  git -C "$1" grep --cached -I -l -E '^#!' 2>/dev/null | while IFS= read -r p; do
    [ -n "$p" ] || continue
    first_line "$1" "$p"
    is_shell_line "$FIRST_LINE" && printf '%s\n' "$p"
  done
}

# ---------------------------------------------------------------------------
# the audit
# ---------------------------------------------------------------------------

# AUDIT_VIOLATIONS is the output that matters -- the paths, not a count of them --
# and it is a global so that --fix can hand exactly the audited set to the fixer
# instead of re-deriving the rule from the report text. audit() runs in the
# current shell (its caller redirects to a file, never a pipe) so the array
# survives.
AUDIT_VIOLATIONS=()
AUDIT_SKIPPED=0
audit() {           # $1 = repo -> the report; rc 0 clean, 1 with violations
  local repo=$1 mode path
  local content_only="" skipped_lines="" violation_lines=""
  local entries=0 regular=0 executable=0 checked=0 by_name=0 ok=0 viol=0
  local -A content=()

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    content[$path]=1
    is_shell_name "$path" || content_only="$content_only"$'\n    '"$path"
  done < <(shebang_paths "$repo")

  AUDIT_VIOLATIONS=()
  AUDIT_SKIPPED=0
  while IFS=$'\t' read -r mode path; do
    entries=$((entries + 1))
    case "$mode" in
      100644|100755) ;;
      # A symlink (120000) or a gitlink (160000) has no exec bit to be wrong
      # about. Counted and named, never failed -- the lockstep gate's counted
      # SKIP, for the same reason: silently skipping is how a gate stops
      # covering what its name says.
      *) AUDIT_SKIPPED=$((AUDIT_SKIPPED + 1))
         skipped_lines="$skipped_lines"$'\n'"SKIP      $mode $path (not a regular file)" ; continue ;;
    esac
    regular=$((regular + 1))
    [ "$mode" = 100755 ] && executable=$((executable + 1))
    if is_shell_name "$path" || [ -n "${content[$path]:-}" ]; then
      checked=$((checked + 1))
      is_shell_name "$path" && by_name=$((by_name + 1))
      if [ "$mode" = 100755 ]; then
        ok=$((ok + 1))
      else
        viol=$((viol + 1))
        AUDIT_VIOLATIONS+=( "$path" )
        violation_lines="$violation_lines"$'\n'"VIOLATION $mode $path"
      fi
    fi
  done < <(index_modes "$repo")

  printf 'REPO      %s\n' "$repo"
  printf 'INDEX     %s tracked entr%s: %s regular file(s), %s at 100755\n' \
    "$entries" "$([ "$entries" = 1 ] && echo y || echo ies)" "$regular" "$executable"
  printf 'SHELL     %s tracked shell script(s) checked: %s by name (.sh/.bash), %s only by their first line%s\n' \
    "$checked" "$by_name" "$((checked - by_name))" \
    "$([ "$((checked - by_name))" -eq 0 ] && echo '' || printf ':%s' "$content_only")"
  printf 'RESULT    OK %s  VIOLATION %s  SKIP %s\n' "$ok" "$viol" "$AUDIT_SKIPPED"
  [ -n "$violation_lines" ] && printf '%s\n' "${violation_lines#$'\n'}"
  [ -n "$skipped_lines" ] && printf '%s\n' "${skipped_lines#$'\n'}"

  [ "$viol" -eq 0 ]
}

fix_repo() {        # $1 = repo; paths to fix, one per line, on stdin
  local repo=$1 path sha flag why fixed=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # --cacheinfo, and the sha is the index's own: this changes the mode of the
    # entry and nothing else. The obvious spelling, --chmod=+x, is wrong twice
    # over -- it stats and re-hashes the path from the working tree, so it stages
    # whatever content is sitting there (on the first run against this repo it
    # staged three files' unstaged edits, which is the kind of thing a gate must
    # never do), and it refuses outright when the entry has no working-tree copy,
    # which is a partial checkout and every entry of the fixture the arms build.
    sha=$(git -C "$repo" ls-files -s -- "$path" 2>/dev/null | awk '{print $2}' | head -1)
    flag=$(git -C "$repo" ls-files -v -- "$path" 2>/dev/null | cut -c1)
    if [ -z "$sha" ]; then
      printf 'FIXFAIL   %s: not in the index\n' "$path"
      continue
    fi
    if why=$(git -C "$repo" update-index --cacheinfo "100755,$sha,$path" 2>&1); then
      # --cacheinfo does not carry the entry's flags, and a sparse checkout's
      # entries carry skip-worktree: dropping it would leave a checkout expecting
      # a file it deliberately does not have, so it goes back on.
      case "$flag" in
        S)     git -C "$repo" update-index --skip-worktree -- "$path" ;;
        [a-z]) git -C "$repo" update-index --assume-unchanged -- "$path" ;;
      esac
      # The working-tree copy is chmod'ed as well: on a Linux working tree the
      # index change alone leaves the file unrunnable until the next checkout, and
      # being told a script is fixed while ./x.sh still answers Permission denied
      # is the confusion this gate exists to end. On Windows it changes nothing
      # the question can see (MSYS reads the `#!` line), which costs one no-op.
      chmod +x -- "$repo/$path" 2>/dev/null || true
      printf 'FIXED     %s (index now 100755)\n' "$path"
      fixed=$((fixed + 1))
    else
      printf 'FIXFAIL   %s: %s\n' "$path" "$(printf '%s' "$why" | head -1)"
    fi
  done
  # Named, not silent: the mode lives in the index until it is committed, and a
  # fix that is never committed is a fix that CI will not see.
  printf 'FIXED     %s path(s) -- the mode is in the index; it needs to be committed\n' "$fixed"
}

# ---------------------------------------------------------------------------
# the arms
# ---------------------------------------------------------------------------
arm_pass=0
arm_fail=0
ok()  { arm_pass=$((arm_pass + 1)); printf '[%s] PASS %s\n' "$1" "$2"; }
bad() { arm_fail=$((arm_fail + 1)); printf '[%s] FAIL %s\n' "$1" "$2"; }
chk() { if [ "$3" = "$4" ]; then ok "$1" "$2 (= $4)"; else bad "$1" "$2: expected [$3] got [$4]"; fi; }

arm_a() {           # the interpreter pattern, line by line
  local spec tag line
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    tag=${spec%%|*}
    line=${spec#*|}
    if [ "$tag" = shell ]; then
      if is_shell_line "$line"; then ok A "shell:     $line"
      else bad A "shell not recognised: $line"; fi
    else
      if is_shell_line "$line"; then bad A "not a shell, claimed as one: $line"
      else ok A "not shell: $line"; fi
    fi
  done <<'EOF'
shell|#!/bin/sh
shell|#!/bin/bash
shell|#!/bin/bash -e
shell|#!/usr/bin/env bash
shell|#!/usr/bin/env sh
shell|#!/bin/dash
shell|#!/bin/ash
shell|#!/bin/ksh
shell|#!/bin/busybox sh
shell|#!/usr/bin/env -S bash -e
other|#!/usr/bin/env python3
other|#!/usr/bin/env python
other|#!/usr/bin/env node
other|#!/usr/bin/env perl
other|#!/usr/bin/env fish
other|# a comment that mentions shell
other|
EOF
}

arm_b() {           # line 1 is what is read, and only line 1
  local d=$1
  mkdir -p "$d" || { bad B "cannot create $d"; return; }
  printf '#!/usr/bin/env bash' > "$d/no-newline"
  printf '# a comment\n#!/bin/sh\n' > "$d/line-two"
  printf '#!%s\n' "$(printf 'z%.0s' $(seq 1 900))" > "$d/long-line"
  printf '#!/bin/sh\n' > "$d/normal"

  first_line "$d" normal
  if is_shell_line "$FIRST_LINE"; then ok B "line 1 read: $FIRST_LINE"; else bad B "line 1 of a shebang file did not read as one"; fi

  first_line "$d" no-newline
  if is_shell_line "$FIRST_LINE"; then ok B "no trailing newline still reads ($FIRST_LINE)"; else bad B "a shebang line with no trailing newline was not recognised"; fi

  first_line "$d" line-two
  if is_shell_line "$FIRST_LINE"; then bad B "a shebang on line 2 was read as line 1 ($FIRST_LINE)"; else ok B "a shebang on line 2 is not line 1"; fi

  first_line "$d" long-line
  if [ "${#FIRST_LINE}" -le 400 ]; then ok B "a 900-byte first line is read bounded (${#FIRST_LINE} bytes)";
  else bad B "the read was not bounded: ${#FIRST_LINE} bytes of a 902-byte file"; fi
  if is_shell_line "$FIRST_LINE"; then bad B "a 900-byte line of z was claimed as a shell shebang"; else ok B "and it is not claimed as a shell shebang"; fi

  first_line "$d" not-here
  chk B "a path in neither the tree nor the index yields no line" "" "$FIRST_LINE"
}

# A repository whose index says exactly what the answer should be, built with
# --cacheinfo so that modes, blobs, a symlink and a gitlink exist without any of
# them having to be a file on this filesystem.
fixture_repo() {    # $1 = a path to build in
  local d=$1 sha
  mkdir -p "$d" || return 1
  # -C as well as the function: the function strips the inherited variables, and
  # -C then says which directory init is about, so neither alone is load-bearing.
  # Without the function this line re-inits whatever GIT_DIR names -- the real
  # repo, when a hook runs the arms -- and `git init` sets core.bare on it.
  git -C "$d" -c init.defaultBranch=main init -q || return 1

  sha=$(printf '#!/usr/bin/env bash\necho hi\n' | git -C "$d" hash-object -w --stdin)
  git -C "$d" update-index --add --cacheinfo "100644,$sha,tools/no-extension" || return 1
  # As a sparse checkout of this repo would carry it: in the index, not on disk,
  # and flagged. --cacheinfo does not keep that flag, so the fixer has to.
  git -C "$d" update-index --skip-worktree -- tools/no-extension || return 1

  sha=$(printf '#!/usr/bin/env python3\n' | git -C "$d" hash-object -w --stdin)
  git -C "$d" update-index --add --cacheinfo "100644,$sha,tools/tool.py" || return 1

  sha=$(printf '# a comment\n#!/bin/sh\n' | git -C "$d" hash-object -w --stdin)
  git -C "$d" update-index --add --cacheinfo "100644,$sha,tools/second-line" || return 1

  sha=$(printf 'echo not a shell script\n' | git -C "$d" hash-object -w --stdin)
  git -C "$d" update-index --add --cacheinfo "100644,$sha,docs/extension-only.sh" || return 1
  git -C "$d" update-index --add --cacheinfo "100755,$sha,docs/already-good.sh" || return 1
  git -C "$d" update-index --add --cacheinfo "100644,$sha,docs/with a space.sh" || return 1
  git -C "$d" update-index --add --cacheinfo "100644,$sha,docs/other.bash" || return 1

  sha=$(printf 'target-of-a-symlink\n' | git -C "$d" hash-object -w --stdin)
  git -C "$d" update-index --add --cacheinfo "120000,$sha,link.sh" || return 1
  # A gitlink's sha is an arbitrary commit id: git refuses an all-zero one
  # (null sha1), and a real submodule commit may not exist in this object store.
  git -C "$d" update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,sub" || return 1

  # Real files, so that the working-tree read is the path under test here and the
  # index fallback is not the only one ever exercised.
  mkdir -p "$d/tree" || return 1
  printf '#!/bin/sh' > "$d/tree/no-newline"
  printf '#!/bin/sh\necho ok\n' > "$d/tree/normal.sh"
  printf '#!/bin/sh\necho v1\n' > "$d/tree/edited.sh"
  # core.autocrlf=false so the fixture's content is the fixture's content on any
  # machine, whatever the clone that runs this gate has configured globally.
  git -C "$d" -c core.autocrlf=false add tree/no-newline tree/normal.sh tree/edited.sh || return 1
  # Committed, then edited in the working tree and left unstaged: the state a
  # fixer must not disturb, and the one --chmod=+x did disturb.
  git -C "$d" -c core.autocrlf=false -c user.email=gate@example.invalid -c user.name=gate \
    -c commit.gpgsign=false commit -qm "fixture: base" || return 1
  printf '#!/bin/sh\necho v2 (an unstaged edit)\n' > "$d/tree/edited.sh"
  return 0
}

arm_c() {           # the fixture, audited, fixed, and audited again
  local d=$1 want got rc line modes
  fixture_repo "$d" || { bad C "could not build the fixture repository"; return; }

  want="docs/extension-only.sh
docs/other.bash
docs/with a space.sh
tools/no-extension
tree/edited.sh
tree/no-newline
tree/normal.sh"

  audit "$d" > "$d/audit-before.log"; rc=$?
  chk C "the audit fails when a mode is wrong" 1 "$rc"

  got=$(printf '%s\n' "${AUDIT_VIOLATIONS[@]+"${AUDIT_VIOLATIONS[@]}"}" | sort)
  if [ "$got" = "$want" ]; then ok C "exactly the seven expected violations, by name, .bash, first line, space and no-newline"
  else bad C "the violation set is wrong"; printf '      expected: %s\n      got:      %s\n' "$(printf '%s' "$want" | tr '\n' ' ')" "$(printf '%s' "$got" | tr '\n' ' ')"; fi

  chk C "non-regular entries (symlink 120000, gitlink 160000) are counted, not failed" 2 "$AUDIT_SKIPPED"
  chk C "and named in the log" 2 "$(grep -c '^SKIP' "$d/audit-before.log")"

  # The rules that must NOT fire: a 100755 script, a python script, a file whose
  # shebang is on line 2. If the policy were inverted or the content arm
  # over-eager, one of these would appear above -- this says so out loud.
  for line in docs/already-good.sh tools/tool.py tools/second-line; do
    if printf '%s\n' "$got" | grep -qxF "$line"; then bad C "$line was reported as a violation"
    else ok C "$line is not a violation"; fi
  done

  printf '%s\n' "${AUDIT_VIOLATIONS[@]+"${AUDIT_VIOLATIONS[@]}"}" | fix_repo "$d" > "$d/fix.log"
  chk C "one FIXED line per violation, and none refused" 7 "$(grep -c '^FIXED     .*index now 100755' "$d/fix.log")"
  if grep -q '^FIXFAIL' "$d/fix.log"; then bad C "a fix was refused: $(grep '^FIXFAIL' "$d/fix.log" | head -1)"; else ok C "no fix refused"; fi

  audit "$d" > "$d/audit-after.log"; rc=$?
  chk C "the same audit passes once the modes are right" 0 "$rc"
  chk C "violations left after the fix" 0 "$(grep -c '^VIOLATION' "$d/audit-after.log")"

  # Only the shell scripts moved: the python script and the line-2 file must still
  # be 100644, or the fixer is chmod'ing by accident rather than by rule.
  # Split on the tab, never on whitespace: one of these paths has a space in it,
  # which is the whole reason the gate parses `ls-files -s` the long way.
  modes=$(git -C "$d" ls-files -s)
  chk C "a path with a space survives the fixer" "100755" "$(printf '%s\n' "$modes" | awk -F'\t' '$2 == "docs/with a space.sh" {print substr($1, 1, 6)}')"
  chk C "the fixer leaves an out-of-scope file alone: tools/tool.py" "100644" "$(printf '%s\n' "$modes" | awk -F'\t' '$2 == "tools/tool.py" {print substr($1, 1, 6)}')"
  chk C "nor the file whose shebang is on line 2: tools/second-line" "100644" "$(printf '%s\n' "$modes" | awk -F'\t' '$2 == "tools/second-line" {print substr($1, 1, 6)}')"
  # On Linux this is the check that chmod ran. On this box it cannot be: MSYS
  # decides from the `#!` line, so a script reads executable whatever its mode is
  # -- which is the same fact that makes the fault this gate hunts invisible here.
  chk C "the working-tree copy is executable (the real check on Linux; unconvincing on MSYS)" "yes" \
    "$([ -x "$d/tree/normal.sh" ] && echo yes || echo no)"
  # The two ways a fixer can be destructive without failing anything: staging
  # work it was not asked to stage, and dropping an entry's flags.
  chk C "an unstaged edit is not staged by the fixer" "yes" \
    "$([ "$(git -C "$d" ls-files -s -- tree/edited.sh | awk '{print $2}')" = "$(git -C "$d" rev-parse HEAD:tree/edited.sh)" ] && echo yes || echo no)"
  chk C "and that edit is still there, still unstaged" "1" \
    "$(git -C "$d" -c core.autocrlf=false diff --name-only -- tree/edited.sh | wc -l | tr -d ' ')"
  chk C "the fixer leaves a skip-worktree flag in place" "S" "$(git -C "$d" ls-files -v -- tools/no-extension | cut -c1)"

  # And the mode has to survive into a commit: that is the object a Linux
  # checkout materializes, and the index alone would prove less.
  git -C "$d" -c core.autocrlf=false -c user.email=gate@example.invalid -c user.name=gate \
    -c commit.gpgsign=false commit -qm "fixture: modes" || { bad C "could not commit the fixture"; return; }
  local tree;  tree=$(git -C "$d" ls-tree -r HEAD | awk -F'\t' '$1 ~ /^100755 / {print $2}' | sort | tr '\n' ' ')
  chk C "the committed tree carries the mode (the object a Linux checkout materializes)" \
    "docs/already-good.sh docs/extension-only.sh docs/other.bash docs/with a space.sh tools/no-extension tree/edited.sh tree/no-newline tree/normal.sh " "$tree"
}

arm_d() {           # this repo's real index
  local repo=$1 list
  list=$(shebang_paths "$repo")
  case "$list" in
    *$'.githooks/pre-push'*) ok D "the content arm finds .githooks/pre-push (bash, no extension)" ;;
    *) bad D "the content arm did not find .githooks/pre-push; it found: $(printf '%s' "$list" | tr '\n' ' ')" ;;
  esac
  case "$list" in
    *'c930/sw/bin2hex.py'*) bad D "the content arm claimed c930/sw/bin2hex.py, which has a python3 shebang" ;;
    *) ok D "and does not claim c930/sw/bin2hex.py (python3 shebang, out of scope)" ;;
  esac
  if index_modes "$repo" | awk -F'\t' '$1 == "100755" && $2 == ".githooks/pre-push" { f = 1 } END { exit !f }'; then
    ok D "the mode gather reads .githooks/pre-push as 100755 out of the real index"
  else
    bad D "the mode gather did not find .githooks/pre-push at 100755"
  fi
}

# The one arm about the environment rather than the rule. Git hands a hook in a
# linked worktree a GIT_DIR that is not the directory any command runs in, and a
# fixture that obeys it writes into the repository being pushed instead of its
# own -- the 2026-10-14 incident, described at the top of this file. Arm E stands
# a throwaway repo with a linked worktree in for that repository, exports its
# gitdir exactly as a hook would, builds the arm-C fixture under it, and asserts
# the stand-in came out untouched. Remove the `git` wrapper and this arm fails on
# a stand-in that costs nothing; the real repository is never the experiment.
arm_e() {           # $1 = a scratch directory
  local base=$1 stand wt fix gd
  stand="$base/stand-in"; wt="$base/stand-in-wt"; fix="$base/fixture"
  mkdir -p "$base" || { bad E "cannot create $base"; return; }

  # The stand-in: a repository with a linked worktree, because that is the shape
  # in which an inherited GIT_DIR is a path that is NOT where commands run.
  git -C "$base" -c init.defaultBranch=main init -q "$stand" || { bad E "cannot init the stand-in repository"; return; }
  git -C "$stand" -c user.email=gate@example.invalid -c user.name=gate -c commit.gpgsign=false \
    commit -q --allow-empty -m "stand-in: base" || { bad E "cannot commit in the stand-in"; return; }
  git -C "$stand" worktree add -q "$wt" -b stand-in-wt 2>/dev/null || { bad E "cannot add the stand-in's linked worktree"; return; }

  local before_list before_bare after_list after_bare
  before_list=$(git -C "$wt" ls-files -s | wc -l | tr -d ' ')
  before_bare=$(git -C "$stand" rev-parse --is-bare-repository 2>&1)
  gd=$(git -C "$wt" rev-parse --absolute-git-dir 2>&1) || { bad E "cannot read the stand-in worktree's gitdir"; return; }

  # Exactly what git hands a hook in a linked worktree -- and the fixture under it.
  ( export GIT_DIR="$gd"; fixture_repo "$fix" >/dev/null 2>&1 )

  after_list=$(git -C "$wt" ls-files -s | wc -l | tr -d ' ')
  after_bare=$(git -C "$stand" rev-parse --is-bare-repository 2>&1)
  chk E "the stand-in's index is untouched by the fixture" "$before_list" "$after_list"
  chk E "the stand-in is still not bare" "$before_bare" "$after_bare"
  if git -C "$wt" ls-files | grep -qxF 'tools/no-extension'; then
    bad E "a fixture entry (tools/no-extension) landed in the stand-in's index"
  else
    ok E "no fixture entry landed in the stand-in's index"
  fi

  # And the fixture is where it was asked for, whole: the same 12 entries arm C
  # relies on, in a working tree of its own rather than in the stand-in.
  chk E "the fixture was built where it was asked for" "12" "$(git -C "$fix" ls-files -s | wc -l | tr -d ' ')"
  chk E "and it is that working tree, not the stand-in" "false" "$(git -C "$fix" rev-parse --is-bare-repository 2>&1)"
}

# ---------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------
main() {
  local repo="" fix=0 a here
  for a in "$@"; do
    case "$a" in
      --fix) fix=1 ;;
      -h|--help) sed -n '2,/^set -u$/p' "$0"; exit 0 ;;
      -*) printf 'script_exec_bit: unknown argument: %s (try --help)\n' "$a" >&2; exit 2 ;;
      *) [ -z "$repo" ] || { printf 'script_exec_bit: name one repository, not two (%s and %s)\n' "$repo" "$a" >&2; exit 2; }
         repo=$a ;;
    esac
  done

  here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  if [ -z "$repo" ]; then
    repo=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null) || repo=""
  fi
  if [ -z "$repo" ]; then
    printf 'script_exec_bit: cannot tell which repository to audit from %s.\n' "$here" >&2
    printf '                 The exec bit lives in a git index: run this inside the repo, or name one.\n' >&2
    exit 2
  fi
  repo=$(CDPATH= cd -- "$repo" 2>/dev/null && pwd) || repo=""
  if [ -z "$repo" ] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'script_exec_bit: not a git repository: %s\n' "${repo:-<named path>}" >&2
    exit 2
  fi

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/script_exec_bit.XXXXXX") || { echo 'script_exec_bit: mktemp failed' >&2; exit 2; }
  trap 'rm -rf "$tmp"' EXIT

  printf 'SCRIPT_EXEC_BIT repo=%s bash=%s\n\n' "$repo" "$BASH_VERSION"
  arm_a
  arm_b "$tmp/first-line"
  arm_c "$tmp/fixture"
  arm_d "$repo"
  arm_e "$tmp/env"
  printf 'ARMS      %s passed, %s failed\n\n' "$arm_pass" "$arm_fail"

  local rc=0
  audit "$repo" > "$tmp/audit.txt"; rc=$?
  cat "$tmp/audit.txt"

  if [ "$fix" = 1 ] && [ "$rc" -ne 0 ] && [ ${#AUDIT_VIOLATIONS[@]} -gt 0 ]; then
    printf '\n'
    fix_repo "$repo" < <(printf '%s\n' "${AUDIT_VIOLATIONS[@]+"${AUDIT_VIOLATIONS[@]}"}")
    printf '\nre-auditing:\n'
    audit "$repo" > "$tmp/audit.txt"; rc=$?
    cat "$tmp/audit.txt"
  fi

  local verdict=PASS
  [ "$arm_fail" -eq 0 ] || verdict=FAIL
  [ "$rc" -eq 0 ] || verdict=FAIL

  printf '\n'
  if [ "$verdict" = PASS ]; then
    printf 'OVERALL: PASS\n'
  else
    printf 'OVERALL: FAIL\n'
    [ "$arm_fail" -eq 0 ] || printf '  %s arm(s) failed: the gate is not testing what it says it tests, whatever the audit says\n' "$arm_fail"
    if [ "$rc" -ne 0 ]; then
      printf '  %s tracked shell script(s) are not 100755 in the index.\n' "${#AUDIT_VIOLATIONS[@]}"
      printf '  Fix:  bash %s --fix     (registers the mode in the index, which is what a Linux checkout\n' "${0#./}"
      printf '                              materializes -- and the only thing git records from Windows, where\n'
      printf '                              core.filemode=false makes chmod +x untracked. Mode only: no content)\n'
    fi
  fi
  [ "$verdict" = PASS ]
}

main "$@"
