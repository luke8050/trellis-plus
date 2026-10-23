#!/bin/bash
# Regression suite for trellis-plus v2.
#
# usage:  BASE=/path/to/unzipped/trellis-project  bash test-harness/run-regression.sh
#   BASE     a project produced by `trellis init --opencode` (Trellis 0.6.17 was used); required
#   TOOL     trellis-plus directory (default: parent of this script)
#   ONLY     comma separated groups to run, e.g. ONLY=D,E   (default: all)
#   V11_TOOL optional: a v1.1 trellis-plus directory; enables the v1.1 -> v2 upgrade test in group A
#
# Conventions
#   * run with bash (not sh/dash). Exit code = number of failed assertions.
#   * every gate rule has a positive case, a negative case and a REVERSE control: `reverse` breaks the rule's logic in the
#     installed gate.mjs (exact-string mutation, the anchor must match exactly N times) and the very same check must then FAIL;
#     the original is restored afterwards. A rule whose check survives its own mutation is a bad test.
#   * assertions on error texts always check the expected message, never the exit code alone (v1.1 lesson: two "passing"
#     tests were failing for the wrong reason).
#   * nothing here talks to a real ocr / mvn / network: fake-ocr and fake-mvn are used.

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="${TOOL:-$(dirname "$HERE")}"
BASE="${BASE:?set BASE=/path/to/a/trellis-initialized/project}"
BASE="$(cd "$BASE" && pwd)" || { echo "BASE is not a directory: $BASE" >&2; exit 2; }   # absolute: the suite cd's around, a relative BASE breaks every group after the first
WORK="$(mktemp -d /tmp/plus-reg.XXXXXX)"
export TRELLIS_CONTEXT_ID=plusreg
# BASE from git has no .trellis/.developer (gitignored): task.py create needs one
export TRELLIS_DEVELOPER="${TRELLIS_DEVELOPER:-regression}"
unset TRELLIS_PLUS_TASK TRELLIS_PLUS_SKIP_GATE
PASS=0; FAIL=0; SKIP=0; LAST=""; RC=0
export PATH="$HERE/fake-ocr:$HERE/fake-mvn:$PATH"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  - SKIPPED $1"; SKIP=$((SKIP+1)); }
run()  { LAST="$("$@" 2>&1)"; RC=$?; }                       # run <cmd...>  → $LAST output, $RC exit code
show() { echo "$LAST" | head -${2:-8} | sed 's/^/      /'; }
exit_is() { [ "$RC" -eq "$2" ] && ok "$1" || { bad "$1 (exit $RC, want $2)"; show; }; }
has()   { echo "$LAST" | grep -qE -- "$2" && ok "$1" || { bad "$1 (pattern: $2)"; show; }; }
hasnt() { echo "$LAST" | grep -qE -- "$2" && { bad "$1 (unexpected: $2)"; show; } || ok "$1"; }
# check <label> <want-exit> <pattern|-> <cmd...> : one assertion = exit code AND message
check() { local label="$1" want="$2" pat="$3"; shift 3; run "$@"
  if [ "$RC" -eq "$want" ] && { [ "$pat" = "-" ] || echo "$LAST" | grep -qE -- "$pat"; }; then ok "$label"; else bad "$label (exit $RC, want $want; pattern: $pat)"; show 10; fi; }
# chk <want-exit> <pattern|-> <cmd...> : silent version, returns 0/1 (used by reverse)
chk() { local want="$1" pat="$2"; shift 2; local out; out="$("$@" 2>&1)"; local rc=$?
  [ "$rc" -eq "$want" ] && { [ "$pat" = "-" ] || echo "$out" | grep -qE -- "$pat"; }; }
want() { [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }

# edit <file> <old> <new> [count]: exact replacement; the anchor must occur exactly <count> (default 1) times
edit() { F="$1" OLD="$2" NEW="$3" CNT="${4:-1}" python3 - <<'PY' || bad "edit: anchor not found exactly ${4:-1}x in $1: ${2:0:60}"
import os, sys
f = os.environ["F"]; s = open(f, encoding="utf8").read()
if s.count(os.environ["OLD"]) != int(os.environ["CNT"]): sys.exit(1)
open(f, "w", encoding="utf8").write(s.replace(os.environ["OLD"], os.environ["NEW"]))
PY
}
# reverse <label> <count> <old> <new> <chk-args...>: break the rule in the installed gate.mjs, the check must fail, then restore
reverse() {
  local label="$1" cnt="$2" old="$3" new="$4"; shift 4
  local gf="$W/.trellis/plus/gate.mjs"; cp "$gf" "$WORK/gate.orig"
  if ! F="$gf" OLD="$old" NEW="$new" CNT="$cnt" python3 - <<'PY'
import os, sys
f = os.environ["F"]; s = open(f, encoding="utf8").read()
if s.count(os.environ["OLD"]) != int(os.environ["CNT"]): sys.exit(1)
open(f, "w", encoding="utf8").write(s.replace(os.environ["OLD"], os.environ["NEW"]))
PY
  then bad "reverse [$label]: mutation anchor does not occur exactly $cnt time(s) in gate.mjs"; cp "$WORK/gate.orig" "$gf"; return; fi
  if "$@" >/dev/null 2>&1; then bad "reverse [$label]: the check still passes with the rule broken (useless test)"; else ok "reverse [$label]: check fails when the rule is broken"; fi
  cp "$WORK/gate.orig" "$gf"
  "$@" >/dev/null 2>&1 || bad "reverse [$label]: check does not pass again after restoring gate.mjs"
}
# reverse_file <label> <relpath-in-tool> <count> <old> <new> <fn> [args]: mutate a file of a COPY of the tool (the installer or an asset);
# <fn> gets the copy's directory as its LAST argument and must FAIL there (and pass with the real tool).
reverse_file() {
  local label="$1" rel="$2" cnt="$3" old="$4" new="$5"; shift 5
  rm -rf "$WORK/toolmut"; cp -r "$TOOL" "$WORK/toolmut"
  if ! F="$WORK/toolmut/$rel" OLD="$old" NEW="$new" CNT="$cnt" python3 - <<'PY'
import os, sys
f = os.environ["F"]; s = open(f, encoding="utf8").read()
if s.count(os.environ["OLD"]) != int(os.environ["CNT"]): sys.exit(1)
open(f, "w", encoding="utf8").write(s.replace(os.environ["OLD"], os.environ["NEW"]))
PY
  then bad "reverse [$label]: mutation anchor does not occur exactly $cnt time(s) in $rel"; rm -rf "$WORK/toolmut"; return; fi
  if "$@" "$WORK/toolmut" >/dev/null 2>&1; then bad "reverse [$label]: the check still passes with the rule broken (useless test)"; else ok "reverse [$label]: check fails when the rule is broken"; fi
  "$@" "$TOOL" >/dev/null 2>&1 || bad "reverse [$label]: the check does not pass with the real tool"
  rm -rf "$WORK/toolmut"
}

gc() { git -c user.email=a@b -c user.name=t commit -q --no-verify "$@" >/dev/null 2>&1; }
fresh() { rm -rf "$1"; cp -r "$BASE" "$1"; ( cd "$1" && git init -q . && git add -A >/dev/null 2>&1 && gc -m init ); }
snap()  { ( cd "$1" && find .trellis .opencode -type f -not -path '*/backup/*' -not -name '*.pyc' | sort | xargs sha256sum ); }
newtask() { ( cd "$1" && python3 .trellis/scripts/task.py create "$2" --slug "$2" --description "regression task" >/dev/null 2>&1 ); ls -d "$1"/.trellis/tasks/*-"$2" | sed "s#^$1/##"; }
# use <project>: all gate calls go through $G
use() { W="$1"; G="node $W/.trellis/plus/gate.mjs"; }
# mkproj <dir>: BASE + apply --all + the order-dedupe Java sources, committed (hook bypassed)
mkproj() { fresh "$1"; node "$TOOL/trellis-plus.mjs" apply "$1" --all >/dev/null 2>&1
  mkdir -p "$1/src/main/java/com/acme"; cp "$HERE"/fixtures/lint/java/*.java "$1/src/main/java/com/acme/"
  ( cd "$1" && git add -A >/dev/null 2>&1 && gc -m plus ); use "$1"; }
# setprof <profile>: set profile in the installed plus.config.json (groups that test blocking review/manifests gates use strict; the shipped default is standard)
setprof() { python3 - "$W/.trellis/plus/plus.config.json" "$1" <<'PY3'
import json, sys
f = sys.argv[1]; d = json.load(open(f, encoding="utf8")); d["profile"] = sys.argv[2]; json.dump(d, open(f, "w", encoding="utf8"), indent=2)
PY3
}
# tri <task> <round> <lines...>: write reviews/ocr-triage.md for ocr-r<round>.json
tri() { local t="$1" n="$2"; shift 2; mkdir -p "$W/$t/reviews"; { printf 'Report: ocr-r%s.json\nRound: %s\n\n' "$n" "$n"; printf '%s\n' "$@"; } > "$W/$t/reviews/ocr-triage.md"; }
SAMPLE="$TOOL/assets/spec/plus-doc-samples"; FX="$HERE/fixtures/lint"
# fill <task> [tier]: the shipped sample + fixtures as a valid plan (L: with code map)
fill() { local T="$1"; cp "$SAMPLE/prd.md" "$W/$T/prd.md"
  if [ "${2:-L}" != "S" ]; then cp "$SAMPLE/design.md" "$W/$T/design.md"; cp "$FX/implement.md" "$W/$T/implement.md"; fi
  if [ "${2:-L}" = "L" ]; then mkdir -p "$W/$T/research"; cp "$FX/code-map.md" "$W/$T/research/code-map.md"; fi; }
# mkplan <slug> <tier>: task + tier + seed + valid documents; echoes the task path
mkplan() { local T; T="$(newtask "$W" "$1")"; $G tier "$T" "$2" --reason "regression: tier $2" >/dev/null 2>&1; $G seed "$T" >/dev/null 2>&1; fill "$T" "$2"; echo "$T"; }

# editall <file> <old> <new>: replace every occurrence (at least one must exist)
editall() { F="$1" OLD="$2" NEW="$3" python3 - <<'PY' || bad "editall: anchor not found in $1: ${2:0:60}"
import os, sys
f = os.environ["F"]; s = open(f, encoding="utf8").read()
if os.environ["OLD"] not in s: sys.exit(1)
open(f, "w", encoding="utf8").write(s.replace(os.environ["OLD"], os.environ["NEW"]))
PY
}
# dropline <file> <prefix>: delete the lines that start with <prefix> (at least one must exist)
dropline() { F="$1" PRE="$2" python3 - <<'PY' || bad "dropline: no line starts with: ${2:0:60}"
import os, sys
f = os.environ["F"]; L = open(f, encoding="utf8").read().split("\n"); keep = [l for l in L if not l.startswith(os.environ["PRE"])]
if len(keep) == len(L): sys.exit(1)
open(f, "w", encoding="utf8").write("\n".join(keep))
PY
}
# dropsection <file> <heading line>: delete a "## " section up to the next "## " heading
dropsection() { F="$1" H="$2" python3 - <<'PY' || bad "dropsection: heading not found: $2"
import os, re, sys
f = os.environ["F"]; s = open(f, encoding="utf8").read(); h = os.environ["H"]
a = s.find("\n" + h + "\n")
if a < 0: sys.exit(1)
m = re.search(r"\n## ", s[a + 1 + len(h):])
b = a + 1 + len(h) + (m.start() if m else len(s))
open(f, "w", encoding="utf8").write(s[:a] + s[b:])
PY
}

echo "regression workdir: $WORK"

############################################################################################################
if want A; then
echo "== A. install / idempotency / doctor / parser / breadcrumbs / plugin / upgrade / revert"
W1="$WORK/a"; fresh "$W1"
cp "$W1/.trellis/workflow.md" "$WORK/o.workflow"; cp "$W1/.trellis/scripts/task.py" "$WORK/o.task"
cp "$W1/.opencode/lib/trellis-context.js" "$WORK/o.ctx"; cp "$W1/.trellis/config.yaml" "$WORK/o.config"
cp "$W1/.opencode/agents/trellis-implement.md" "$WORK/o.impl"; cp "$W1/.opencode/agents/trellis-check.md" "$WORK/o.check"
run node "$TOOL/trellis-plus.mjs" apply "$W1" --all;           exit_is "apply --all (project path as argument, cwd elsewhere)" 0
snap "$W1" > "$WORK/s1"; run node "$TOOL/trellis-plus.mjs" apply "$W1" --all; snap "$W1" > "$WORK/s2"
cmp -s "$WORK/s1" "$WORK/s2" && ok "apply is idempotent" || bad "apply is idempotent"
run node "$TOOL/trellis-plus.mjs" doctor "$W1";                exit_is "doctor passes after apply" 0
cfgver() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version"))' "$1/.trellis/plus/plus.config.json"; }
# tv <tool dir>: the version in that tool's package.json (the single source of the tool version)
tv() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]+"/package.json"))["version"])' "$1"; }
TV="$(tv "$TOOL")"
[ "$(cfgver "$W1")" = "$TV" ] && ok "a fresh apply leaves plus.config.json with the package.json version ($TV)" || bad "a fresh apply leaves plus.config.json with the package.json version ($TV; got $(cfgver "$W1"))"
cp "$W1/.trellis/plus/plus.config.json" "$WORK/a.ver.cfg"
python3 - "$W1/.trellis/plus/plus.config.json" <<'PY2'
import json, sys
f = sys.argv[1]; d = json.load(open(f)); d.pop("version"); d["ocr"]["maxRerun"] = 1; json.dump(d, open(f, "w"), indent=2)
PY2
run node "$TOOL/trellis-plus.mjs" doctor "$W1"; exit_is "doctor flags a plus.config.json without a version" 1; has "...and says what is wrong" "plus.config.json version is missing"
run node "$TOOL/trellis-plus.mjs" apply "$W1" --all; exit_is "apply stamps the missing version" 0
[ "$(cfgver "$W1")" = "$TV" ] && ok "...version is $TV again" || bad "...version is $TV again"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ocr"]["maxRerun"])' "$W1/.trellis/plus/plus.config.json")" = "1" ] && ok "...and the user's own keys are untouched (ocr.maxRerun stays 1)" || bad "...and the user's own keys are untouched"
sed -i "s/\"version\": \"$TV\"/\"version\": \"2.0.0\"/" "$W1/.trellis/plus/plus.config.json"
run node "$TOOL/trellis-plus.mjs" doctor "$W1"; exit_is "doctor flags an older version" 1; has "...naming both versions" "version is \"2.0.0\", this tool is $TV"
run node "$TOOL/trellis-plus.mjs" apply "$W1" --all; [ "$(cfgver "$W1")" = "$TV" ] && ok "apply upgrades 2.0.0 -> $TV" || bad "apply upgrades 2.0.0 -> $TV"
cp "$WORK/a.ver.cfg" "$W1/.trellis/plus/plus.config.json"
ver_stamped() { local t="$1" w="$WORK/vs"; fresh "$w"; node "$t/trellis-plus.mjs" apply "$w" --all >/dev/null 2>&1
  python3 - "$w/.trellis/plus/plus.config.json" <<'PY3'
import json, sys
f = sys.argv[1]; d = json.load(open(f)); d.pop("version", None); json.dump(d, open(f, "w"), indent=2)
PY3
  node "$t/trellis-plus.mjs" apply "$w" --all >/dev/null 2>&1; [ "$(cfgver "$w")" = "$(tv "$t")" ]; }
chk 0 - ver_stamped "$TOOL" && ok "apply re-stamps the version (helper holds on the real tool)" || bad "apply re-stamps the version (helper)"
reverse_file "apply stamps the version" trellis-plus.mjs 1 '  stampVersion()
  let good = patchWorkflow()' '  let good = patchWorkflow()' ver_stamped
# the version comes from package.json: change it in a COPY of the tool and the stamped value must follow (not a constant)
ver_follows() { local t="$1" c="$WORK/tvcopy" w="$WORK/vf"; rm -rf "$c"; cp -r "$t" "$c"
  python3 - "$c/package.json" <<'PY3'
import json, sys
f = sys.argv[1]; d = json.load(open(f)); d["version"] = "9.9.9"; json.dump(d, open(f, "w"), indent=2)
PY3
  fresh "$w"; node "$c/trellis-plus.mjs" apply "$w" --all >/dev/null 2>&1; [ "$(cfgver "$w")" = "9.9.9" ] && node "$c/trellis-plus.mjs" doctor "$w" >/dev/null 2>&1; }
chk 0 - ver_follows "$TOOL" && ok "the stamped version follows package.json (copy set to 9.9.9: config says 9.9.9, doctor passes)" || bad "the stamped version follows package.json (copy set to 9.9.9)"
reverse_file "version is read from package.json" trellis-plus.mjs 1 '  TOOL_VERSION = doc.version' '  TOOL_VERSION = "2.1.0"' ver_follows
# the shipped config no longer carries a second, hard-coded version
[ "$(grep -c '"version"' "$TOOL/assets/plus/plus.config.json")" = "0" ] && ok "assets/plus/plus.config.json has no hard-coded version (package.json is the only source)" || bad "assets/plus/plus.config.json has no hard-coded version"
# unreadable / invalid package.json: apply and doctor stop with exit 2, say why, and write nothing; --help still works
ver_bad() { local mode="$1" cmd="$2" t="$3" c="$WORK/tvbad" w="$WORK/vb"; rm -rf "$c"; cp -r "$t" "$c"
  case "$mode" in
    missing) rm "$c/package.json" ;;
    invalid) echo '{ not json' > "$c/package.json" ;;
    nover)   echo '{"name":"x"}' > "$c/package.json" ;;
    badver)  echo '{"version":"latest"}' > "$c/package.json" ;;
  esac
  fresh "$w"; snap "$w" > "$WORK/vb.before"
  run node "$c/trellis-plus.mjs" $cmd "$w" --all; ver_bad_rc=$RC; ver_bad_out="$LAST"
  snap "$w" > "$WORK/vb.after"
  [ "$ver_bad_rc" = "2" ] && echo "$ver_bad_out" | grep -qE 'cannot read the tool version|"version" must be a semver' && cmp -s "$WORK/vb.before" "$WORK/vb.after" && [ ! -e "$w/.trellis/plus" ]; }
for m in missing invalid nover badver; do
  chk 0 - ver_bad "$m" apply "$TOOL" && ok "apply with package.json '$m' exits 2, explains, and writes nothing" || bad "apply with package.json '$m' exits 2, explains, and writes nothing"
done
chk 0 - ver_bad missing doctor "$TOOL" && ok "doctor with a missing package.json exits 2 as well" || bad "doctor with a missing package.json exits 2 as well"
ver_bad_dry() { local t="$1" c="$WORK/tvbad2" w="$WORK/vb2"; rm -rf "$c"; cp -r "$t" "$c"; rm "$c/package.json"; fresh "$w"
  node "$c/trellis-plus.mjs" apply "$w" --dry-run >/dev/null 2>&1; [ $? -eq 2 ]; }
chk 0 - ver_bad_dry "$TOOL" && ok "apply --dry-run with a missing package.json also exits 2" || bad "apply --dry-run with a missing package.json also exits 2"
ver_help_ok() { local t="$1" c="$WORK/tvbad3"; rm -rf "$c"; cp -r "$t" "$c"; rm "$c/package.json"; node "$c/trellis-plus.mjs" -h 2>&1 | grep -q "Usage"; }
chk 0 - ver_help_ok "$TOOL" && ok "-h works without package.json (help does not need the version)" || bad "-h works without package.json"
ver_bad_missing_t() { ver_bad missing apply "$1"; }; ver_bad_semver_t() { ver_bad badver apply "$1"; }
reverse_file "package.json errors stop apply" trellis-plus.mjs 1 '  if (!loadToolVersion()) return false
' '' ver_bad_missing_t
reverse_file "a non-semver version is rejected" trellis-plus.mjs 1 '!SEMVER_RE.test(doc.version)' 'false' ver_bad_semver_t
no_grill_warning() { local t="$1" w="$WORK/ng"; fresh "$w"; local o; o="$(HOME="$WORK/emptyhome" node "$t/trellis-plus.mjs" apply "$w" --all 2>&1)"; ! echo "$o" | grep -qiE "grill-me|grilling"; }
chk 0 - no_grill_warning "$TOOL" && ok "apply does not look for /grill-me or grilling (no warning when they are not installed)" || bad "apply does not look for /grill-me or grilling"
reverse_file "no grill-me check at install" trellis-plus.mjs 1 '  stampVersion()
  let good = patchWorkflow()' '  log.warn("skill \"grill-me\" not found")
  let good = patchWorkflow()' no_grill_warning
cp "$W1/.trellis/plus/plus.config.json" "$WORK/a.cfg"
python3 - "$W1/.trellis/plus/plus.config.json" <<'PY2'
import json, sys
f = sys.argv[1]; d = json.load(open(f)); d["gates"] = {"lintplan": "warn"}; json.dump(d, open(f, "w"))
PY2
run node "$TOOL/trellis-plus.mjs" doctor "$W1"; has "doctor warns about an invalid gates key (every gate would exit 2)" "plus.config.json: plus.config.json: gates.lintplan is unknown|gates.lintplan is unknown.*exits 2"
python3 - "$W1/.trellis/plus/plus.config.json" <<'PY2'
import json, sys
f = sys.argv[1]; d = json.load(open(f)); d["gates"] = {"lintPlan": "warn", "designReview": "off"}; json.dump(d, open(f, "w"))
PY2
run node "$TOOL/trellis-plus.mjs" doctor "$W1"; has "doctor lists the switches that are not error" 'gate switches that are not "error": lintPlan=warn, designReview=off'; exit_is "...and stays green (switches are the user's choice)" 0
cp "$WORK/a.cfg" "$W1/.trellis/plus/plus.config.json"
for s in 1.6 1.7 2.4 2.5; do
  run bash -c "cd '$W1' && python3 .trellis/scripts/get_context.py --mode phase --step $s --platform opencode | head -1"
  has "get_context --step $s finds the step" "^#### $s "
done
run bash -c "cd '$W1' && python3 .trellis/scripts/get_context.py --mode phase --step 1.8 --platform opencode | head -3"
hasnt "the v1.1 step 1.8 (alignment) is gone" "^#### 1\.8 "
run node "$HERE/smoke_load.mjs" "$W1";                          has "patched inject-subagent-context.js really imports" "LOAD OK"
LAST="$(grep -c 'plus-design-reviewer' "$W1/.opencode/lib/trellis-context.js")"; has "trellis-context.js excludes plus-design-reviewer from the breadcrumb" "^1$"
LAST="$(grep -c 'plus-design-accuracy' "$W1/.opencode/lib/trellis-context.js")"; has "no v1.1 reviewer names left in trellis-context.js" "^0$"
# per-turn breadcrumb hygiene: [plus] lines <= 400 chars per block, no HTML comment in them, every required step has a line
bc_check() { python3 - "$1" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf8").read(); bad = 0
for status, steps in (("planning", ("1.6", "1.7")), ("in_progress", ("2.4", "2.5"))):
    m = re.search(r"\[workflow-state:%s\]\n(.*?)\n\s*\[/workflow-state:%s\]" % (status, status), t, re.S)
    plus = [l for l in m.group(1).split("\n") if l.startswith("[plus] ")]
    n = sum(len(l) for l in plus)
    print("%s: %d [plus] line(s), %d chars" % (status, len(plus), n))
    if not plus or n > 400: print("  TOO LONG or MISSING"); bad = 1
    if any("<!--" in l for l in plus): print("  HTML comment in breadcrumb"); bad = 1
    for s in steps:
        if s not in " ".join(plus): print("  step %s has no breadcrumb line" % s); bad = 1
sys.exit(bad)
PY
}
check "breadcrumb: [plus] lines <= 400 chars per block, no HTML comment, required steps present" 0 "^in_progress: 1 \[plus\] line" bc_check "$W1/.trellis/workflow.md"
show 4
cp "$W1/.trellis/workflow.md" "$WORK/wf.bad"; edit "$WORK/wf.bad" "[plus] After trellis-check:" "[plus] $(printf 'x%.0s' $(seq 1 120)) After trellis-check:"
check "breadcrumb check REJECTS an over-long [plus] line (reverse control)" 1 "TOO LONG" bc_check "$WORK/wf.bad"
cp "$W1/.trellis/workflow.md" "$WORK/wf.bad2"; edit "$WORK/wf.bad2" "2.5 \`gate.mjs ocr" "2.x \`gate.mjs ocr"
check "breadcrumb check REJECTS a required step without a breadcrumb line (reverse control)" 1 "step 2.5 has no breadcrumb" bc_check "$WORK/wf.bad2"
# v1.1 -> v2 upgrade (needs the v1.1 sources)
if [ -n "$V11_TOOL" ] && [ -f "$V11_TOOL/trellis-plus.mjs" ]; then
  W2="$WORK/a11"; fresh "$W2"; node "$V11_TOOL/trellis-plus.mjs" apply "$W2" --all >/dev/null 2>&1
  echo "local edit" >> "$W2/.opencode/skills/plus-align/SKILL.md"
  run node "$TOOL/trellis-plus.mjs" apply "$W2" --all;          exit_is "upgrade v1.1 -> v2 apply succeeds" 0
  [ ! -e "$W2/.opencode/agents/plus-design-accuracy.md" ] && [ ! -e "$W2/.opencode/agents/plus-req-coverage.md" ] && [ ! -e "$W2/.opencode/agents/plus-impact-analysis.md" ] && ok "upgrade removes the three v1.1 reviewers" || bad "upgrade removes the three v1.1 reviewers"
  [ ! -e "$W2/.opencode/skills/plus-planning-depth/SKILL.md" ] && [ ! -e "$W2/.trellis/plus/templates/alignment.md" ] && [ ! -e "$W2/.trellis/spec/guides/plus-design-review-rubric.md" ] && ok "upgrade removes planning-depth skill, alignment template, rubric" || bad "upgrade removes planning-depth skill, alignment template, rubric"
  [ -e "$W2/.opencode/skills/plus-align/SKILL.md" ] && has "an obsolete file edited locally is KEPT with a warning" "obsolete .*plus-align.* edited locally" || bad "locally edited obsolete file was deleted"
  LAST="$(grep -c 'plus-design-reviewer' "$W2/.opencode/lib/trellis-context.js")"; has "upgrade rewrites the v1.1 plugin pattern" "^1$"
  run node "$TOOL/trellis-plus.mjs" doctor "$W2";               exit_is "doctor passes after the upgrade" 0; has "doctor warns about v1.x config keys" "v1\.x key"
  grep -q "Plus Enhancements" "$W2/.trellis/workflow.md" && ! grep -q "Requirement alignment" "$W2/.trellis/workflow.md" && ok "upgrade replaces the v1.1 workflow blocks" || bad "upgrade replaces the v1.1 workflow blocks"
  rm -f "$W2/.opencode/skills/plus-align/SKILL.md"
else skip "v1.1 -> v2 upgrade (set V11_TOOL=<v1.1 trellis-plus dir>)"; fi
run node "$TOOL/trellis-plus.mjs" apply "$W1" --align-skill foo;  has "--align-skill is reported as gone" "--align-skill is gone"
run node "$TOOL/trellis-plus.mjs" revert "$W1" --purge
for p in ".trellis/workflow.md:o.workflow" ".trellis/scripts/task.py:o.task" ".opencode/lib/trellis-context.js:o.ctx" ".trellis/config.yaml:o.config" ".opencode/agents/trellis-implement.md:o.impl" ".opencode/agents/trellis-check.md:o.check"; do
  cmp -s "$W1/${p%%:*}" "$WORK/${p##*:}" && ok "revert restores ${p%%:*} byte-for-byte" || bad "revert restores ${p%%:*}"
done
( cd "$BASE" && find . -type f -not -name '*.pyc' | sort | xargs sha256sum ) > "$WORK/base.sum"
( cd "$W1" && find . -path ./.git -prune -o -type f -not -path './.trellis/plus/*' -not -name '*.pyc' -print | sort | xargs sha256sum ) > "$WORK/w1.sum"
diff -q <(grep -v "\./\.trellis/plus/\|\.git/" "$WORK/base.sum") "$WORK/w1.sum" >/dev/null && ok "revert --purge leaves the project byte-identical to BASE (outside .trellis/plus config/backup)" || { bad "revert --purge leaves the project identical to BASE"; diff <(grep -v "\./\.trellis/plus/\|\.git/" "$WORK/base.sum") "$WORK/w1.sum" | head -5; }
fi

############################################################################################################
if want B; then
echo "== B. tier S/M/L: storage, reasons, refusals, legacy"
mkproj "$WORK/b"; cd "$W"
T="$(newtask "$W" t1)"
meta_is() { python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf8"))
assert d.get("meta", {}).get("plus_tier") == sys.argv[2], d.get("meta")
assert "status" in d and "title" in d, "other task.json keys lost"
print("meta.plus_tier =", d["meta"]["plus_tier"])
PY
}
check "a new task has no tier" 0 "not set" $G tier "$T"
check "seed refuses without a tier" 1 "set the tier first" $G seed "$T"
check "align refuses without a tier" 1 "task has no tier" $G align "$T"
check "pre-start refuses without a tier" 1 "task has no tier" $G pre-start "$T"
check "tier S needs a reason" 2 "needs --reason" $G tier "$T" S
check "tier M needs a reason" 2 "needs --reason" $G tier "$T" M
check "a short reason is not enough" 2 "needs --reason" $G tier "$T" S --reason abc
check "an invalid tier is rejected" 2 "tier must be S, M or L" $G tier "$T" X
check "tier L needs no reason" 0 "tier L set" $G tier "$T" L
check "tier is stored in task.json meta.plus_tier, other keys kept" 0 "meta.plus_tier = L" meta_is "$W/$T/task.json" L
check "tier is shown" 0 "^tier: L" $G tier "$T"
check "tier S with a reason" 0 "tier S set" $G tier "$T" S --reason "docs only change"
run $G tier "$T"; has "the reason is shown" "tier: S — docs only change"
# legacy: v1.x markers
T2="$(newtask "$W" t2)"; echo "typo fix only" > "$W/$T2/.plus-lightweight"
check "a v1.1 .plus-lightweight marker counts as tier S (legacy)" 0 "tier: S \(legacy" $G tier "$T2"
T3="$(newtask "$W" t3)"; echo "x" > "$W/$T3/alignment.md"
check "a v1.1 alignment.md makes the task legacy L" 0 "tier: L \(legacy" $G tier "$T3"
T4="$(newtask "$W" t4)"; printf '# d\n\n## 3. Change Inventory\n| DES-1 | a |\n' > "$W/$T4/design.md"
check "v1.1 DES-n ids make the task legacy L" 0 "tier: L \(legacy" $G tier "$T4"
T5="$(newtask "$W" t5)"
check "gate lightweight is a deprecated alias of tier S" 0 "deprecated" $G lightweight "$T5" --reason "typo fix outside services"
check "...and really stores tier S" 0 "meta.plus_tier = S" meta_is "$W/$T5/task.json" S
# refusals depend on the working tree
echo "// edit" >> src/main/java/com/acme/OrderService.java
T6="$(newtask "$W" t6)"
check "tier S is refused while a Service/Controller is changed" 1 "tier S refused" $G tier "$T6" S --reason "claims to be small"
check "tier M is accepted for 1 changed Service" 0 "tier M set" $G tier "$T6" M --reason "one service only"
check "tier L is always accepted" 0 "tier L set" $G tier "$T6" L
for n in A B C D; do printf 'package com.acme;\npublic class %sService { public int f() { return 1; } }\n' $n > src/main/java/com/acme/${n}Service.java; done
check "tier M is refused for more than 3 Service/Controller files" 1 "tier M refused .*limit 3" $G tier "$T6" M --reason "four services"
git checkout -q -- . ; git clean -fdq src; mkdir -p mod-a/src/main/java/x mod-b/src/main/java/x; echo "<project/>" > mod-a/pom.xml; echo "<project/>" > mod-b/pom.xml
printf 'package x;\npublic class AService { public int f() { return 1; } }\n' > mod-a/src/main/java/x/AService.java
printf 'package x;\npublic class BService { public int f() { return 1; } }\n' > mod-b/src/main/java/x/BService.java
check "tier M is refused when the change spans 2 Maven modules" 1 "2 module\(s\)" $G tier "$T6" M --reason "two modules"
rm -rf mod-a mod-b
# reverse controls
echo "// edit" >> src/main/java/com/acme/OrderService.java
reverse "tier S refusal" 1 'if (t === "S" && sc.length) {' 'if (false) {' chk 1 "tier S refused" $G tier "$T6" S --reason "claims to be small"
git checkout -q -- .
for n in A B C D; do printf 'package com.acme;\npublic class %sService { public int f() { return 1; } }\n' $n > src/main/java/com/acme/${n}Service.java; done
reverse "tier M class limit" 1 'if (sc.length > cfg.tiers.maxClassesM || mods.size > 1) {' 'if (false) {' chk 1 "tier M refused" $G tier "$T6" M --reason "four services"
git clean -fdq src
reverse "reason required for S/M" 1 'if (t !== "L" && reason.length < 6) fail2(' 'if (false) fail2(' chk 2 "needs --reason" $G tier "$T" S
reverse "seed needs a tier" 1 'if (ti.unset) { rep.error("set the tier first' 'if (false) { rep.error("set the tier first' chk 1 "set the tier first" $G seed "$(newtask "$W" t7)"
reverse "unset tier is an error (needTier)" 1 'if (!ti.unset) return false' 'return false' chk 1 "task has no tier" $G align "$(newtask "$W" t8)"
reverse "legacy lightweight marker counts as S" 1 'if (existsSync(join(taskDir, ".plus-lightweight")))' 'if (false)' chk 0 "tier: S \(legacy" $G tier "$T2"
fi

############################################################################################################
if want C; then
echo "== C. seed per tier"
mkproj "$WORK/c"; cd "$W"
TS="$(newtask "$W" s1)"; $G tier "$TS" S --reason "docs only change" >/dev/null
check "seed S: prd.md is created from the plus template" 0 "replaced the untouched Trellis prd.md skeleton" $G seed "$TS"
[ ! -e "$W/$TS/design.md" ] && [ ! -e "$W/$TS/implement.md" ] && ok "seed S: no design.md / implement.md" || bad "seed S: no design.md / implement.md"
LAST="$(head -c 300 "$W/$TS/prd.md")"; has "seed replaces the untouched Trellis prd.md skeleton (TBD) with the plus structure" "对齐状态：未对齐"
TM="$(newtask "$W" m1)"; $G tier "$TM" M --reason "single service change" >/dev/null; run $G seed "$TM"
[ -e "$W/$TM/design.md" ] && [ -e "$W/$TM/implement.md" ] && [ ! -e "$W/$TM/research/code-map.md" ] && ok "seed M: prd + design + implement, no code-map" || bad "seed M: prd + design + implement, no code-map"
TL="$(newtask "$W" l1)"; $G tier "$TL" L >/dev/null; run $G seed "$TL"
[ -e "$W/$TL/design.md" ] && [ -e "$W/$TL/implement.md" ] && [ -e "$W/$TL/research/code-map.md" ] && [ -d "$W/$TL/reviews" ] && ok "seed L: + research/code-map.md and reviews/" || bad "seed L: + research/code-map.md and reviews/"
run $G seed "$TL"; has "seed keeps existing files" "design.md exists — kept"
LAST="$(grep -c 'plus-testing-guide' "$W/$TL/implement.jsonl" "$W/$TL/check.jsonl" | tr '\n' ' ')"; has "seed registers the testing guide once per manifest (M/L), also after a second seed" "implement.jsonl:1 .*check.jsonl:1"
LAST="$(grep -c 'plus-testing-guide' "$W/$TS/implement.jsonl" | tr '\n' ' ')"; has "seed S does not register the testing guide" "^0"
for f in design implement; do LAST="$(grep -c '【填写' "$W/$TL/$f.md")"; [ "$LAST" -gt 0 ] && ok "template $f.md carries fill-in slots (so an unfilled draft fails the gate)" || bad "template $f.md carries fill-in slots"; done
# a prd.md the user already wrote is never overwritten
TE="$(newtask "$W" e1)"; $G tier "$TE" S --reason "docs only change" >/dev/null; printf '# mine\n\n## Requirements\n- do the thing\n' > "$W/$TE/prd.md"
check "seed keeps a user-written prd.md and warns that the plus structure is missing" 0 "without the plus structure" $G seed "$TE"
LAST="$(cat "$W/$TE/prd.md")"; has "...and did not touch it" "^# mine"
# templates must not trip the gate by their own instruction text (v1.1 E07 lesson)
for f in prd design implement code-map; do
  LAST="$(sed 's/【填写[^】]*】//g' "$TOOL/assets/plus/templates/$f.md" | python3 -c 'import re,sys; t=re.sub(r"<!--.*?-->","",sys.stdin.read(),flags=re.S); print("HIT" if re.search(r"\bTBD\b|\bTODO\b|\bXXX\b|待补充|待定|\{\{[^}]*\}\}",t) else "CLEAN")')"; has "template $f.md: instruction text contains no placeholder keyword" "^CLEAN$"
done
seeded_prd_ok() { local t; t="$(newtask "$W" "sk$RANDOM")"; $G tier "$t" S --reason "docs only change" >/dev/null; $G seed "$t" >/dev/null 2>&1; grep -q "^对齐状态：未对齐" "$W/$t/prd.md"; }
jsonl_once() { local t; t="$(newtask "$W" "jl$RANDOM")"; $G tier "$t" L >/dev/null; $G seed "$t" >/dev/null 2>&1; $G seed "$t" >/dev/null 2>&1; [ "$(grep -c plus-testing-guide "$W/$t/implement.jsonl")" = "1" ]; }
s_only_prd() { local t; t="$(newtask "$W" "so$RANDOM")"; $G tier "$t" S --reason "docs only change" >/dev/null; $G seed "$t" >/dev/null 2>&1; [ -e "$W/$t/prd.md" ] && [ ! -e "$W/$t/design.md" ]; }
chk 0 - seeded_prd_ok && chk 0 - jsonl_once && chk 0 - s_only_prd && ok "seed helpers pass on the intact gate" || bad "seed helpers pass on the intact gate"
reverse "skeleton replacement" 1 'if (cur !== null && PRD_SKELETON_RE.test(cur) &&' 'if (false &&' chk 0 - seeded_prd_ok
reverse "jsonl registration is deduplicated" 1 'if (readJsonl(p).some((e) => e.file === guide[0])) continue' '' chk 0 - jsonl_once
reverse "S tier gets only prd.md" 1 'if (ti.tier !== "S" && !prdOnly) { put("design.md", "design.md"); put("implement.md", "implement.md") }' 'if (!prdOnly) { put("design.md", "design.md"); put("implement.md", "implement.md") }' chk 0 - s_only_prd
fi

############################################################################################################
if want D; then
echo "== D. align: the four checks on prd.md"
FXO="$HERE/fixtures/ocr"; export FAKE_OCR_LOG="$WORK/ocr-d.log"
mkproj "$WORK/d"; cd "$W"
T="$(mkplan al L)"
check "valid prd (shipped sample) passes" 0 "3 requirement\(s\), 3 decision\(s\), status 已对齐" $G align "$T"
P="$W/$T/prd.md"; goodprd() { cp "$SAMPLE/prd.md" "$P"; }
# 1 status line
edit "$P" "对齐状态：已对齐" "对齐状态：未对齐"
check "未对齐 fails" 1 "对齐状态 is 未对齐" $G align "$T"
reverse "status check" 1 'else if (status !== "已对齐") soft(' 'else if (false) soft(' chk 1 "对齐状态 is 未对齐" $G align "$T"
goodprd; edit "$P" "对齐状态：已对齐" "（状态行被删）"
check "missing status line fails" 1 "missing the line .对齐状态" $G align "$T"
goodprd; edit "$P" "对齐状态：已对齐" "<!-- 对齐状态：已对齐 -->"
check "a status line inside an HTML comment does not count" 1 "missing the line .对齐状态" $G align "$T"
# 2 open questions
goodprd; edit "$P" $'## 5 待确认问题\n\n无' $'## 5 待确认问题\n\n- 并发下是否需要分布式锁？'
check "open question fails" 1 "待确认问题 is not empty \(1 item" $G align "$T"
reverse "open-question check" 1 'if (!NONE_RE.test(body)) soft(' 'if (false) soft(' chk 1 "待确认问题 is not empty" $G align "$T"
goodprd; edit "$P" $'## 5 待确认问题\n\n无' $'## 5 待确认问题\n\nNone.'
check "'None.' counts as empty" 0 "PASS" $G align "$T"
goodprd; python3 - "$P" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf8").read(); s = s[:s.index("## 5 待确认问题")]; open(sys.argv[1], "w", encoding="utf8").write(s)
PY
check "missing 待确认问题 section fails" 1 'missing section "待确认问题"' $G align "$T"
# 3 decision log (M/L only)
goodprd; python3 - "$P" <<'PY'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read()
s = "\n".join(l for l in s.split("\n") if not l.startswith("| D")); open(f, "w", encoding="utf8").write(s)
PY
check "L: empty decision log fails" 1 "决策记录 has no D<n> row" $G align "$T"
reverse "decision-log check (M/L)" 1 'else if (decs.length === 0) {' 'else if (false) {' chk 1 "决策记录 has no D<n> row" $G align "$T"
TSx="$(newtask "$W" als)"; $G tier "$TSx" S --reason "docs only change" >/dev/null; cp "$P" "$W/$TSx/prd.md"
check "S: the same prd without decisions passes" 0 "PASS" $G align "$TSx"
# a skipped clarification (e.g. /grill-me not installed): ONE line `无：<原因>` replaces the D<n> rows
nodec() { goodprd; python3 - "$P" "$1" <<'PY'
import re, sys
f = sys.argv[1]; s = open(f, encoding="utf8").read()
s = "\n".join(l for l in s.split("\n") if not l.startswith("| D"))
s = re.sub(r"(^##[^\n]*决策记录[^\n]*\n)", lambda m: m.group(1) + "\n" + sys.argv[2] + "\n", s, count=1, flags=re.M)
open(f, "w", encoding="utf8").write(s)
PY
}
nodec "- 无：未安装 grill-me，需求已在对话中确认"
check "L: a skipped clarification (one line 无：<原因>) is accepted, and says so" 0 "clarification skipped — 未安装 grill-me" $G align "$T"
reverse "skipped clarification is accepted" 1 'const skip = stripComments(decSec.body).match(SKIP_CLARIFY_RE)' 'const skip = null' chk 0 "clarification skipped" $G align "$T"
nodec "- 无：略"; check "L: a skip line without a real reason (< 6 chars) still fails" 1 "决策记录 has no D<n> row" $G align "$T"
nodec "- 备注：未澄清，直接开始"; check "L: any other free text is not a skip line" 1 "决策记录 has no D<n> row" $G align "$T"
goodprd
reverse "S tier is exempt from the decision log" 1 'if (ti.tier !== "S") {
    if (!decSec)' 'if (true) {
    if (!decSec)' chk 0 "PASS" $G align "$TSx"
# 4 numbered requirements
goodprd; edit "$P" "| R2 | 重复提交对外返回" "| 第二条 | 重复提交对外返回"
check "requirement without R<n> fails" 1 "item without a number R<n>" $G align "$T"
reverse "requirement numbering check" 1 'if (!m) { soft(`prd.md 需求: item without a number' 'if (false) { soft(`prd.md 需求: item without a number' chk 1 "item without a number" $G align "$T"
goodprd; edit "$P" "| R3 | 入参为空" "| R2 | 入参为空"
check "duplicate R<n> fails" 1 "duplicate R2" $G align "$T"
reverse "duplicate id check" 1 'if (reqIds.includes(m[0])) soft(' 'if (false) soft(' chk 1 "duplicate R2" $G align "$T"
goodprd; python3 - "$P" <<'PY'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read(); a = s.index("## 2 需求与验收"); b = s.index("## 3 非目标")
open(f, "w", encoding="utf8").write(s[:a] + "## 2 需求与验收\n\n- R1 重复订单号只创建一次\n- R2 重复提交返回 409\n- R3 空入参行为不变\n\n" + s[b:])
PY
check "requirements written as a list are fine" 0 "3 requirement\(s\)" $G align "$T"
goodprd; python3 - "$P" <<'PY'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read(); a = s.index("## 2 需求与验收"); b = s.index("## 3 非目标")
open(f, "w", encoding="utf8").write(s[:a] + "## 2 需求与验收\n\n说明文字\n\n" + s[b:])
PY
check "no requirement at all fails" 1 "no requirement R<n> found" $G align "$T"
# requirements grouped by function: ### headings, one table each
goodprd; check "grouped sample: 3 requirements in 2 function groups, no warning" 0 "3 requirement\(s\), 3 decision\(s\), status 已对齐, 2 function group\(s\)" $G align "$T"
LAST="$($G align "$T" 2>&1)"; hasnt "...and no grouping warning" "not grouped by function|has no requirement"
reverse "every table of the requirement section counts (multi-table)" 1 'for (const t of tablesOf(body)) for (const row of t) items.push(' 'for (const row of parseTable(body)) items.push(' chk 0 "3 requirement\(s\)" $G align "$T"
goodprd; python3 - "$P" <<'PY2'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read(); a = s.index("## 2 需求与验收"); b = s.index("## 3 非目标")
open(f, "w", encoding="utf8").write(s[:a] + "## 2 需求与验收\n\n| 编号 | 需求 | 验收 |\n| --- | --- | --- |\n| R1 | a | x |\n| R2 | b | y |\n| R3 | c | z |\n\n" + s[b:])
PY2
check "one flat table (no ### headings) passes but warns to group by function" 0 "WARN  prd.md 需求: not grouped by function" $G align "$T"
reverse "grouping hint" 1 'if (reqIds.length && groups.length === 0) rep.warn(' 'if (false) rep.warn(' chk 0 "not grouped by function" $G align "$T"
goodprd; edit "$P" $'### 2.2 入参校验兼容\n\n| 编号 | 需求 | 验收标准（在什么条件下应看到什么结果） |\n| --- | --- | --- |\n| R3 | 入参为空的行为保持不变 | 传入 null 仍抛出 IllegalArgumentException，接口返回 400 |' $'### 2.2 入参校验兼容\n\n（待写）\n\n### 2.3 空小节后面还有内容\n\n| 编号 | 需求 | 验收 |\n| --- | --- | --- |\n| R3 | 入参为空的行为保持不变 | 传入 null 仍抛出异常 |'
check "a ### group without any requirement only warns" 0 'WARN  prd.md 需求: group "2.2 入参校验兼容" has no requirement R<n>' $G align "$T"
reverse "empty group warning" 1 'for (const g of groups) if (!g.items.some(' 'for (const g of []) if (!g.items.some(' chk 0 'group "2.2 入参校验兼容" has no requirement' $G align "$T"
goodprd; edit "$P" "| R3 | 入参为空的行为保持不变" "| R1 | 入参为空的行为保持不变"
check "the same R<n> in two function groups is still a duplicate" 1 "duplicate R1" $G align "$T"
# v2.2: dotted ids (R1.1) are whole ids; nested list lines are not requirements
goodprd; edit "$P" "| R1 | 创建订单时" "| R1.1 | 创建订单时"; edit "$P" "| R2 | 重复提交对外" "| R1.2 | 重复提交对外"; edit "$P" "| R3 | 入参为空" "| R2.1 | 入参为空"
check "dotted ids R1.1 / R1.2 / R2.1 are 3 distinct requirements (no duplicate R1)" 0 "3 requirement\(s\)" $G align "$T"
reverse "dotted requirement ids" 1 'const R_HEAD_RE = /^R\d+(?:\.\d+)*\b/' 'const R_HEAD_RE = /^R\d+\b/' chk 0 "3 requirement\(s\)" $G align "$T"
goodprd; python3 - "$P" <<'PY4'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read()
a = s.index("## 2 需求与验收"); b = s.index("## 3 非目标")
open(f, "w", encoding="utf8").write(s[:a] + "## 2 需求与验收\n\n- R1 创建订单时订单号已存在则拒绝\n  - 验收：第二次创建仍只有 1 条\n- R2 重复提交返回 409\n  - 验收：状态码 409\n- R3 入参为空行为不变\n    - 验收：仍抛 IllegalArgumentException\n\n" + s[b:])
PY4
check "a list with nested acceptance lines: only the R lines are requirements" 0 "3 requirement\(s\)" $G align "$T"
reverse "nested list lines are not requirements" 1 'm[1].replace(/\t/g, "  ").length >= 2 &&' 'false &&' chk 0 "3 requirement\(s\)" $G align "$T"
goodprd
goodprd; edit "$P" "### 2.2 入参校验兼容" "### 2.2 【填写：功能或需求模块名】"
check "an unfilled group heading from the template is a placeholder error" 1 "prd.md:[0-9]+ unresolved placeholder: ### 2.2" $G align "$T"
bg_all() { local t; t="$(newtask "$W" "bga$RANDOM")"; cp "$SAMPLE/prd.md" "$W/$t/prd.md"; FAKE_OCR_FINDINGS_FILE="$FXO/findings-empty.json" $G ocr --task "$t" --run >/dev/null 2>&1
  grep -q 'R1 | 创建订单时' "$W/$t/reviews/ocr-background.md" && grep -q 'R3 | 入参为空' "$W/$t/reviews/ocr-background.md" && ! grep -q '^编号 | 需求' "$W/$t/reviews/ocr-background.md"; }
chk 0 - bg_all && ok "ocr background lists the requirements of ALL groups (R1, R3) and takes no table header for a requirement" || bad "ocr background lists the requirements of ALL groups"
reverse "background reads every requirement table" 1 'for (const t of tablesOf(body)) for (const row of t) items.push(' 'for (const row of parseTable(body)) items.push(' chk 0 - bg_all
# placeholders / size
goodprd; edit "$P" "- 目标：同一订单号只能成功创建一次" "- 目标：【填写：目标】"
check "an unresolved placeholder fails" 1 "prd.md:[0-9]+ unresolved placeholder" $G align "$T"
reverse "placeholder check" 1 'if (!PLACEHOLDER_RE.test(line)) return' 'return' chk 1 "unresolved placeholder" $G align "$T"
goodprd; python3 -c "print('<!-- ' + 'x' * 11000 + ' -->')" >> "$P"
check "prd.md over 10 KB only warns (size is a hint, never blocks)" 0 "WARN  prd.md is [0-9]+ bytes \(> 10240\)" $G align "$T"
reverse "prd size hint" 1 'if (bytesOf(raw) > cfg.limits.prd) rep.warn(' 'if (false) rep.warn(' chk 0 "WARN  prd.md is" $G align "$T"
# warnings only
goodprd; edit "$P" "| D3 | 入参为空是否一并调整 | 不调整，保持现状 | 代码 src/main/java/com/acme/OrderService.java:8 | R3 |" "| D3 | 入参为空是否一并调整 | 不调整，保持现状 |  | R9 |"
check "a decision without source / citing an unknown R only warns" 0 "WARN  prd.md D3: needs both|WARN  prd.md D3: 影响 cites R9" $G align "$T"
# legacy: v1.1 task = warnings only
goodprd; TL="$(newtask "$W" allegacy)"; echo "x" > "$W/$TL/alignment.md"; printf '# old\n\n## Requirements\n- REQ-1 old format\n' > "$W/$TL/prd.md"
check "legacy (v1.1) task: format findings are warnings only" 0 "legacy task: " $G align "$TL"
reverse "legacy leniency" 2 'const soft = (m) => (ti.legacy ? rep.warn(`legacy task: ${m}`) : rep.error(m))' 'const soft = (m) => rep.error(m)' chk 0 "legacy task: " $G align "$TL"
goodprd; check "restored: valid prd passes again" 0 "PASS" $G align "$T"
fi

############################################################################################################
if want E; then
echo "== E. lint-plan: truth findings are errors, style findings are warnings"
mkproj "$WORK/e"; cd "$W"
T="$(mkplan lp L)"; D="$W/$T/design.md"; I="$W/$T/implement.md"; M="$W/$T/research/code-map.md"
good() { fill "$T" L; }
check "valid plan (shipped sample + fixtures) passes" 0 "3 requirement\(s\); 2 Service/Controller class\(es\) need tests; 7 test-matrix row" $G lint-plan "$T"
# unfilled templates
TU="$(newtask "$W" lpu)"; $G tier "$TU" L >/dev/null; $G seed "$TU" >/dev/null
check "unfilled templates fail (placeholders, capped list)" 1 "unresolved placeholder.*\n?" $G lint-plan "$TU"; has "...the list is capped (no 45-line wall)" "more unresolved placeholder\(s\)"
# anchors
editall "$D" "OrderService.java:7#create" "OrderService.java:30#create"
check "anchor with a line out of range fails" 1 "anchor .*OrderService.java:30#create — line out of range" $G lint-plan "$T"
reverse "anchor line range" 1 'if (a < 1 || b > lines.length || a > b) {' 'if (false) {' chk 1 "line out of range" $G lint-plan "$T"
good; editall "$D" "OrderController.java:6#post" "OrderController.java:6#placeOrderV2"
check "anchor with a hallucinated symbol fails" 1 'symbol "placeOrderV2" not found within' $G lint-plan "$T"
reverse "anchor symbol" 1 'if (!slice.includes(bare))' 'if (false)' chk 1 "not found within" $G lint-plan "$T"
good; editall "$D" "src/main/java/com/acme/OrderService.java:7#create" "src/main/java/com/acme/Missing.java:7#create"
check "anchor on a missing file fails" 1 "Missing.java:7#create — file does not exist" $G lint-plan "$T"
reverse "anchor file existence" 1 'if (cands.length === 0) { rep.error(`${name}: anchor' 'if (false) { rep.error(`${name}: anchor' chk 1 "file does not exist" $G lint-plan "$T"
# short paths: the full path is NOT required, the file is looked up in the repo
good; editall "$D" "src/main/java/com/acme/OrderService.java:7#create" "OrderService.java:7#create"
check "a bare file name in an anchor resolves (no full path needed)" 0 "PASS" $G lint-plan "$T"
good; editall "$D" "src/main/java/com/acme/OrderService.java:7#create" "acme/OrderService.java:7#create"
check "a partial path (suffix) in an anchor resolves" 0 "PASS" $G lint-plan "$T"
good; editall "$D" "src/main/java/com/acme/OrderService.java:7#create" "OrderService.java:30#create"
check "a short path is still verified: line out of range fails" 1 "OrderService.java:30#create — line out of range" $G lint-plan "$T"
good; editall "$D" "src/main/java/com/acme/OrderService.java:7#create" "OrderService.java:7#hallucinated"
check "a short path is still verified: unknown symbol fails" 1 'symbol "hallucinated" not found within' $G lint-plan "$T"
good; editall "$D" "src/main/java/com/acme/OrderService.java:7#create" "OrderService.java:7#create"
reverse "short path lookup" 1 'return fileIndex().filter((x) => x === f || x.endsWith("/" + f))' 'return []' chk 0 "PASS" $G lint-plan "$T"
mkdir -p "$W/other/src/main/java/com/acme" && printf 'package com.acme;\npublic class OrderService { public int create() { return 2; } }\n' > "$W/other/src/main/java/com/acme/OrderService.java"
check "a name shared by two files warns (write a longer path) but is verified against the candidates" 0 "WARN  design.md: anchor OrderService.java matches 2 files" $G lint-plan "$T"
rm -rf "$W/other"; good
good; editall "$M" "OrderService.java:9#insert" "OrderService.java:99#insert"
check "anchors in research/code-map.md are verified too" 1 "research/code-map.md: anchor .*:99#insert — line out of range" $G lint-plan "$T"
good; editall "$I" "OrderService.java\`" "OrderService.java:4#nothing\`"
good
# required sections
dropsection "$D" "## 6 异常与边界"
check "missing required design section fails" 1 'design.md missing section "## 6 异常与边界"' $G lint-plan "$T"
reverse "required design sections" 1 'if (!s) { soft(`design.md missing section' 'if (false) { soft(`design.md missing section' chk 1 'missing section "## 6' $G lint-plan "$T"
good; python3 - "$D" <<'PY'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read(); a = s.index("## 11 开放问题"); open(f, "w", encoding="utf8").write(s[:a] + "## 11 开放问题\n\n")
PY
check "an empty design section fails (write 无 / 省略：原因)" 1 'section "11 开放问题" is empty' $G lint-plan "$T"
reverse "empty section check" 1 'if (s.body.replace(/\s+/g, " ").trim().length === 0) soft(`design.md section' 'if (false) soft(`design.md section' chk 1 "is empty" $G lint-plan "$T"
# 4 数据库变更: one chapter with ALL database changes (or "无变更：原因")
good; check "the shipped sample (数据库变更 = 无变更：原因) passes" 0 "PASS" $G lint-plan "$T"
dropsection "$D" "## 4 数据库变更"
check "L: missing 数据库变更 chapter fails" 1 'design.md missing section "## 4 数据库变更"' $G lint-plan "$T"
reverse "数据库变更 is a required chapter" 1 '["数据库变更", "4 数据库变更"], ' '' chk 1 'missing section "## 4 数据库变更"' $G lint-plan "$T"
good; python3 - "$D" <<'PY2'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read(); a = s.index("## 4 数据库变更"); b = s.index("## 5 详细设计"); open(f, "w", encoding="utf8").write(s[:a] + "## 4 数据库变更\n\n" + s[b:])
PY2
check "an empty 数据库变更 chapter fails (write 无变更：原因)" 1 'section "4 数据库变更" is empty' $G lint-plan "$T"
good; python3 - "$D" <<'PY2'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read(); a = s.index("## 4 数据库变更"); b = s.index("## 5 详细设计")
open(f, "w", encoding="utf8").write(s[:a] + "## 4 数据库变更\n\n| 对象 | 变更类型 | 变更内容 | 兼容与回滚 | 对应R |\n| --- | --- | --- | --- | --- |\n| orders | 加字段 | ADD COLUMN dedup_key VARCHAR(64) NULL COMMENT '去重键' | 存量为空；回滚 DROP COLUMN | R1 |\n\n" + s[b:])
PY2
check "a real database change table passes" 0 "PASS" $G lint-plan "$T"
good; python3 - "$D" <<'PY2'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read(); a = s.index("## 4 数据库变更"); b = s.index("## 5 详细设计")
open(f, "w", encoding="utf8").write(s[:a] + "## 4 数据库变更\n\n| 对象 | 变更类型 | 变更内容 | 兼容与回滚 | 对应R |\n| --- | --- | --- | --- | --- |\n| 【填写：表名】 | 加字段 | x | y | R1 |\n\n" + s[b:])
PY2
check "an unfilled template row in 数据库变更 is a placeholder error" 1 "design.md:[0-9]+ unresolved placeholder" $G lint-plan "$T"
good; python3 - "$D" <<'PY2'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read(); a = s.index("关键逻辑（伪代码）：\n\n```\n") + len("关键逻辑（伪代码）：\n\n```\n")
open(f, "w", encoding="utf8").write(s[:a] + "【填写：入口方法()】  // 谁调用\n" + s[a:])
PY2
check "an unfilled slot inside the pseudo-code block is a placeholder error" 1 "design.md:[0-9]+ unresolved placeholder: 【填写：入口方法" $G lint-plan "$T"
good
TMd="$(mkplan lpmd M)"; dropsection "$W/$TMd/design.md" "## 4 数据库变更"
check "M: 数据库变更 is required too" 1 'design.md missing section "## 4 数据库变更"' $G lint-plan "$TMd"
LAST="$(sed -n '/^## 5 详细设计/,/^## 6 /p' "$SAMPLE/design.md")"; hasnt "sample: 详细设计 has neither 主流程 nor 数据结构 (moved / removed)" "主流程|数据结构"; has "sample: 关键逻辑 is pseudo-code in a code block" '^```'
LAST="$(sed -n '/^## 5 详细设计/,/^## 6 /p' "$TOOL/assets/plus/templates/design.md")"; hasnt "template: 详细设计 has neither 主流程 nor 数据结构" "主流程|数据结构"; has "template: 关键逻辑 pseudo-code tree" "├──"; has "template: 字段与口径 limited to changed fields" "只写本次新增或修改的字段"
good; dropsection "$D" "## 2 术语与约定"; dropsection "$D" "## 8 非功能"
check "L: sections 2 and 8 are required" 1 'missing section "## 2 术语与约定"' $G lint-plan "$T"
TM="$(mkplan lpm M)"; DM="$W/$TM/design.md"; dropsection "$DM" "## 2 术语与约定"; dropsection "$DM" "## 8 非功能"
check "M: sections 2 and 8 may be omitted" 0 "tier M" $G lint-plan "$TM"
reverse "M may omit sections 2/8" 1 'const need = ti.tier === "L" ? [...DESIGN_ALWAYS, ...DESIGN_L_ONLY] : DESIGN_ALWAYS' 'const need = [...DESIGN_ALWAYS, ...DESIGN_L_ONLY]' chk 0 "tier M" $G lint-plan "$TM"
good; rm -f "$M"
check "L: research/code-map.md is required" 1 "research/code-map.md missing" $G lint-plan "$T"
check "M: no code-map needed" 0 "PASS" $G lint-plan "$TM"
good; rm -f "$D"
check "design.md missing fails" 1 "design.md missing" $G lint-plan "$T"
good
# requirement coverage (v2.2: there is no 模块拆分 chapter; coverage = 覆盖矩阵)
LAST="$(cat "$D")"; hasnt "the sample has no 模块拆分 chapter" "模块拆分"
LAST="$(cat "$TOOL/assets/plus/templates/design.md")"; hasnt "the template has no 模块拆分 chapter" "模块拆分"
dropline "$D" "| R3 | OrderService | OrderServiceTest#create_null_throws |"
check "a requirement missing from the coverage matrix fails" 1 "R3 is missing from design.md 覆盖矩阵" $G lint-plan "$T"
reverse "coverage matrix" 1 'else for (const q of leafIds(reqIds)) if (!covCited.has(q)) soft(' 'else for (const q of leafIds(reqIds)) if (false) soft(' chk 1 "R3 is missing from design.md 覆盖矩阵" $G lint-plan "$T"
good; editall "$D" "| R3 | OrderService | OrderServiceTest#create_null_throws |" "| R3, R7 | OrderService | OrderServiceTest#create_null_throws |"
check "an unknown R in the coverage matrix fails" 1 "cites R7, which prd.md does not define" $G lint-plan "$T"
reverse "unknown R reference" 1 'if (reqIds.length && !knownId(r, reqIds)) rep.error(`${name} cites' 'if (false) rep.error(`${name} cites' chk 1 "cites R7" $G lint-plan "$T"
good
# dotted ids in the plan: citing the group R1 covers R1.1 and R1.2
good; edit "$W/$T/prd.md" "| R1 | 创建订单时，订单号已存在则拒绝创建 |" "| R1.1 | 创建订单时，订单号已存在则拒绝创建 |"
edit "$W/$T/prd.md" $'\n\n### 2.2 入参校验兼容' $'\n| R1.2 | 附加需求 | 附加验收 |\n\n### 2.2 入参校验兼容'
check "citing a group (R1) in the plan covers its children R1.1 / R1.2" 0 "PASS" $G lint-plan "$T"
reverse "group citation covers children" 1 'for (const o of ids) if (o.startsWith(c + ".")) out.add(o)' '' chk 0 "PASS" $G lint-plan "$T"
editall "$D" "| R1 | OrderService |" "| R1.1 | OrderService |"
check "a child (R1.2) missing from the coverage matrix fails" 1 "R1.2 is missing from design.md 覆盖矩阵" $G lint-plan "$T"
good
# impact analysis
editall "$D" '"OrderService.create"` → 1' '"OrderService.create"` → 7'
check "7 references without 高风险 fails" 1 'has 7 references \(>= 5\) — mark it 高风险' $G lint-plan "$T"
reverse "high-risk rule" 1 'hits >= cfg.planning.highRiskRefs &&' 'false &&' chk 1 "has 7 references" $G lint-plan "$T"
editall "$D" "| 唯一调用方 OrderController#post，同步修改 |" "| 高风险：唯一调用方 OrderController#post，兼容靠 R3 用例回归 |"
check "...marked 高风险 passes" 0 "PASS" $G lint-plan "$T"
good; editall "$D" "| 唯一调用方 OrderController#post，同步修改 |" "|  |"
check "an impact row without 处置 fails" 1 'OrderService#create" has no 处置' $G lint-plan "$T"
reverse "impact disposition" 1 'if (!disp.trim()) {' 'if (false) {' chk 1 "has no 处置" $G lint-plan "$T"
good; editall "$D" '`git grep -n "OrderService.create"` → 1' '见代码'
check "an impact row without a number only warns" 0 'WARN  design.md 影响分析: "OrderService#create" — write the references as' $G lint-plan "$T"
good
# implement.md: files, tests
editall "$I" 'src/main/java/com/acme/OrderController.java`' 'src/main/java/com/acme/Ghost.java`'
check "a path that does not exist fails" 1 'Ghost.java` does not exist' $G lint-plan "$T"
reverse "implement path existence" 1 'if (cands.length === 0 && !isNew) rep.error(' 'if (false) rep.error(' chk 1 "does not exist" $G lint-plan "$T"
editall "$I" "改什么：post 捕获" "改什么：新增 post 捕获"
check "...the same path in a step marked 新增 passes" 0 "PASS" $G lint-plan "$T"
good; dropline "$I" "| R2 | OrderControllerTest"
check "a Controller without any matrix row fails" 1 "no cases for OrderController \(Service/Controller\)" $G lint-plan "$T"
reverse "matrix class rows" 1 'if (rows.length === 0) { rep.error(`implement.md 测试矩阵 has no cases for' 'if (false) { rep.error(`implement.md 测试矩阵 has no cases for' chk 1 "no cases for OrderController" $G lint-plan "$T"
good; dropline "$I" "| R1 | OrderServiceTest | create_firstOrderNo_inserts"
check "a Service without a 边界 case fails" 1 "OrderService has no 边界 case" $G lint-plan "$T"
reverse "matrix case types" 1 'if (!rows.some((r) => re.test(col(r, ["类型", "type"]))))' 'if (false)' chk 1 "has no 边界 case" $G lint-plan "$T"
good; dropline "$I" "| R2 | OrderControllerTest"; editall "$I" $'## 3 测试豁免\n\n无' $'## 3 测试豁免\n\n- src/main/java/com/acme/OrderController.java: thin controller covered by the contract suite'
check "an exempted Controller needs no rows (and is flagged for sign-off)" 0 "WARN  EXEMPT src/main/java/com/acme/OrderController.java" $G lint-plan "$T"
reverse "test exemption" 1 'if (!isSvcCtl(f) || exempt.has(f) || exempt.has(written)) continue' 'if (!isSvcCtl(f)) continue' chk 0 "WARN  EXEMPT" $G lint-plan "$T"
good; editall "$I" "| R3 | OrderServiceTest | create_null_throws" "| R8 | OrderServiceTest | create_null_throws"
check "an unknown R in the test matrix fails" 1 "implement.md 测试矩阵 cites R8" $G lint-plan "$T"
good
# size limits
python3 -c "print('y' * 31000)" >> "$D"
check "design.md over the L hint only warns (size never blocks)" 0 "WARN  design.md is [0-9]+ bytes \(> 30720\)" $G lint-plan "$T"
reverse "size hints" 1 'if (b > max) rep.warn(' 'if (false) rep.warn(' chk 0 "WARN  design.md is" $G lint-plan "$T"
good; python3 -c "print('z' * 30000)" >> "$M"
check "research/code-map.md has NO size limit (it is not injected into sub-agents)" 0 "PASS" $G lint-plan "$T"
hasnt "...and no size warning for it either" "code-map.md is [0-9]+ bytes"
good; python3 -c "print('y' * 13000)" >> "$DM"
check "M: design.md over 12 KB only warns" 0 "WARN  design.md is [0-9]+ bytes \(> 12288\)" $G lint-plan "$TM"
reverse "M has a lower design hint" 1 'const dLimit = ti.tier === "M" ? L.designM : L.designL' 'const dLimit = L.designL' chk 0 "> 12288" $G lint-plan "$TM"
good; python3 -c "print('y' * 13000)" >> "$D"; check "...a 13 KB design is fine for L" 0 "PASS" $G lint-plan "$T"
good; fill "$TM" M; cp "$W/.trellis/plus/plus.config.json" "$WORK/plus.config.bak"
python3 - "$W/.trellis/plus/plus.config.json" <<'PY'
import json, sys
f = sys.argv[1]; c = json.load(open(f)); c["limits"]["total"] = 6000; json.dump(c, open(f, "w"), indent=2)
PY
check "prd+design+implement over the total hint only warns" 0 "WARN  prd\+design\+implement is [0-9]+ bytes \(> 6000\)" $G lint-plan "$T"
reverse "total hint" 1 'if (total > L.total) rep.warn(' 'if (false) rep.warn(' chk 0 "WARN  prd\+design\+implement is" $G lint-plan "$T"
cp "$WORK/plus.config.bak" "$W/.trellis/plus/plus.config.json"
# tier M: at most 3 classes
for n in A B C D; do printf 'package com.acme;\npublic class %sService { public int f() { return 1; } }\n' $n > "$W/src/main/java/com/acme/${n}Service.java"; done
fill "$TM" M; python3 - "$W/$TM/implement.md" <<'PY'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read()
extra = "".join("\n### 步骤 %d：%sService\n\n- 文件：`src/main/java/com/acme/%sService.java`\n- 改什么：新增查询\n" % (i + 3, n, n) for i, n in enumerate("ABCD"))
open(f, "w", encoding="utf8").write(s.replace("\n## 2 测试矩阵", extra + "\n## 2 测试矩阵"))
PY
check "M: more than 3 Service/Controller classes in the plan fails" 1 "tier M allows at most 3 Service/Controller classes" $G lint-plan "$TM"
reverse "M class limit in the plan" 1 'if (needTest.size > cfg.tiers.maxClassesM || mods.size > 1) rep.error(`tier M allows' 'if (false) rep.error(`tier M allows' chk 1 "tier M allows at most" $G lint-plan "$TM"
rm -f "$W"/src/main/java/com/acme/[ABCD]Service.java
# tier S
TSx="$(newtask "$W" lps)"; $G tier "$TSx" S --reason "docs only change" >/dev/null; cp "$SAMPLE/prd.md" "$W/$TSx/prd.md"
check "S: lint-plan only needs prd.md" 0 "tier S .*only prd.md is required" $G lint-plan "$TSx"
reverse "S skips design/implement" 1 'if (ti.tier === "S") { rep.note(' 'if (false) { rep.note(' chk 0 "only prd.md is required" $G lint-plan "$TSx"
# style findings are warnings
good; python3 - "$D" <<'PY'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read()
s = s.replace("| B 数据库唯一索引 | 彻底杜绝重复 | 需迁移存量重复数据，发布窗口长 | 放弃，另立项 |\n", "")
s = s.replace("| 并发提交 | 两请求同时通过查重 | 可能各插入一条，本次接受，索引另立项 | 无（已在第 0 节说明） |", "| 并发提交 | 两请求同时通过查重 | 可能各插入一条，本次接受，索引另立项 |  |")
s = s.replace("## 11 开放问题\n\n无", "## 11 开放问题\n\n- [ ] 唯一索引何时立项")
open(f, "w", encoding="utf8").write(s)
PY
check "整体方案 without any alternatives table passes (no comparison is required)" 0 "PASS" $G lint-plan "$T"
hasnt "...and there is no 'compare at least two options' warning" "compare at least two options"
has "...scenario without a test" 'WARN  design.md 异常与边界: scenario "并发提交" has no 对应测试'; has "...unchecked open question" "WARN  design.md 开放问题: 1 unchecked item"
no_alt_warning() { local o; o="$($G lint-plan "$T" 2>&1)"; ! echo "$o" | grep -q "compare at least two options"; }
chk 0 - no_alt_warning && ok "...(helper holds on the intact gate)" || bad "no_alt_warning helper"
reverse "整体方案 needs no alternatives table" 1 '  // 整体方案 holds only the chosen solution (summary + diagram): no alternatives table is required or checked' '  const alt = findSection(dSecs, "整体方案")
  if (alt && parseTable(alt.body).length < 2) rep.warn("design.md 整体方案: compare at least two options (采用 + one rejected)")' chk 0 - no_alt_warning
# legacy
good; TLg="$(newtask "$W" lplegacy)"; echo x > "$W/$TLg/alignment.md"; cp "$SAMPLE/prd.md" "$W/$TLg/prd.md"; printf '# old\n\n## 1. Old section\ntext\n' > "$W/$TLg/design.md"; printf '# old plan\n' > "$W/$TLg/implement.md"
check "legacy (v1.1) task: format findings are warnings, exit 0" 0 "legacy task: design.md missing section" $G lint-plan "$TLg"
reverse "legacy leniency in lint-plan" 2 'const soft = (m) => (ti.legacy ? rep.warn(`legacy task: ${m}`) : rep.error(m))' 'const soft = (m) => rep.error(m)' chk 0 "legacy task: design.md missing section" $G lint-plan "$TLg"
check "legacy: anchors/placeholders stay errors" 1 "unresolved placeholder" bash -c "printf 'TBD\n' >> $W/$TLg/implement.md; node $W/.trellis/plus/gate.mjs lint-plan $TLg"
good
fi

############################################################################################################
if want F; then
echo "== F. anchors / matrix / status / usage (0-token helpers)"
mkproj "$WORK/f"; cd "$W"; setprof strict
T="$(mkplan hp L)"; D="$W/$T/design.md"; I="$W/$T/implement.md"; M="$W/$T/research/code-map.md"; good() { fill "$T" L; }
check "anchors: the sample's anchors verify" 0 "5 distinct anchor\(s\) verified" $G anchors "$T"
editall "$M" '搜索：`git grep -n "order_no"`' '搜索：待查'
check "anchors: NOT-FOUND without the search command only warns" 0 "WARN  research/code-map.md:[0-9]+ NOT-FOUND without the search command" $G anchors "$T"
reverse "NOT-FOUND needs a command" 1 'if (/NOT-FOUND/.test(line) && !/`[^`]+`/.test(line))' 'if (false)' chk 0 "NOT-FOUND without the search command" $G anchors "$T"
good; editall "$M" "OrderController.java:6#post" "OrderController.java:6#postV2"
check "anchors: a wrong symbol in code-map fails" 1 'research/code-map.md: anchor .*postV2.* not found within' $G anchors "$T"
good
check "matrix prints R → module → test" 0 "\| R1 \| OrderService \| OrderServiceTest#create_valid_savesAndReturnsId" $G matrix "$T"
check "matrix --check passes on a complete plan" 0 "R3 \| OrderService" $G matrix "$T" --check
hasnt "matrix: no 模块拆分 reference any more" "模块拆分"
dropline "$I" "| R3 | OrderServiceTest"
check "matrix --check fails when a requirement has no test row" 1 "R3: no row in implement.md 测试矩阵" $G matrix "$T" --check
reverse "matrix --check exit code" 1 'return opts.check && gaps.length ? 1 : 0' 'return 0' chk 1 "R3: no row" $G matrix "$T" --check
good
check "status: tier line" 0 "^  tier: L" $G status "$T"
has "status: lint-plan passes" "✓ lint-plan"; has "status: design-review is the open gate" "✗ design-review"; has "status: sizes are shown" "✓ design.md [0-9]+/30720 bytes"
check "status: the next step is the review (L, no review yet)" 0 "next: step 1.7" $G status "$T"
reverse "status next-step hint" 1 'if (!r.ok && !next) next = hint' 'if (false) next = hint' chk 0 "next: step 1.7" $G status "$T"
editall "$W/$T/prd.md" "对齐状态：已对齐" "对齐状态：未对齐"
check "status: a failing align is reported" 0 "✗ align — " $G status "$T"
has "status: ...and the next step points at the clarification" "next: step 1.6: clarify"
good
TN="$(newtask "$W" hpn)"; check "status: tier not set" 0 "not set" $G status "$TN"
# usage
check "usage: record a phase" 0 "recorded 12000 tokens" $G usage "$T" --phase 勘探 --tokens 12000 --note "code map"
check "usage: the sum and the tier target" 0 "tokens: 20000 / 320000 \(tier L target, not measured\)" $G usage "$T" --phase 起草 --tokens 8000
run $G usage "$T"; has "usage: both rows listed" "勘探: 12000 — code map"; has "usage: total adds up" "tokens: 20000"
check "usage: a non-numeric --tokens is rejected" 2 "--tokens must be a number" $G usage "$T" --phase x --tokens abc
check "usage: over the target is flagged" 0 "over the tier L target" $G usage "$T" --phase 实现 --tokens 400000
check "usage --check fails when over the target" 1 "over the tier L target" $G usage "$T" --check
reverse "usage budget check" 1 'if (budget && total > budget) {' 'if (false) {' chk 1 "over the tier L target" $G usage "$T" --check
fi

############################################################################################################
if want G; then
echo "== G. design-review (L): header, blocker/resolution consistency"
mkproj "$WORK/g"; cd "$W"; setprof strict
T="$(mkplan dr L)"; R="$W/$T/reviews"; mkdir -p "$R"
report() { # report <round> <blockers-in-header> <confirm> <rows-file-or-none>
  { printf '轮次：%s\n阻塞：%s\n需人工确认：%s\n\n## 1. 需求覆盖矩阵\n| 需求编号 | 摘要 | 对应模块 | 对应验收点 | 结论 |\n| --- | --- | --- | --- | --- |\n| R1 | 查重 | OrderService | 第二次创建失败 | 已覆盖 |\n\n## 2. 问题清单\n' "$1" "$2" "$3"
    if [ "$4" = none ]; then echo "无"; else printf '| 编号 | 位置 | 问题描述 | 证据 | 严重程度 | 修改建议 |\n| --- | --- | --- | --- | --- | --- |\n%s\n' "$4"; fi
    printf '\n## 3. 假设清单\n- 无\n\n## 4. 需人工确认\n- 并发是否接受\n\n## 5. 已检查无问题的维度\n- 术语一致性\n'; } > "$R/design-review.md"; }
ROWS2='| 1 | §5.1 | 缺少查重步骤 | src/main/java/com/acme/OrderService.java:7 | 阻塞 | 补充步骤 |
| 2 | §6 | 409 未说明 | prd.md R2 | 阻塞 | 补充 |
| 3 | §3 | 方案对比略 | prd.md | 建议 | 补充 |'
resolution() { printf '%s\n' "$@" > "$R/design-review-resolution.md"; }
rm -rf "$R"/*; check "L: no review report fails" 1 "reviews/design-review.md missing" $G design-review "$T"
reverse "L needs a review report" 1 'else rep.error("reviews/design-review.md missing' 'else rep.note("reviews/design-review.md missing' chk 1 "design-review.md missing" $G design-review "$T"
report 1 0 1 none
check "no blockers: passes without a resolution file" 0 "round 1: 0 blocker\(s\)" $G design-review "$T"
report 1 2 1 "$ROWS2"
check "blockers without a resolution file fail" 1 "design-review-resolution.md missing" $G design-review "$T"
resolution "- #1 采纳 — 已在 5.1 增加查重步骤"
check "a blocker without an entry fails" 1 "blocker #2 has no entry" $G design-review "$T"
reverse "every blocker needs an entry" 1 'if (!r) { rep.error(`blocker #${n} has no entry' 'if (false) { rep.error(`blocker #${n} has no entry' chk 1 "blocker #2 has no entry" $G design-review "$T"
resolution "- #1 采纳 — 已在 5.1 增加查重步骤" "- #2 驳回 — src/main/java/com/acme/OrderController.java:6 已有统一异常映射"
check "采纳 + 驳回 with an existing code anchor passes" 0 "round 1: 2 blocker\(s\), 1 suggestion\(s\)" $G design-review "$T"
resolution "- #1 采纳 — 已在 5.1 增加查重步骤" "- #2 驳回 — 需求 prd.md 第 2 节明确要求 409"
check "驳回 citing prd.md passes" 0 "PASS" $G design-review "$T"
resolution "- #1 采纳 — 已在 5.1 增加查重步骤" "- #2 驳回 — 我认为没问题"
check "驳回 without evidence fails" 1 "#2 驳回 needs evidence" $G design-review "$T"
reverse "驳回 needs evidence" 1 'if (r.kind === "驳回" && !(hasCodeEvidence(r.text)' 'if (false && !(hasCodeEvidence(r.text)' chk 1 "#2 驳回 needs evidence" $G design-review "$T"
resolution "- #1 采纳 — 已在 5.1 增加查重步骤" "- #2 驳回 — src/main/java/com/acme/Nope.java:6 不存在的文件"
check "驳回 with an anchor that does not exist fails" 1 "#2 驳回 needs evidence" $G design-review "$T"
resolution "- #1 采纳 — ok" "- #2 采纳 — 已补充 409 说明"
check "采纳 without saying what changed fails" 1 "#1 采纳: say what changed" $G design-review "$T"
reverse "采纳 needs content" 1 'if (r.kind === "采纳" && r.text.length < 4)' 'if (false)' chk 1 "say what changed" $G design-review "$T"
resolution "- #1 采纳 — 已在 5.1 增加查重步骤" "- #2 采纳 — 已补充 409 说明" "- #1 采纳 — 再次说明已改"
check "answering a blocker twice only warns" 0 "WARN  design-review-resolution.md: #1 answered twice" $G design-review "$T"
# header consistency
report 1 1 1 "$ROWS2"; resolution "- #1 采纳 — 已在 5.1 增加查重步骤" "- #2 采纳 — 已补充 409 说明"
check "header 阻塞：1 but 2 blocker rows → inconsistent, fails" 1 "header says 阻塞：1 but the 问题清单 table has 2 blocker row" $G design-review "$T"
reverse "header must match the table" 1 'if (blockers !== null && blockRows.length !== blockers)' 'if (false)' chk 1 "header says" $G design-review "$T"
report 1 2 1 "$ROWS2"; sed -i '/^阻塞：/d' "$R/design-review.md"
check "missing header line 阻塞 fails" 1 '阻塞：N" missing' $G design-review "$T"
reverse "header 阻塞 required" 1 'if (blockers === null) rep.error(' 'if (false) rep.error(' chk 1 '阻塞：N" missing' $G design-review "$T"
report 1 2 1 "$ROWS2"; sed -i '/^需人工确认：/d' "$R/design-review.md"
check "missing header line 需人工确认 fails" 1 '需人工确认：M" missing' $G design-review "$T"
report 3 2 1 "$ROWS2"; resolution "- #1 采纳 — 已在 5.1 增加查重步骤" "- #2 采纳 — 已补充 409 说明"
check "round 3 only warns (human decides)" 0 "WARN  round 3 exceeds review.maxRounds=2" $G design-review "$T"
reverse "round limit warning" 1 'if (round !== null && round > cfg.review.maxRounds)' 'if (false)' chk 0 "round 3 exceeds" $G design-review "$T"
report 1 2 3 "$ROWS2"
check "3+ items for a human → suggests /plus-grill-design" 0 "consider /plus-grill-design" $G design-review "$T"
report 1 2 1 "$ROWS2"; touch -d "now + 30 seconds" "$W/$T/design.md"
check "editing design.md after the review only warns" 0 "WARN  design.md changed after the review was written" $G design-review "$T"
reverse "stale-document warning" 1 'if (later.length) rep.warn(' 'if (false) rep.warn(' chk 0 "changed after the review" $G design-review "$T"
touch "$W/$T/design.md"
# tiers
TMx="$(newtask "$W" drm)"; $G tier "$TMx" M --reason "single service change" >/dev/null
check "M: no independent review needed" 0 "tier M: independent design review is not required" $G design-review "$TMx"
reverse "review only for L" 1 'if (ti.tier !== "L") { rep.note(`tier ${ti.tier}: independent design review' 'if (false) { rep.note(`tier ${ti.tier}: independent design review' chk 0 "not required" $G design-review "$TMx"
# legacy: v1.1 three-lens reports accepted, nothing at all is not
TLg="$(newtask "$W" drlegacy)"; echo x > "$W/$TLg/alignment.md"; mkdir -p "$W/$TLg/reviews"
check "legacy L without any review fails" 1 "design-review.md missing" $G design-review "$TLg"
for k in accuracy coverage impact; do echo "PASS" > "$W/$TLg/reviews/design-r1-$k.md"; done
check "legacy L with v1.1 three-lens reports is accepted" 0 "legacy task: v1.x three-lens reports present" $G design-review "$TLg"
reverse "legacy reports accepted" 1 'if (ti.legacy && old)' 'if (false)' chk 0 "three-lens reports present" $G design-review "$TLg"
fi

############################################################################################################
if want H; then
echo "== H. hard gate: pre-start per tier and task.py start"
mkproj "$WORK/h"; cd "$W"; setprof strict
real() { for k in implement check; do echo '{"file":".trellis/spec/backend/index.md","reason":"spec"}' >> "$W/$1/$k.jsonl"; done; }
start() { ( cd "$W" && python3 .trellis/scripts/task.py start "$1" ); }
tier_is() { python3 - "$W/$1/task.json" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf8")); assert d["meta"]["plus_tier"] == sys.argv[2]; print("tier kept:", d["meta"]["plus_tier"], "status:", d["status"])
PY
}
TN="$(newtask "$W" hn)"; real "$TN"
check "task.py start is refused for a task without a tier" 1 "task has no tier" start "$TN"
LAST="$(cd "$W" && python3 .trellis/scripts/task.py start "$TN" 2>&1 | tail -3)"; has "...with the hard-gate summary" "pre-start gate failed"
check "TRELLIS_PLUS_SKIP_GATE=1 bypasses the hard gate" 0 - env TRELLIS_PLUS_SKIP_GATE=1 bash -c "cd $W && python3 .trellis/scripts/task.py start $TN"
# tier S
TS="$(mkplan hs S)"
check "S: manifests with only [plus] entries are refused" 1 "no project spec/research entries" $G pre-start "$TS"
real "$TS"
check "S: prd + manifests are enough (no design / lint-plan / review)" 0 "== align" $G pre-start "$TS"
hasnt "S: lint-plan and design-review are not run" "== lint-plan|== design-review"
check "S: task.py start is allowed" 0 - start "$TS"
check "...and the tier survives start in task.json" 0 "tier kept: S status: in_progress" tier_is "$TS" S
# tier M
TM="$(newtask "$W" hm)"; $G tier "$TM" M --reason "single service change" >/dev/null; $G seed "$TM" >/dev/null; cp "$SAMPLE/prd.md" "$W/$TM/prd.md"; real "$TM"
check "M: unfilled design/implement templates are refused" 1 "unresolved placeholder" $G pre-start "$TM"
check "M: task.py start is refused too" 1 "pre-start gate failed" start "$TM"
fill "$TM" M
check "M: filled plan passes (align + lint-plan + manifests, no review)" 0 "== lint-plan" $G pre-start "$TM"; hasnt "M: no design-review gate" "== design-review"
check "M: task.py start is allowed" 0 - start "$TM"
# tier L
TL="$(mkplan hl L)"; real "$TL"; mkdir -p "$W/$TL/reviews"
check "L: no design review yet → refused" 1 "reviews/design-review.md missing" $G pre-start "$TL"
check "L: task.py start is refused" 1 "pre-start gate failed" start "$TL"
printf '轮次：1\n阻塞：0\n需人工确认：0\n\n## 2. 问题清单\n无\n' > "$W/$TL/reviews/design-review.md"
check "L: with a clean review it passes (all four gates)" 0 "== design-review" $G pre-start "$TL"
check "L: task.py start is allowed" 0 - start "$TL"
check "...and the tier is kept in task.json after start" 0 "tier kept: L status: in_progress" tier_is "$TL" L
# reverse controls (through pre-start: it has no side effects)
TMr="$(newtask "$W" hmr)"; $G tier "$TMr" M --reason "single service change" >/dev/null; $G seed "$TMr" >/dev/null; cp "$SAMPLE/prd.md" "$W/$TMr/prd.md"; real "$TMr"
reverse "M/L run lint-plan before start" 1 'if (ti.tier !== "S") reps.push(runGate("lintPlan", cfg, "lint-plan", () => lintPlan(taskDir, cfg, ti)))' 'if (false) reps.push(runGate("lintPlan", cfg, "lint-plan", () => lintPlan(taskDir, cfg, ti)))' chk 1 "unresolved placeholder" $G pre-start "$TMr"
TLr="$(mkplan hlr L)"; real "$TLr"
reverse "L needs the design review before start" 1 'if (ti.tier === "L") reps.push(runGate("designReview", cfg, "design-review", () => designReview(taskDir, cfg, ti)))' 'if (false) reps.push(runGate("designReview", cfg, "design-review", () => designReview(taskDir, cfg, ti)))' chk 1 "design-review.md missing" $G pre-start "$TLr"
TSr="$(mkplan hsr S)"
reverse "manifests need real spec entries" 1 'if (real.length === 0) man.error(' 'if (false) man.error(' chk 1 "no project spec/research entries" $G pre-start "$TSr"
real "$TSr"; editall "$W/$TSr/prd.md" "对齐状态：已对齐" "对齐状态：未对齐"
reverse "align runs before start" 1 'const reps = [runGate("align", cfg, "align", () => alignGate(taskDir, cfg, ti))]' 'const reps = []' chk 1 "对齐状态 is 未对齐" $G pre-start "$TSr"
fi

############################################################################################################
if want I; then
echo "== I. unit-test gate: Java scenario, method-level, tier limits, staged, base, git subdirectory"
fresh "$WORK/i"; node "$TOOL/trellis-plus.mjs" apply "$WORK/i" --all >/dev/null 2>&1
( cd "$WORK/i" && git add -A >/dev/null 2>&1 && gc -m plus ); bash "$HERE/mkjava.sh" "$WORK/i" no >/dev/null; use "$WORK/i"; cd "$W"
T="$(newtask "$W" gate)"
check "the Java scenario fails overall" 1 "problem\(s\)" $G test --task "$T"
has   "OrderService passes (test changed, has @Test)"            "ok  src/main/java/com/acme/OrderService.java"
has   "PayServiceImpl passes via PayServiceTest (Impl stripped)" "ok  src/main/java/com/acme/PayServiceImpl.java"
has   "pure interface UserService is skipped"                    "skip \(pure interface\): src/main/java/com/acme/UserService.java"
has   "OrderController without a test fails"                     "OrderController.java\n?.*no unit test found|no unit test found in module"
has   "StockService shell test (no @Test) fails"                 "no JUnit test method"
hasnt "deleted AuditService is ignored"                          "AuditService"
no_audit() { local o; o="$($G test --task "$T" 2>&1)"; ! echo "$o" | grep -q AuditService; }
chk 0 - no_audit && ok "...(helper holds on the intact gate)" || bad "no_audit helper"
# reverse controls on the failing scenario
reverse "a missing test is an error" 1 'if (existing.length === 0) { rep.error(' 'if (false) { rep.error(' chk 1 "no unit test found in module" $G test --task "$T"
reverse "a test without @Test is an error" 1 'if (!existing.some((c) => re.test(read(resolve(ROOT, c)) ?? ""))) {' 'if (false) {' chk 1 "no JUnit test method" $G test --task "$T"
reverse "pure interfaces are skipped" 1 'if (tg.skipInterfaces && isPureInterface(src)) {' 'if (false) {' chk 1 "skip \(pure interface\): src/main/java/com/acme/UserService.java" $G test --task "$T"
reverse "Impl suffix is stripped" 1 'for (const suf of tg.stripSuffixes || []) {' 'for (const suf of []) {' chk 1 "ok  src/main/java/com/acme/PayServiceImpl.java" $G test --task "$T"
cat > src/test/java/com/acme/OrderControllerTest.java <<'X'
package com.acme;
import org.junit.jupiter.api.Test;
class OrderControllerTest { @Test void post_ok() {} }
X
sed -i 's/void helperOnly() {}/@org.junit.jupiter.api.Test void left_ok() {}/' src/test/java/com/acme/StockServiceTest.java
check "after adding the missing tests the gate passes" 0 "✓ PASS" $G test --task "$T"
# staged mode: nothing staged → nothing to check; staged → checked
git add -A >/dev/null 2>&1; git reset -q src/test/java/com/acme/OrderControllerTest.java
check "--staged: a staged Controller whose test is not staged fails" 1 "OrderController.java" $G test --task "$T" --staged
git add -A >/dev/null 2>&1; check "--staged: everything staged passes" 0 "staged: [0-9]+ file" $G test --task "$T" --staged
git reset -q; git add -N . >/dev/null 2>&1; git reset -q
check "--staged with an empty index checks nothing" 0 "staged: 0 file\(s\)" $G test --task "$T" --staged
reverse "--staged reads the index only" 1 'const args = staged' 'const args = false' chk 0 "staged: 0 file\(s\)" $G test --task "$T" --staged
git add -A >/dev/null 2>&1
# an existing but unchanged test
git -c user.email=a@b -c user.name=t commit -qm wip --no-verify >/dev/null 2>&1
echo "// again" >> src/main/java/com/acme/OrderService.java
check "an existing-but-unchanged test fails (requireTestChanged)" 1 "was not added/modified in this change" $G test --task "$T"
reverse "requireTestChanged" 1 'if (tg.requireTestChanged && !existing.some((c) => changedSet.has(c))) {' 'if (false) {' chk 1 "was not added/modified in this change" $G test --task "$T"
git checkout -q -- .
# committed changes need --base
echo "// committed edit" >> src/main/java/com/acme/OrderService.java; echo "// t" >> src/test/java/com/acme/OrderServiceTest.java
git add -A >/dev/null 2>&1; git -c user.email=a@b -c user.name=t commit -qm feature --no-verify >/dev/null 2>&1
check "already committed: nothing found against HEAD, with a hint" 0 "already committed\? pass --base" $G test --task "$T"
check "--base <ref> sees the committed change" 0 "ok  src/main/java/com/acme/OrderService.java" $G test --task "$T" --base HEAD~1
reverse "--base is honoured" 1 'const base = typeof opts.base === "string" ? opts.base : "HEAD"' 'const base = "HEAD"' chk 0 "ok  src/main/java/com/acme/OrderService.java" $G test --task "$T" --base HEAD~1

# method-level approximation (multi-line Service so methods have real line spans)
mkdir -p src/main/java/com/acme src/test/java/com/acme
cat > src/main/java/com/acme/ShipService.java <<'X'
package com.acme;
public class ShipService {
    public int pack(String id) {
        return id.length();
    }

    public int send(String id) {
        int n = id.length();
        return n + 1;
    }

    private int helper() {
        return 0;
    }
}
X
cat > src/test/java/com/acme/ShipServiceTest.java <<'X'
package com.acme;
import org.junit.jupiter.api.Test;
class ShipServiceTest { @Test void pack_ok() { new ShipService().pack("a"); } }
X
git add -A >/dev/null 2>&1; git -c user.email=a@b -c user.name=t commit -qm ship --no-verify >/dev/null 2>&1
sed -i 's/return n + 1;/return n + 2;/' src/main/java/com/acme/ShipService.java; echo "// t" >> src/test/java/com/acme/ShipServiceTest.java
meth_warn() { local o; o="$($G test --task "$T" 2>&1)"; local rc=$?; [ $rc -eq 0 ] && echo "$o" | grep -q "changed method(s) never referenced by ShipServiceTest.java: send"; }
check "method-level: a changed method the test never references only warns (default)" 0 "changed method\(s\) never referenced by ShipServiceTest.java: send" $G test --task "$T"
reverse "method-level detection" 1 'if (missing.length) {' 'if (false) {' chk 0 "never referenced by ShipServiceTest.java: send" $G test --task "$T"
reverse "changed lines map to the right method" 1 'for (const m of methods) if (m.start <= b && m.end >= a) names.add(m.name)' 'for (const m of methods) if (m.start <= b && m.end >= a && false) names.add(m.name)' chk 0 "never referenced by ShipServiceTest.java: send" $G test --task "$T"
cp .trellis/plus/plus.config.json "$WORK/i.cfg"
python3 - .trellis/plus/plus.config.json error <<'PY'
import json, sys
f = sys.argv[1]; c = json.load(open(f)); c["testGate"]["methodLevel"] = sys.argv[2]; json.dump(c, open(f, "w"), indent=2)
PY
check "methodLevel=error: the same finding fails the gate" 1 "FAIL  src/main/java/com/acme/ShipService.java" $G test --task "$T"
reverse "methodLevel=error" 1 'if (tg.methodLevel === "error") {' 'if (false) {' chk 1 "FAIL  src/main/java/com/acme/ShipService.java" $G test --task "$T"
python3 - .trellis/plus/plus.config.json off <<'PY'
import json, sys
f = sys.argv[1]; c = json.load(open(f)); c["testGate"]["methodLevel"] = sys.argv[2]; json.dump(c, open(f, "w"), indent=2)
PY
no_meth() { local o; o="$($G test --task "$T" 2>&1)"; local rc=$?; [ $rc -eq 0 ] && ! echo "$o" | grep -q "never referenced"; }
chk 0 - no_meth && ok "methodLevel=off: no method-level finding" || bad "methodLevel=off: no method-level finding"
reverse "methodLevel=off" 1 'if (tg.methodLevel !== "off" &&' 'if (true &&' chk 0 - no_meth
cp "$WORK/i.cfg" .trellis/plus/plus.config.json
sed -i 's/return n + 2;/return n + 1;/' src/main/java/com/acme/ShipService.java; sed -i 's/return 0;/return 1;/' src/main/java/com/acme/ShipService.java
no_meth2() { local o; o="$($G test --task "$T" 2>&1)"; local rc=$?; [ $rc -eq 0 ] && ! echo "$o" | grep -q "never referenced"; }
check "a changed PRIVATE method is not demanded in the test" 0 "ok  src/main/java/com/acme/ShipService.java" $G test --task "$T"
chk 0 - no_meth2 && ok "...and produces no method-level warning" || bad "...and produces no method-level warning"
reverse "private methods are ignored" 1 'const methods = javaMethods(read(abs) ?? "").filter((m) => !m.priv)' 'const methods = javaMethods(read(abs) ?? "")' chk 0 - no_meth2
git checkout -q -- .
printf 'package com.acme;\npublic class NewService {\n    public int a() {\n        return 1;\n    }\n    public int b() {\n        return 2;\n    }\n}\n' > src/main/java/com/acme/NewService.java
printf 'package com.acme;\nimport org.junit.jupiter.api.Test;\nclass NewServiceTest { @Test void a_ok() { new NewService().a(); } }\n' > src/test/java/com/acme/NewServiceTest.java
check "a NEW Service: every public method must be referenced" 0 "never referenced by NewServiceTest.java: b" $G test --task "$T"
rm -f src/main/java/com/acme/NewService.java src/test/java/com/acme/NewServiceTest.java
echo "// c" >> src/main/java/com/acme/OrderController.java; sed -i 's#// t#// t2#' src/test/java/com/acme/OrderControllerTest.java; echo "// t" >> src/test/java/com/acme/OrderControllerTest.java
sed -i 's/class OrderController { public Long post(String no) { return 1L; } }/class OrderController {\n    public Long post(String no) {\n        return 2L;\n    }\n}/' src/main/java/com/acme/OrderController.java
no_ctl() { local o; o="$($G test --task "$T" 2>&1)"; ! echo "$o" | grep -q "never referenced by OrderControllerTest"; }
chk 0 - no_ctl && ok "Controllers are checked by file only (no method-level finding)" || bad "Controllers are checked by file only"
reverse "controllers are exempt from the method-level check" 1 '!/Controller$/.test(basename(f, ".java"))' 'true' chk 0 - no_ctl
git checkout -q -- .

# tier limits in the test gate
TS="$(newtask "$W" tgs)"; $G tier "$TS" S --reason "docs only change" >/dev/null; echo "// s" >> src/main/java/com/acme/OrderService.java; echo "// t" >> src/test/java/com/acme/OrderServiceTest.java
check "tier S + a changed Service fails even with a test" 1 "task is tier S .*changes 1 Service/Controller" $G test --task "$TS"; has "...and says how to raise the tier" "gate tier <task> M\|L"
reverse "tier S forbids Service/Controller changes" 1 'if (ti.tier === "S") rep.error(' 'if (false) rep.error(' chk 1 "task is tier S" $G test --task "$TS"
TLw="$(newtask "$W" tgw)"; echo "x" > "$W/$TLw/.plus-lightweight"
check "legacy .plus-lightweight is enforced the same way" 1 "task is marked lightweight" $G test --task "$TLw"
TMt="$(newtask "$W" tgm)"; $G tier "$TMt" M --reason "single service change" >/dev/null
check "tier M + 1 changed Service with a test passes" 0 "ok  src/main/java/com/acme/OrderService.java" $G test --task "$TMt"
git checkout -q -- .
for n in A B C D; do printf 'package com.acme;\npublic class %sService {\n    public int f() {\n        return 1;\n    }\n}\n' $n > src/main/java/com/acme/${n}Service.java; printf 'package com.acme;\nimport org.junit.jupiter.api.Test;\nclass %sServiceTest { @Test void f_ok() { new %sService().f(); } }\n' $n $n > src/test/java/com/acme/${n}ServiceTest.java; done
git add -A >/dev/null 2>&1; git -c user.email=a@b -c user.name=t commit -qm four --no-verify >/dev/null 2>&1
for n in A B C D; do sed -i 's/return 1;/return 2;/' src/main/java/com/acme/${n}Service.java; echo "// t" >> src/test/java/com/acme/${n}ServiceTest.java; done
check "tier M + 4 changed Services fails" 1 "tier M allows at most 3 Service/Controller classes in one module; this change has 4" $G test --task "$TMt"
reverse "tier M class limit in the test gate" 1 'if (concrete.length > cfg.tiers.maxClassesM || mods.size > 1) rep.error(' 'if (false) rep.error(' chk 1 "tier M allows at most 3" $G test --task "$TMt"
TLt="$(newtask "$W" tgl)"; $G tier "$TLt" L >/dev/null
check "tier L has no class limit" 0 "ok  src/main/java/com/acme/DService.java" $G test --task "$TLt"
git checkout -q -- .; git clean -fdq src

# project root below the git root (changedFiles --relative)
R="$WORK/i8"; rm -rf "$R"; mkdir -p "$R"; cp -r "$BASE" "$R/proj"; ( cd "$R" && git init -q . && git add -A >/dev/null 2>&1 && gc -m init )
node "$TOOL/trellis-plus.mjs" apply "$R/proj" >/dev/null 2>&1
mkdir -p "$R/proj/src/main/java/com/acme" "$R/proj/src/test/java/com/acme"
printf 'package com.acme;\npublic class OrderService {\n    public Long create(String no) {\n        return 1L;\n    }\n}\n' > "$R/proj/src/main/java/com/acme/OrderService.java"
( cd "$R" && git add -A >/dev/null 2>&1 && gc -m java ); echo "// edit" >> "$R/proj/src/main/java/com/acme/OrderService.java"
sub() { ( cd "$R/proj" && node .trellis/plus/gate.mjs test ); }
check "git root above the project: a changed Service without a test is found" 1 "OrderService.java" sub
cp "$W/.trellis/plus/gate.mjs" "$WORK/gate.keep"; W="$R/proj"
reverse "paths are relative to the project root" 1 '"--diff-filter=ACMR", "--relative", base]' '"--diff-filter=ACMR", base]' chk 1 "no unit test found" sub
W="$WORK/i"
fi

############################################################################################################
if want J; then
echo "== J. Maven multi-module: module detection, same-module tests, per-module run commands (fake mvn)"
fresh "$WORK/j"; node "$TOOL/trellis-plus.mjs" apply "$WORK/j" >/dev/null 2>&1; use "$WORK/j"; cd "$W"
for m in "" svc-a svc-b svc-a/inner; do mkdir -p "$m"; echo "<project/>" > "${m:+$m/}pom.xml"; done
mk() { # mk <module-dir-or-.> <Class> : source + test in the same module
  local d="${1%/.}"; [ "$1" = . ] && d=""; local p="${d:+$d/}"
  mkdir -p "${p}src/main/java/x" "${p}src/test/java/x"
  printf 'package x;\npublic class %s { public int f() { return 1; } }\n' "$2" > "${p}src/main/java/x/$2.java"
  printf 'package x;\nimport org.junit.jupiter.api.Test;\nclass %sTest { @Test void f_ok() { new %s().f(); } }\n' "$2" "$2" > "${p}src/test/java/x/${2}Test.java"; }
mk svc-a AService; mk svc-b BService; mk svc-a/inner InnerService; mk . RootService
( git add -A >/dev/null 2>&1; gc -m modules )
touch_all() { for f in svc-a/src/main/java/x/AService svc-b/src/main/java/x/BService svc-a/inner/src/main/java/x/InnerService src/main/java/x/RootService; do echo "// e" >> "$f.java"; done
  for f in svc-a/src/test/java/x/AServiceTest svc-b/src/test/java/x/BServiceTest svc-a/inner/src/test/java/x/InnerServiceTest src/test/java/x/RootServiceTest; do echo "// e" >> "$f.java"; done; }
touch_all; T="$(newtask "$W" mm)"; export FAKE_MVN_LOG="$WORK/mvn.log"; : > "$FAKE_MVN_LOG"
check "four modules, every Service has its own module's test" 0 "ok  svc-a/src/main/java/x/AService.java" $G test --task "$T" --run
LAST="$(cat "$FAKE_MVN_LOG")"
has "run: svc-a gets -pl svc-a -am with only its own test class" "^-q -pl svc-a -am test -Dtest=AServiceTest -Dsurefire.failIfNoSpecifiedTests=false$"
has "run: svc-b gets its own command" "^-q -pl svc-b -am test -Dtest=BServiceTest -Dsurefire.failIfNoSpecifiedTests=false$"
has "run: a nested module uses the NEAREST pom (svc-a/inner)" "^-q -pl svc-a/inner -am test -Dtest=InnerServiceTest "
has "run: the root module has no -pl" "^-q test -Dtest=RootServiceTest -Dsurefire.failIfNoSpecifiedTests=false$"
LAST="$(wc -l < "$FAKE_MVN_LOG" | tr -d ' ')"; has "run: exactly one mvn call per module (4)" "^4$"
chk_log() { : > "$FAKE_MVN_LOG"; $G test --task "$T" --run >/dev/null 2>&1; grep -q "$1" "$FAKE_MVN_LOG"; }
reverse "module grouping" 1 'const mod = moduleOf(f)' 'const mod = ""' chk 0 - chk_log "^-q -pl svc-a -am test -Dtest=AServiceTest "
reverse "-pl command per module" 1 'const tpl = mod ? cfg.testGate.runCommand.replace("{module}", mod) : cfg.testGate.runCommandRoot' 'const tpl = cfg.testGate.runCommandRoot' chk 0 - chk_log "^-q -pl svc-b -am test"
reverse "nearest pom wins" 1 'if (existsSync(resolve(ROOT, d, "pom.xml"))) return d === "." ? "" : d' 'if (d === "svc-a" && existsSync(resolve(ROOT, d, "pom.xml"))) return d' chk 0 - chk_log "^-q -pl svc-a/inner -am test"
# a test of the same name in ANOTHER module does not count
rm -f svc-b/src/test/java/x/BServiceTest.java; cp svc-a/src/test/java/x/AServiceTest.java svc-a/src/test/java/x/BServiceTest.java; sed -i 's/AServiceTest/BServiceTest/; s/AService/BService/' svc-a/src/test/java/x/BServiceTest.java
check "a same-named test in ANOTHER module does not satisfy the gate" 1 'no unit test found in module "svc-b"' $G test --task "$T"
has "...and the expected path is inside svc-b" "svc-b/src/test/java/x/BServiceTest.java"
reverse "tests must live in the same module" 1 'to: "$1src/test/java/$2/$3Test.java" },' 'to: "svc-a/src/test/java/$2/$3Test.java" },' chk 1 'no unit test found in module "svc-b"' $G test --task "$T"
rm -f svc-a/src/test/java/x/BServiceTest.java; git checkout -q -- svc-b/src/test/java/x/BServiceTest.java; echo "// e" >> svc-b/src/test/java/x/BServiceTest.java
# --run only after the static checks pass
rm -f svc-b/src/test/java/x/BServiceTest.java; : > "$FAKE_MVN_LOG"
check "--run: static findings stop before maven" 1 "no unit test found" $G test --task "$T" --run
LAST="$(wc -c < "$FAKE_MVN_LOG" | tr -d ' ')"; has "...maven was not called" "^0$"
reverse "no maven run after a failing static check" 1 'if (opts.run && rep.ok) reps.push(runTests(groups, cfg))' 'if (opts.run) reps.push(runTests(groups, cfg))' chk 0 - bash -c ": > $FAKE_MVN_LOG; node $W/.trellis/plus/gate.mjs test --task $T --run >/dev/null 2>&1; [ ! -s $FAKE_MVN_LOG ]"
git checkout -q -- svc-b/src/test/java/x/BServiceTest.java; echo "// e" >> svc-b/src/test/java/x/BServiceTest.java
# maven failures propagate
export FAKE_MVN_FAIL=1; check "a failing mvn run fails the gate and names the module" 1 'test command for module "svc-a" exited with 1' $G test --task "$T" --run; unset FAKE_MVN_FAIL
reverse "maven exit code is honoured" 1 'if (r.status !== 0) rep.error(`test command for module' 'if (false) rep.error(`test command for module' chk 1 "exited with 1" env FAKE_MVN_FAIL=1 node "$W/.trellis/plus/gate.mjs" test --task "$T" --run
# custom commands from plus.config.json
cp .trellis/plus/plus.config.json "$WORK/j.cfg"
python3 - .trellis/plus/plus.config.json <<'PY'
import json, sys
f = sys.argv[1]; c = json.load(open(f)); c["testGate"]["runCommand"] = "mvn -pl {module} verify -Dtest={classes}"; json.dump(c, open(f, "w"), indent=2)
PY
: > "$FAKE_MVN_LOG"; $G test --task "$T" --run >/dev/null 2>&1; LAST="$(cat "$FAKE_MVN_LOG")"; has "runCommand from plus.config.json is used" "^-pl svc-a verify -Dtest=AServiceTest$"
cp "$WORK/j.cfg" .trellis/plus/plus.config.json
# tier M: one module only
git checkout -q -- . ; git clean -fdq -e .trellis -- . >/dev/null 2>&1
TMm="$(newtask "$W" mmm)"; check "tier M can be set on a clean tree" 0 "tier M set" $G tier "$TMm" M --reason "small change"
echo "// e" >> svc-a/src/main/java/x/AService.java; echo "// e" >> svc-a/src/test/java/x/AServiceTest.java; echo "// e" >> svc-b/src/main/java/x/BService.java; echo "// e" >> svc-b/src/test/java/x/BServiceTest.java
check "tier M: one class per module in 2 modules is still refused" 1 "tier M allows at most 3 Service/Controller classes in one module; this change has 2 in 2 module" $G test --task "$TMm"
reverse "tier M is single-module" 1 '|| mods.size > 1) rep.error(`tier M allows at most ${cfg.tiers.maxClassesM} Service/Controller classes in one module; this change' '|| false) rep.error(`tier M allows at most ${cfg.tiers.maxClassesM} Service/Controller classes in one module; this change' chk 1 "in 2 module" $G test --task "$TMm"
unset FAKE_MVN_LOG
fi

############################################################################################################
if want K; then
echo "== K. OCR gate (fake ocr): triage by severity, rerun budget, background, version"
fresh "$WORK/k"; node "$TOOL/trellis-plus.mjs" apply "$WORK/k" --all >/dev/null 2>&1
( cd "$WORK/k" && git add -A >/dev/null 2>&1 && gc -m plus ); bash "$HERE/mkjava.sh" "$WORK/k" no >/dev/null; use "$WORK/k"; cd "$W"
FXO="$HERE/fixtures/ocr"; export FAKE_OCR_LOG="$WORK/ocr.log"; : > "$FAKE_OCR_LOG"
OS=src/main/java/com/acme/OrderService.java
ocr_with() { local fx="$1"; shift; FAKE_OCR_FINDINGS_FILE="$FXO/$fx" "$@"; }
T="$(newtask "$W" o1)"
check "no report fails with the command to run" 1 "no reviews/ocr-rN.json. Run: node .trellis/plus/gate.mjs ocr --task" $G ocr --task "$T"
check "--run without a triage file fails" 1 "2 finding\(s\) need triage but reviews/ocr-triage.md is missing" $G ocr --task "$T" --run
LAST="$(cat "$FAKE_OCR_LOG")"; has "ocr is called as \`review --audience agent --format json\` (the real ocr has no --output flag)" "^review --audience agent --format json --background-file"
has "...and with the task background file" "--background-file .*reviews/ocr-background.md"
tri "$T" 1 "- [fixed] OrderService.java:8 — [high] possible NPE — added a null check" "- [false-positive] OrderController.java:5 — [low] missing @Valid — validated upstream by the gateway"
check "a complete triage passes" 0 "triage: 2 entr\(ies\) — fixed 1, false-positive 1" $G ocr --task "$T"
tri "$T" 2 "- [fixed] OrderService.java:8 — x" "- [fixed] OrderController.java:5 — y"
check "a triage that names another report fails" 1 "ocr-triage.md refers to ocr-r2.json but the latest report is ocr-r1.json" $G ocr --task "$T"
reverse "triage must name the latest report" 1 'if (Number(rn) !== cur.n) rep.error(' 'if (false) rep.error(' chk 1 "refers to ocr-r2.json" $G ocr --task "$T"
tri "$T" 1 "- [fixed] OrderService.java:8 — [high] NPE — added a null check"
check "a finding without a triage line fails" 1 "finding not triaged: \[low\] OrderController.java:5" $G ocr --task "$T"
reverse "every finding needs a triage line" 1 'if (!e) { rep.error(`finding not triaged' 'if (false) { rep.error(`finding not triaged' chk 1 "finding not triaged" $G ocr --task "$T"
tri "$T" 1 "- [fixed] OrderService.java:8 — [high] NPE — added a null check" "- [pending] OrderController.java:5 — [low] missing @Valid — to look at"
check "[pending] fails" 1 "1 finding\(s\) still \[pending\]" $G ocr --task "$T"
reverse "pending is not a triage result" 1 'if (count("pending")) rep.error(' 'if (false) rep.error(' chk 1 "still \[pending\]" $G ocr --task "$T"
rm -f "$W/$T/reviews/ocr-triage.md"
reverse "a missing triage file is an error" 1 'if (!triage) { rep.error(' 'if (false) { rep.error(' chk 1 "reviews/ocr-triage.md is missing" $G ocr --task "$T"
# severity rules
T2="$(newtask "$W" o2)"; ocr_with findings-critical.json run $G ocr --task "$T2" --run >/dev/null
tri "$T2" 1 "- [deferred] OrderService.java:8 — [critical] SQL injection — later"
check "critical cannot be deferred" 1 "\[critical\] OrderService.java:8 was deferred" $G ocr --task "$T2"
reverse "critical/high cannot be deferred" 1 'if (blocking && e.status === "deferred") rep.error(' 'if (false) rep.error(' chk 1 "was deferred" $G ocr --task "$T2"
tri "$T2" 1 "- [false-positive] OrderService.java:8 — [critical] SQL injection — it is parameterized, trust me"
check "critical false-positive without code evidence fails" 1 "marked false-positive without code evidence" $G ocr --task "$T2"
reverse "false-positive on critical/high needs evidence" 1 'else if (blocking && e.status === "false-positive" && !hasCodeEvidence(e.note)) rep.error(' 'else if (false) rep.error(' chk 1 "without code evidence" $G ocr --task "$T2"
tri "$T2" 1 "- [false-positive] OrderService.java:8 — [critical] SQL injection — no such file src/main/java/com/acme/Nope.java:3 proves it"
check "evidence pointing at a file that does not exist fails" 1 "without code evidence" $G ocr --task "$T2"
reverse "evidence must be a real path:line" 1 'if (abs.startsWith(ROOT) && existsSync(abs) && Number(m[2]) >= 1 && Number(m[2]) <= (read(abs) ?? "").split("\n").length) return true' 'return true' chk 1 "without code evidence" $G ocr --task "$T2"
tri "$T2" 1 "- [false-positive] OrderService.java:8 — [critical] SQL injection — the value is a constant, see $OS:2"
check "evidence with an existing path:line passes" 0 "triage: 1 entr" $G ocr --task "$T2"
tri "$T2" 1 "- [fixed] OrderService.java:8 — [critical] SQL injection — switched to a parameterized query"
check "critical fixed passes" 0 "✓ PASS" $G ocr --task "$T2"
T3="$(newtask "$W" o3)"; ocr_with findings-high-low.json run $G ocr --task "$T3" --run >/dev/null
tri "$T3" 1 "- [fixed] OrderService.java:8 — [high] NPE — added a null check" "- [deferred] OrderController.java:5 — [low] missing @Valid — style, ask the user"
check "a deferred LOW finding passes with a warning for the user" 0 "WARN  1 deferred finding\(s\)" $G ocr --task "$T3"
tri "$T3" 1 "- [fixed] OrderService.java:8 — [high] NPE — added a null check" "- [false-positive] OrderController.java:5 — ok"
check "a low false-positive needs a reason of 10+ chars" 1 "OrderController.java:5 false-positive needs a reason" $G ocr --task "$T3"
reverse "low false-positive needs a reason" 1 'else if (!blocking && e.status === "false-positive" && e.note.length < 10) rep.error(' 'else if (false) rep.error(' chk 1 "false-positive needs a reason" $G ocr --task "$T3"
T4="$(newtask "$W" o4)"; ocr_with findings-no-severity.json run $G ocr --task "$T4" --run >/dev/null
tri "$T4" 1 "- [deferred] OrderService.java:8 — resource not closed — minor, ask the user"
check "a finding without severity is treated as medium (may be deferred)" 0 "medium 1" $G ocr --task "$T4"
reverse "unknown severity defaults to medium" 1 'return "medium" // unknown / missing: still has to be triaged' 'return "high" // unknown / missing: still has to be triaged' chk 0 "medium 1" $G ocr --task "$T4"
T5="$(newtask "$W" o5)"; ocr_with findings-array-root.json run $G ocr --task "$T5" --run >/dev/null
check "--inspect shows the extracted keys (array root, path/start_line/comment)" 0 "keys: file=path line=start_line msg=comment severity=severity" $G ocr --task "$T5" --inspect
tri "$T5" 1 "- [fixed] OrderService.java:8 — unchecked cast — fixed" "- [fixed] StockService.java:3 — unused import — removed"
check "an array-root report with other key names is parsed and triaged" 0 "findings: 2 \(critical 0, high 0, medium 1, low 1\)" $G ocr --task "$T5"
T6="$(newtask "$W" o6)"; ocr_with findings-empty.json run $G ocr --task "$T6" --run >/dev/null
check "no findings: no triage file needed" 0 "findings: 0" $G ocr --task "$T6"
# staleness
T7="$(newtask "$W" o7)"; $G ocr --task "$T7" --run >/dev/null 2>&1; tri "$T7" 1 "- [fixed] OrderService.java:8 — [high] NPE — fixed" "- [fixed] OrderController.java:5 — [low] x — fixed"
check "fresh report + triage passes" 0 "✓ PASS" $G ocr --task "$T7"
sleep 1.3; echo "// edit" >> "$OS"
check "a source edited after the report and its triage makes it STALE" 1 "report is STALE — 1 file\(s\) changed after the report and its triage" $G ocr --task "$T7"
reverse "stale detection" 1 'if (stale.length) rep.error(' 'if (false) rep.error(' chk 1 "report is STALE" $G ocr --task "$T7"
git checkout -q -- "$OS"; echo "x" >> .opencode/agents/trellis-check.md
check "editing only .opencode/ does NOT make the report stale" 0 "✓ PASS" $G ocr --task "$T7"
git checkout -q -- .opencode 2>/dev/null
# rerun budget
T8="$(newtask "$W" o8)"; export FAKE_OCR_FINDINGS_FILE="$FXO/findings-critical.json"
tri "$T8" 1 "- [fixed] OrderService.java:8 — [critical] injection — fixed"
check "run 1 is always allowed" 0 "ocr-r1.json" $G ocr --task "$T8" --run
tri "$T8" 2 "- [fixed] OrderService.java:8 — [critical] injection — fixed again"
check "rerun 1 after a critical finding is allowed" 0 "ocr-r2.json" $G ocr --task "$T8" --run
tri "$T8" 3 "- [fixed] OrderService.java:8 — [critical] injection — fixed once more"
check "rerun 2 is allowed" 0 "ocr-r3.json" $G ocr --task "$T8" --run
check "rerun 3 exceeds ocr.maxRerun=2 and is refused" 1 "would be rerun #3 \(> ocr.maxRerun=2\)" $G ocr --task "$T8" --run
[ ! -e "$W/$T8/reviews/ocr-r4.json" ] && ok "...and no report r4 was written" || bad "...and no report r4 was written"
fourth_run_refused() { local t; t="$(newtask "$W" "cap$RANDOM")"; for n in 1 2 3; do tri "$t" $n "- [fixed] OrderService.java:8 — [critical] injection — fixed"; $G ocr --task "$t" --run >/dev/null 2>&1; done
  local o; o="$($G ocr --task "$t" --run 2>&1)"; local rc=$?; [ $rc -eq 1 ] && echo "$o" | grep -q "ocr.maxRerun=2" && [ ! -e "$W/$t/reviews/ocr-r4.json" ]; }
reverse "rerun cap" 1 'const refused = n > 1 + oc.maxRerun' 'const refused = false && n > 1 + oc.maxRerun' chk 0 - fourth_run_refused
mk3() { local t; t="$(newtask "$W" "f$RANDOM")"; for n in 1 2 3; do tri "$t" $n "- [fixed] OrderService.java:8 — [critical] injection — fixed"; $G ocr --task "$t" --run >/dev/null 2>&1; done; echo "$t"; }
force_noreason() { local t o rc; t="$(mk3)"; o="$($G ocr --task "$t" --run --force 2>&1)"; rc=$?; [ $rc -eq 1 ] && echo "$o" | grep -q -- "--force needs --reason" && [ ! -e "$W/$t/reviews/ocr-r4.json" ]; }
force_reason() { local t o rc; t="$(mk3)"; tri "$t" 4 "- [fixed] OrderService.java:8 — [critical] injection — fixed"; o="$($G ocr --task "$t" --run --force --reason "user approved a 4th round" 2>&1)"; rc=$?
  [ $rc -eq 0 ] && [ -e "$W/$t/reviews/ocr-r4.json" ] && grep -q "user approved a 4th round" "$W/$t/reviews/ocr-overrides.log" && echo "$o" | grep -q "recorded in reviews/ocr-overrides.log"; }
force_warned() { local t o; t="$(mk3)"; $G ocr --task "$t" --run --force --reason "user approved a 4th round" >/dev/null 2>&1; tri "$t" 4 "- [fixed] OrderService.java:8 — [critical] injection — fixed"
  o="$($G ocr --task "$t" 2>&1)"; echo "$o" | grep -q "was used 1 time(s)"; }
no_force_hint() { local t o; t="$(mk3)"; o="$($G ocr --task "$t" --run 2>&1)"; echo "$o" | grep -q "would be rerun #3" && ! echo "$o" | grep -q "override: --force"; }
chk 0 - force_noreason && ok "--force without --reason is refused (no round 4 is written)" || bad "--force without --reason is refused"
chk 0 - force_reason && ok "--force with --reason runs, is logged in reviews/ocr-overrides.log and says so" || bad "--force with --reason runs and is logged"
chk 0 - force_warned && ok "a later check warns that --force was used" || bad "a later check warns that --force was used"
chk 0 - no_force_hint && ok "the refusal no longer advertises --force" || bad "the refusal no longer advertises --force"
reverse "--force needs a reason" 1 'if (why.length < 6) {' 'if (false) {' chk 0 - force_noreason
reverse "--force is logged" 1 'appendFileSync(join(rdir, "ocr-overrides.log"), ' 'void (' chk 0 - force_reason
reverse "--force use is warned about" 1 'if (ov && ov.trim()) rep.warn(' 'if (false) rep.warn(' chk 0 - force_warned
reverse "refusal does not advertise --force" 1 ' — stop and ask the user`' ' — stop and ask the user (override: --force)`' chk 0 - no_force_hint
# the dead end the 5-round run hit: fixing findings changes the source, so the report went STALE and only --force could get past it
OSDEV="$W/$OS"
fix_medium_ok() { local t o rc; t="$(newtask "$W" "fm$RANDOM")"; printf '{"comments":[{"file":"%s","line":2,"severity":"medium","message":"m"}]}' "$OS" > "$WORK/medium2.json"
  FAKE_OCR_FINDINGS_FILE="$WORK/medium2.json" $G ocr --task "$t" --run >/dev/null 2>&1
  sleep 1.3; echo "// fix" >> "$OSDEV"; sleep 1.3; tri "$t" 1 "- [fixed] OrderService.java:2 — [medium] m — fixed"
  o="$($G ocr --task "$t" 2>&1)"; rc=$?; git checkout -q -- "$OS"; [ $rc -eq 0 ] && echo "$o" | grep -q "PASS"; }
fix_after_cap_ok() { local t o rc; t="$(mk3)"; sleep 1.3; echo "// fix" >> "$OSDEV"; sleep 1.3; tri "$t" 3 "- [fixed] OrderService.java:8 — [critical] injection — fixed"
  o="$($G ocr --task "$t" 2>&1)"; rc=$?; git checkout -q -- "$OS"; [ $rc -eq 0 ] && echo "$o" | grep -q "PASS"; }
other_report_stale() { local t o rc; t="$(newtask "$W" "or$RANDOM")"; printf '{"comments":[{"file":"%s","line":2,"severity":"medium","message":"m"}]}' "$OS" > "$WORK/medium2.json"
  FAKE_OCR_FINDINGS_FILE="$WORK/medium2.json" $G ocr --task "$t" --run >/dev/null 2>&1
  sleep 1.3; echo "// fix" >> "$OSDEV"; sleep 1.3; tri "$t" 9 "- [fixed] OrderService.java:2 — [medium] m — fixed"
  o="$($G ocr --task "$t" 2>&1)"; rc=$?; git checkout -q -- "$OS"; [ $rc -eq 1 ] && echo "$o" | grep -q "report is STALE"; }
chk 0 - fix_medium_ok && ok "medium-only report: fixing it and updating the triage passes — no rerun, no --force" || bad "medium-only report: fix + triage passes"
chk 0 - fix_after_cap_ok && ok "after the last allowed round: fixing the critical finding and updating the triage passes — no --force" || bad "after the last round: fix + triage passes"
chk 0 - other_report_stale && ok "a triage that names a different report does not extend the baseline (STALE)" || bad "a triage naming another report keeps STALE"
reverse "triage is the staleness baseline (medium)" 1 'base = Math.max(base, statSync(triFile).mtimeMs)' 'base = base' chk 0 - fix_medium_ok
reverse "triage is the staleness baseline (last round)" 1 'base = Math.max(base, statSync(triFile).mtimeMs)' 'base = base' chk 0 - fix_after_cap_ok
reverse "only a triage of THIS report counts" 1 '=== cur.n) base = Math.max(base' '!== 0) base = Math.max(base' chk 0 - other_report_stale
unset FAKE_OCR_FINDINGS_FILE
no_rerun_after_medium() { local t; t="$(newtask "$W" "nr$RANDOM")"; printf '{"comments":[{"file":"%s","line":2,"severity":"medium","message":"m"}]}' "$OS" > "$WORK/medium.json"
  tri "$t" 1 "- [fixed] OrderService.java:2 — [medium] m — fixed"; FAKE_OCR_FINDINGS_FILE="$WORK/medium.json" $G ocr --task "$t" --run >/dev/null 2>&1
  local o; o="$(FAKE_OCR_FINDINGS_FILE="$WORK/medium.json" $G ocr --task "$t" --run 2>&1)"; local rc=$?; [ $rc -eq 1 ] && echo "$o" | grep -q "has no critical/high finding, so no rerun is needed" && [ ! -e "$W/$t/reviews/ocr-r2.json" ]; }
chk 0 - no_rerun_after_medium && ok "a rerun after a medium-only report is refused (no critical/high finding)" || bad "a rerun after a medium-only report is refused"
reverse "rerun only after critical/high" 1 ': !hasBlocking(cur0.path, oc)' ': false' chk 0 - no_rerun_after_medium
# background file
mkbig() { local t="$1"
  python3 - "$W" "$t" <<'PY'
import json, sys, os
w, t = sys.argv[1], sys.argv[2]
tj = os.path.join(w, t, "task.json"); d = json.load(open(tj, encoding="utf8")); d["title"] = "背景测试 " + "T" * 4000; json.dump(d, open(tj, "w", encoding="utf8"), ensure_ascii=False, indent=2)
PY
  local rows=""; for i in $(seq 1 20); do rows="$rows| R$i | $(printf 'r%.0s' $(seq 1 150)) | acc |\n"; done
  { printf '# t\n\n对齐状态：已对齐\n\n## 2 需求与验收\n\n| 编号 | 需求 | 验收 |\n| --- | --- | --- |\n'; printf "$rows"; printf '\n## 4 决策记录\n\n| 编号 | 问题 | 结论 | 来源 | 影响 |\n| --- | --- | --- | --- | --- |\n'; for i in $(seq 1 10); do echo "| D$i | $(printf 'q%.0s' $(seq 1 100)) | c | s | R1 |"; done; printf '\n## 5 待确认问题\n\n无\n'; } > "$W/$t/prd.md"
  { printf '# impl\n\n## 1 实施步骤\n\n'; for i in $(seq 1 40); do printf '### 步骤 %s：f\n\n- 文件：`src/main/java/com/acme/pkg%s/Some%sThing.java`\n\n' $i $i $i; done; printf '## 2 测试矩阵\n\n## 3 测试豁免\n\n无\n'; } > "$W/$t/implement.md"; }
chars() { python3 -c "import sys; print(len(open(sys.argv[1], encoding='utf8').read()))" "$1"; }
T="$(newtask "$W" bg)"; mkbig "$T"; $G ocr --task "$T" --run >/dev/null 2>&1; BG="$W/$T/reviews/ocr-background.md"
LAST="$(chars "$BG")"; [ "$LAST" -le 3000 ] && ok "background file is <= 3000 chars ($LAST) even with a 4000-char title, 20 requirements, 10 decisions, 40 files" || bad "background file is <= 3000 chars ($LAST)"
LAST="$(cat "$BG")"; has "background keeps the review instructions (shrunk by dropping items, not by cutting the tail)" "## Review instructions"; has "background contains requirements" "## Requirements \(prd.md\)"; has "background says it was truncated" "\(truncated\)"
LAST="$(grep '^Task:' "$BG" | head -1 | python3 -c 'import sys; print(len(sys.stdin.read()))')"; [ "$LAST" -le 340 ] && ok "the task title is capped ($LAST chars incl. prefix)" || bad "the task title is capped ($LAST)"
bg_fresh() { local t; t="$(newtask "$W" "bgx$RANDOM")"; mkbig "$t"; $G ocr --task "$t" --run >/dev/null 2>&1; BGF="$W/$t/reviews/ocr-background.md"; }
bg_ok() { bg_fresh; [ "$(chars "$BGF")" -le 3000 ] && grep -q "## Review instructions" "$BGF"; }
title_capped() { bg_fresh; [ "$(grep '^Task:' "$BGF" | head -1 | python3 -c 'import sys; print(len(sys.stdin.read()))')" -le 340 ]; }
reverse "task title cap" 1 '.slice(0, 120)}${tj.description' '}${tj.description' chk 0 - title_capped
reverse "background shrinks by dropping items" 1 'shrink(exLines, 0); shrink(files, 3); shrink(decLines, 0); shrink(reqLines, 3)' '' chk 0 - bg_ok
# --background-file unknown to this ocr build
T11="$(newtask "$W" o11)"; : > "$FAKE_OCR_LOG"
check "an ocr build without --background-file: retry without it, with a warning" 1 "WARN  this ocr build does not know --background-file" env FAKE_OCR_REJECT_BACKGROUND=1 $G ocr --task "$T11" --run
LAST="$(cat "$FAKE_OCR_LOG")"; has "...the retry call has no --background-file" "^review --audience agent --format json$"
reverse "background retry" 1 'if (r.status !== 0 && bg.length && /background/i.test(r.stderr || "")' 'if (false && /background/i.test(r.stderr || "")' chk 1 "WARN  this ocr build does not know" env FAKE_OCR_REJECT_BACKGROUND=1 $G ocr --task "$(newtask "$W" o12)" --run
# --- real ocr v1.9.8 report shape (comments[] with path / content / start_line / severity; status partial; manifest) ---
T9="$(newtask "$W" o9)"; ocr_with real-partial.json $G ocr --task "$T9" --run >/dev/null
check "real report: a partial status warns and names the file that was NOT reviewed" 1 'ocr report status is "partial".*NOT reviewed: 003_insert.sql' $G ocr --task "$T9"
reverse "partial status warning" 1 'if (meta && meta.status && meta.status !== "complete") rep.warn(' 'if (false) rep.warn(' chk 1 'ocr report status is "partial"' $G ocr --task "$T9"
check "real report: --inspect shows the real keys (path / start_line / content / severity)" 0 "keys: file=path line=start_line msg=content severity=severity" $G ocr --task "$T9" --inspect
LAST="$($G ocr --task "$T9" --inspect 2>&1)"; has "...and extracts exactly the 6 comments, nothing from the manifest" "6 finding\(s\) extracted"
python3 - "$FXO" "$WORK" <<'PY'
import json, sys
d = json.load(open(sys.argv[1] + "/real-partial.json", encoding="utf8")); d["hints"] = [{"path": "Decoy.java", "start_line": 1, "content": "looks like a finding but is not under comments"}]
json.dump(d, open(sys.argv[2] + "/decoy.json", "w", encoding="utf8"), ensure_ascii=False)
json.dump({"status": "complete", "comments": [{"severity": "high"}]}, open(sys.argv[2] + "/nofields.json", "w"))
PY
T9b="$(newtask "$W" o9b)"; FAKE_OCR_FINDINGS_FILE="$WORK/decoy.json" $G ocr --task "$T9b" --run >/dev/null
check "comments[] is the single source: a finding-like object elsewhere in the document is ignored" 0 "6 finding\(s\) extracted" $G ocr --task "$T9b" --inspect
reverse "comments[] is the single source of findings" 1 'if (root && !Array.isArray(root) && typeof root === "object" && Array.isArray(root.comments)) {' 'if (false) {' chk 0 "6 finding\(s\) extracted" $G ocr --task "$T9b" --inspect
T9c="$(newtask "$W" o9c)"; FAKE_OCR_FINDINGS_FILE="$WORK/nofields.json" $G ocr --task "$T9c" --run >/dev/null
check "a comment without path/line/text is still a finding (never silently dropped)" 0 "1 finding\(s\) extracted" $G ocr --task "$T9c" --inspect
reverse "a comment entry is never dropped" 1 'if (root && !Array.isArray(root) && typeof root === "object" && Array.isArray(root.comments)) {' 'if (false) {' chk 0 "1 finding\(s\) extracted" $G ocr --task "$T9c" --inspect
tri "$T9" 1 "- [fixed] OrderService.java:3 — [medium] retCode check added" "- [fixed] OrderService.java:8 — [high] path traversal rejected" "- [fixed] OrderService.java:8 — [high] rollback on failure added" "- [fixed] OrderController.java:5 — [low] renamed" "- [fixed] 001_rollback.sql:7 — [low] IF EXISTS added" "- [fixed] 003_insert.sql:15 — [medium] insert first"
check "real report: one triage line per finding passes (the status warning stays visible)" 0 "findings: 6 \(critical 0, high 2, medium 2, low 2\)" $G ocr --task "$T9"
tri "$T9" 1 "- [fixed] OrderService.java:3 — [medium] retCode check added" "- [fixed] OrderService.java:8 — [high] path traversal rejected" "- [fixed] OrderController.java:5 — [low] renamed" "- [fixed] 001_rollback.sql:7 — [low] IF EXISTS added" "- [fixed] 003_insert.sql:15 — [medium] insert first"
check "two findings on the same file:line need two triage lines" 1 "finding not triaged: \[high\] OrderService.java:8" $G ocr --task "$T9"
reverse "an entry is not reused by a second finding" 1 'c = entries.filter((e) => !e.used && basename(e.file)' 'c = entries.filter((e) => basename(e.file)' chk 1 "finding not triaged: \[high\] OrderService.java:8" $G ocr --task "$T9"
tri "$T9" 1 "- [fixed] OrderService.java:4 — [medium] wrong line" "- [fixed] OrderService.java:8 — [high] a" "- [fixed] OrderService.java:8 — [high] b" "- [fixed] OrderController.java:5 — [low] renamed" "- [fixed] 001_rollback.sql:7 — [low] IF EXISTS added" "- [fixed] 003_insert.sql:15 — [medium] insert first"
check "triage lines are matched on start_line (a wrong line is not accepted)" 1 "finding not triaged: \[medium\] OrderService.java:3" $G ocr --task "$T9"
reverse "start_line is the line key of a real report" 1 'line: ["line", "start_line",' 'line: ["line", "xx_start_line",' chk 1 "finding not triaged: \[medium\] OrderService.java:3" $G ocr --task "$T9"
T9d="$(newtask "$W" o9d)"; ocr_with real-empty-complete.json $G ocr --task "$T9d" --run >/dev/null
check "status complete with comments [] → no triage needed" 0 "findings: 0" $G ocr --task "$T9d"
LAST="$($G ocr --task "$T9d" 2>&1)"; hasnt "...and no partial warning" "ocr report status"
# The real ocr has no --output flag (ocr review --help): the report is printed on stdout and the gate saves it as ocr-r<N>.json
: > "$FAKE_OCR_LOG"; T9e="$(newtask "$W" o9e)"
check "the report is taken from stdout and saved as ocr-r1.json" 0 "report: .*ocr-r1.json" env FAKE_OCR_FINDINGS_FILE="$FXO/real-empty-complete.json" $G ocr --task "$T9e" --run
[ -s "$W/$T9e/reviews/ocr-r1.json" ] && ok "...and ocr-r1.json exists and is JSON" || bad "...and ocr-r1.json exists"
LAST="$(cat "$FAKE_OCR_LOG")"; hasnt "...and --output is never passed to ocr" "--output"
reverse "ocr is not called with --output (the real ocr rejects it)" 1 'const base = ["review", "--audience", "agent", "--format", "json"]' 'const base = ["review", "--audience", "agent", "--format", "json", "--output", out]' chk 0 "report: .*ocr-r1.json" env FAKE_OCR_FINDINGS_FILE="$FXO/real-empty-complete.json" $G ocr --task "$(newtask "$W" o9f)" --run
quiet_report() { local o; o="$(FAKE_OCR_FINDINGS_FILE="$FXO/real-partial.json" $G ocr --task "$(newtask "$W" "q$RANDOM")" --run 2>&1)"; ! echo "$o" | grep -qE 'session_id|existing_code'; }
chk 0 - quiet_report && ok "the full JSON report is not echoed into the conversation (it stays in ocr-rN.json)" || bad "the full JSON report is not echoed"
reverse "the report stays on disk, not on screen" 1 'writeFileSync(out, JSON.stringify(j, null, 2) + "\n") //' 'process.stdout.write(r.stdout); writeFileSync(out, JSON.stringify(j, null, 2) + "\n") //' chk 0 - quiet_report
check "ocr printing no JSON at all is an error (never a silent pass)" 1 "printed no JSON report on stdout" env FAKE_OCR_NO_JSON=1 $G ocr --task "$(newtask "$W" o9i)" --run
reverse "no JSON on stdout is an error" 1 'rep.error(`ocr exited with ${r.status ?? r.error?.message} and printed no JSON report on stdout`)' 'rep.note("x")' chk 1 "printed no JSON report" env FAKE_OCR_NO_JSON=1 $G ocr --task "$(newtask "$W" o9j)" --run
check "ocr exiting non-zero but printing the report: kept, with a warning" 1 "WARN  ocr exited with 3 \(JSON report printed" env FAKE_OCR_EXIT=3 $G ocr --task "$(newtask "$W" o9k)" --run
reverse "non-zero exit warning" 1 'if (r.status !== 0) rep.warn(`ocr exited with ${r.status} (JSON report printed' 'if (false) rep.warn(`ocr exited with ${r.status} (JSON report printed' chk 1 "WARN  ocr exited with 3" env FAKE_OCR_EXIT=3 $G ocr --task "$(newtask "$W" o9l)" --run
python3 - "$FXO" "$WORK" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1] + "/real-partial.json", encoding="utf8")); d["comments"] = []; d["summary"]["comments"] = 0
c = d["manifest"]["coverage"]; c["failed"] = c["selected"]; c["completed"] = []; d["status"] = "failed"; d["message"] = "Review failed: 5 of 5 selected item(s) failed."
json.dump(d, open(sys.argv[2] + "/none-reviewed.json", "w", encoding="utf8"), ensure_ascii=False)
PY2
TN="$(newtask "$W" o9m)"; FAKE_OCR_FINDINGS_FILE="$WORK/none-reviewed.json" $G ocr --task "$TN" --run >/dev/null 2>&1
check "every selected file failed: no comments is NOT a clean review (error)" 1 "ocr reviewed none of the 5 selected file\(s\)" $G ocr --task "$TN"
reverse "an all-failed run is an error" 1 'if (meta && meta.selected > 0 && meta.completed === 0) rep.error(' 'if (false) rep.error(' chk 1 "reviewed none of the 5" $G ocr --task "$TN"
# availability = `ocr llm test`; no version / git checks; failure -> delegation mode (ocr.mode: auto | cli | delegate)
NB="$WORK/nobin"; mkdir -p "$NB"; for b in node git python3; do ln -sf "$(command -v $b)" "$NB/$b"; done
setmode() { python3 - "$W/.trellis/plus/plus.config.json" "$1" <<'PY2'
import json, sys
f = sys.argv[1]; d = json.load(open(f, encoding="utf8")); d.setdefault("ocr", {})["mode"] = sys.argv[2]; json.dump(d, open(f, "w", encoding="utf8"), indent=2)
PY2
}
cp "$W/.trellis/plus/plus.config.json" "$WORK/k.cfg"
: > "$FAKE_OCR_LOG"; TA="$(newtask "$W" m1)"; $G ocr --task "$TA" --run >/dev/null 2>&1
LAST="$(head -1 "$FAKE_OCR_LOG")"; has "auto: the first ocr call is \`llm test\`, before any review" "^llm test$"
LAST="$(sed -n 2p "$FAKE_OCR_LOG")"; has "...and the review follows" "^review --audience agent"
check "an old ocr version is NOT refused any more (no version check)" 0 "report: .*ocr-r1.json" env FAKE_OCR_VERSION=0.0.1 FAKE_OCR_FINDINGS_FILE="$FXO/findings-empty.json" $G ocr --task "$(newtask "$W" m2)" --run
LAST="$(grep -c 'minGitVersion\|minVersion\|verGte' "$W/.trellis/plus/gate.mjs")"; has "gate.mjs has no ocr/git version check left" "^0$"
: > "$FAKE_OCR_LOG"; TB="$(newtask "$W" m3)"
check "auto + \`ocr llm test\` fails -> DELEGATION MODE (exit 0, warning, instructions)" 0 "WARN  OCR is not usable .*llm test.* exited with 1.*DELEGATION MODE" env FAKE_OCR_LLM_TEST_EXIT=1 $G ocr --task "$TB" --run
LAST="$(env FAKE_OCR_LLM_TEST_EXIT=1 $G ocr --task "$TB" --run 2>&1)"; has "...the instructions name the report file and its shape" 'ocr-r1.json as: \{"status":"complete","comments":\[\{"path"'
LAST="$(cat "$FAKE_OCR_LOG")"; hasnt "...and ocr review was never called" "^review "
[ ! -e "$W/$TB/reviews/ocr-r1.json" ] && ok "...and no report was invented" || bad "...and no report was invented"
reverse "llm test failure triggers the fallback" 1 'if (t.error || t.status !== 0) why =' 'if (false) why =' chk 0 "DELEGATION MODE" env FAKE_OCR_LLM_TEST_EXIT=1 $G ocr --task "$(newtask "$W" m4)" --run
check "ocr missing (not on PATH) -> DELEGATION MODE" 0 "ocr. not found.*DELEGATION MODE|not found\) → DELEGATION MODE" env PATH="$NB" $G ocr --task "$(newtask "$W" m5)" --run
reverse "a missing ocr falls back too" 1 'if (t.error || t.status !== 0) why =' 'if (false) why =' chk 0 "DELEGATION MODE" env PATH="$NB" $G ocr --task "$(newtask "$W" m6)" --run
# a delegated report is accepted and triaged like an ocr report
TC="$(newtask "$W" m7)"; mkdir -p "$W/$TC/reviews"
printf '{"status":"complete","comments":[{"path":"%s","start_line":8,"end_line":9,"severity":"high","category":"bug","content":"possible NPE"}]}' "$OS" > "$W/$TC/reviews/ocr-r1.json"
check "delegated report without a triage file fails like an ocr report" 1 "1 finding\(s\) need triage" $G ocr --task "$TC"
tri "$TC" 1 "- [fixed] OrderService.java:8 — [high] possible NPE — added a null check"
check "delegated report + triage passes" 0 "✓ PASS" $G ocr --task "$TC"
# modes
setmode cli
check "mode cli + llm test fails -> error, no fallback" 1 'ocr.mode is "cli", so there is no fallback' env FAKE_OCR_LLM_TEST_EXIT=1 $G ocr --task "$(newtask "$W" m8)" --run
reverse "cli mode has no fallback" 1 'if (oc.mode === "cli") { rep.error(' 'if (false) { rep.error(' chk 1 'so there is no fallback' env FAKE_OCR_LLM_TEST_EXIT=1 $G ocr --task "$(newtask "$W" m9)" --run
check "mode cli + working ocr runs it" 0 "report: .*ocr-r1.json" env FAKE_OCR_FINDINGS_FILE="$FXO/findings-empty.json" $G ocr --task "$(newtask "$W" m10)" --run
setmode delegate; : > "$FAKE_OCR_LOG"
check "mode delegate: never calls ocr, prints the instructions" 0 'ocr.mode is "delegate".*DELEGATION MODE' $G ocr --task "$(newtask "$W" m11)" --run
[ ! -s "$FAKE_OCR_LOG" ] && ok "...and ocr was not called at all (not even llm test)" || bad "...and ocr was not called at all"
reverse "delegate mode never calls ocr" 1 'if (oc.mode === "delegate") why =' 'if (false) why =' chk 0 'ocr.mode is "delegate"' $G ocr --task "$(newtask "$W" m12)" --run
cp "$WORK/k.cfg" "$W/.trellis/plus/plus.config.json"
# summary.comments must match the extracted comments (a dropped finding is a silent pass)
python3 - "$FXO" "$WORK" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1] + "/real-partial.json", encoding="utf8")); d["summary"]["comments"] = d["summary"]["comments"] + 1
json.dump(d, open(sys.argv[2] + "/count-mismatch.json", "w", encoding="utf8"), ensure_ascii=False)
PY2
TD="$(newtask "$W" m13)"; FAKE_OCR_FINDINGS_FILE="$WORK/count-mismatch.json" $G ocr --task "$TD" --run >/dev/null
check "summary.comments != extracted comments -> error" 1 "report says summary.comments=7 but 6 comment\(s\) were extracted" $G ocr --task "$TD"
reverse "summary.comments reconciliation" 1 'if (claimed !== null && claimed !== findings.length) rep.error(' 'if (false) rep.error(' chk 1 "report says summary.comments=7" $G ocr --task "$TD"
LAST="$($G ocr --task "$T9" --inspect 2>&1)"; hasnt "a consistent real report has no count error" "summary.comments="
unset FAKE_OCR_LOG
fi

############################################################################################################
if want L; then
echo "== L. git pre-commit hook and task selection (session / TRELLIS_PLUS_TASK / the only in_progress task)"
fresh "$WORK/l"; node "$TOOL/trellis-plus.mjs" apply "$WORK/l" --all >/dev/null 2>&1
( cd "$WORK/l" && git add -A >/dev/null 2>&1 && gc -m plus ); bash "$HERE/mkjava.sh" "$WORK/l" no >/dev/null; use "$WORK/l"; cd "$W"
cat > src/test/java/com/acme/OrderControllerTest.java <<'X'
package com.acme;
import org.junit.jupiter.api.Test;
class OrderControllerTest { @Test void post_ok() {} }
X
sed -i 's/void helperOnly() {}/@org.junit.jupiter.api.Test void left_ok() {}/' src/test/java/com/acme/StockServiceTest.java
git add -A >/dev/null 2>&1; git -c user.email=a@b -c user.name=t commit -qm complete --no-verify >/dev/null 2>&1
export FAKE_OCR_FINDINGS_FILE="$HERE/fixtures/ocr/findings-high-low.json"
gcm() { git -c user.email=a@b -c user.name=t commit -q -m "$1" 2>&1; }          # a real commit: the hook runs
stage_ok() { echo "// $RANDOM" >> src/main/java/com/acme/OrderService.java; echo "// $RANDOM" >> src/test/java/com/acme/OrderServiceTest.java; git add src; }
unstage() { git reset -q; git checkout -q -- .; }
check "the hook is installed and executable" 0 "trellis-plus" bash -c "test -x $W/.git/hooks/pre-commit && grep -c '>>> trellis-plus >>>' $W/.git/hooks/pre-commit && cat $W/.git/hooks/pre-commit"
echo "doc" > README.md; git add README.md
check "a commit that stages no source files passes untouched" 0 - gcm docs
echo "// x" >> src/main/java/com/acme/OrderService.java; git add src
check "hook: source change without a changed test is blocked" 1 "commit blocked by the pre-commit hook" gcm nope
has "...with the reason" "was not added/modified in this change"; has "...and how to bypass" "TRELLIS_PLUS_SKIP_GATE=1 git commit"
unstage
stage_ok
check "hook: no task and tests are fine → the commit goes through, OCR is skipped with a note" 0 - gcm "no task"
LAST="$(cd "$W" && stage_ok && git -c user.email=a@b -c user.name=t commit -q -m t2 2>&1; true)"; has "...the note says the commit is not part of a Trellis task" "no in_progress task — OCR check skipped"
reverse "hook without a task skips OCR (does not block)" 1 '} else if (opts.hook) rep.note("no in_progress task' '} else if (false) rep.note("no in_progress task' chk 0 - bash -c "cd $W && echo '// $RANDOM' >> src/main/java/com/acme/OrderService.java && echo '// $RANDOM' >> src/test/java/com/acme/OrderServiceTest.java && git add src && node .trellis/plus/gate.mjs pre-commit --hook; rc=\$?; git reset -q; git checkout -q -- .; exit \$rc"
# Trellis's own bootstrap task is in_progress in every fresh project and must not count as a candidate
BS=".trellis/tasks/00-bootstrap-guidelines"; python3 -c "import json,sys; sys.exit(0 if json.load(open('$W/$BS/task.json'))['status']=='in_progress' else 1)" && ok "precondition: BASE carries 00-bootstrap-guidelines as in_progress" || bad "precondition: 00-bootstrap-guidelines is in_progress in BASE"
only_bootstrap() { env -u TRELLIS_CONTEXT_ID $G ocr 2>&1 | grep -q "active task not found"; }
chk 0 - only_bootstrap && ok "CLI: with only the bootstrap task in_progress there is no active task" || bad "CLI: with only the bootstrap task in_progress there is no active task"
reverse "the bootstrap task is not a candidate" 1 'if (/^00-bootstrap/.test(d)) continue' '' chk 0 - only_bootstrap
# one in_progress task → OCR is required
TA="$(newtask "$W" ha)"; TB="$(newtask "$W" hb)"
for t in "$TA"; do $G tier "$t" L >/dev/null; for k in implement check; do echo '{"file":".trellis/spec/backend/index.md","reason":"spec"}' >> "$W/$t/$k.jsonl"; done; done
TRELLIS_PLUS_SKIP_GATE=1 python3 .trellis/scripts/task.py start "$TA" >/dev/null 2>&1
stage_ok
check "hook: the ONLY in_progress task is used, its OCR report is required" 1 "no reviews/ocr-rN.json. Run: node .trellis/plus/gate.mjs ocr --task $TA" gcm withtask
has "...and the hook message names that task" "OCR:  node .trellis/plus/gate.mjs ocr --task $TA --run"
$G ocr --task "$TA" --run >/dev/null 2>&1; tri "$TA" 1 "- [fixed] OrderService.java:8 — [high] NPE — added a null check" "- [fixed] OrderController.java:5 — [low] x — fixed"
check "hook: with a fresh report and a complete triage the commit goes through" 0 - gcm withreport
# two in_progress tasks, no session context
for k in implement check; do echo '{"file":".trellis/spec/backend/index.md","reason":"spec"}' >> "$W/$TB/$k.jsonl"; done
TRELLIS_PLUS_SKIP_GATE=1 python3 .trellis/scripts/task.py start "$TB" >/dev/null 2>&1
python3 -c "import json; print(sorted(d['status'] for d in [json.load(open('$W/$TA/task.json')), json.load(open('$W/$TB/task.json'))]))" | grep -q "in_progress.*in_progress" && ok "precondition: two real tasks are in_progress" || bad "precondition: two real tasks are in_progress"
stage_ok; export -n TRELLIS_CONTEXT_ID
check "CLI: two in_progress tasks and no hint → refuses to guess" 1 "2 tasks are in_progress \($TA, $TB\) and nothing says which one" env -u TRELLIS_CONTEXT_ID $G ocr
reverse "never 'newest wins'" 1 'if (all.length === 1) {' 'if (all.length >= 1) {' chk 1 "2 tasks are in_progress" env -u TRELLIS_CONTEXT_ID $G ocr
check "hook: two in_progress tasks → OCR check skipped with a warning, tests still enforced" 0 "WARN  OCR check skipped: 2 tasks are in_progress" env -u TRELLIS_CONTEXT_ID node "$W/.trellis/plus/gate.mjs" pre-commit --hook
reverse "ambiguity is a warning in the hook" 1 'if (opts.hook) rep.warn(`OCR check skipped: ${m}`); else rep.error(m)' 'rep.error(m)' chk 0 "WARN  OCR check skipped" env -u TRELLIS_CONTEXT_ID node "$W/.trellis/plus/gate.mjs" pre-commit --hook
check "TRELLIS_PLUS_TASK picks the task" 1 "no reviews/ocr-rN.json. Run: node .trellis/plus/gate.mjs ocr --task $TB" env -u TRELLIS_CONTEXT_ID TRELLIS_PLUS_TASK="$TB" $G ocr
reverse "TRELLIS_PLUS_TASK" 1 'const env = process.env.TRELLIS_PLUS_TASK' 'const env = ""' chk 1 "ocr --task $TB" env -u TRELLIS_CONTEXT_ID TRELLIS_PLUS_TASK="$TB" $G ocr
check "--task beats TRELLIS_PLUS_TASK" 0 "latest report: $TA/reviews/ocr-r1.json" env -u TRELLIS_CONTEXT_ID TRELLIS_PLUS_TASK="$TB" $G ocr --task "$TA" 
check "an unknown TRELLIS_PLUS_TASK is a usage error" 2 "task directory not found: nope" env -u TRELLIS_CONTEXT_ID TRELLIS_PLUS_TASK=nope $G ocr
export TRELLIS_CONTEXT_ID=plusreg
check "the session task (TB: the last one started in this session) wins over 'ambiguous'" 1 "ocr --task $TB --run" $G ocr
reverse "the session task is consulted" 1 'if (r.status === 0 && r.stdout) {' 'if (false) {' chk 1 "ocr --task $TB --run" $G ocr
check "the pre-commit hook honours the session task too" 0 "OCR|ocr-gate" bash -c "cd $W && node .trellis/plus/gate.mjs pre-commit --hook | head -20"
unstage
# bypass
stage_ok; echo "// y" >> src/main/java/com/acme/PayServiceImpl.java; git add src
check "the hook blocks a change without a test" 1 "commit blocked" gcm blocked
check "TRELLIS_PLUS_SKIP_GATE=1 git commit bypasses the hook" 0 - env TRELLIS_PLUS_SKIP_GATE=1 git -c user.email=a@b -c user.name=t commit -q -m skip
echo "// z" >> src/main/java/com/acme/PayServiceImpl.java; git add src
check "git commit --no-verify bypasses the hook" 0 - git -c user.email=a@b -c user.name=t commit -q --no-verify -m nv
check "gate pre-commit --hook honours TRELLIS_PLUS_SKIP_GATE" 0 "TRELLIS_PLUS_SKIP_GATE is set — skipped" env TRELLIS_PLUS_SKIP_GATE=1 node "$W/.trellis/plus/gate.mjs" pre-commit --hook
reverse "skip env inside the gate" 1 'if (hook && process.env.TRELLIS_PLUS_SKIP_GATE) {' 'if (false) {' chk 0 "TRELLIS_PLUS_SKIP_GATE is set — skipped" env TRELLIS_PLUS_SKIP_GATE=1 node "$W/.trellis/plus/gate.mjs" pre-commit --hook
# nothing to gate
git reset -q; git checkout -q -- .; echo "doc2" >> README.md; git add README.md
check "pre-commit --hook with only non-source files staged: nothing to gate" 0 "nothing to gate" node "$W/.trellis/plus/gate.mjs" pre-commit --hook
reverse "hook ignores commits without source files" 1 'if (!sf.some((f) => isSource(f, cfg.ocr) || matchAny(cfg.testGate.include, f))) {' 'if (false) {' chk 0 "nothing to gate" node "$W/.trellis/plus/gate.mjs" pre-commit --hook
git reset -q; git checkout -q -- .
# the project below the git root: the hook path is relative to the repository top
R="$WORK/l8"; rm -rf "$R"; mkdir -p "$R"; cp -r "$BASE" "$R/proj"; ( cd "$R" && git init -q . && git add -A >/dev/null 2>&1 && gc -m init )
node "$TOOL/trellis-plus.mjs" apply "$R/proj" --git-hook >/dev/null 2>&1
mkdir -p "$R/proj/src/main/java/com/acme"; printf 'package com.acme;\npublic class OrderService {\n    public Long create(String no) {\n        return 1L;\n    }\n}\n' > "$R/proj/src/main/java/com/acme/OrderService.java"
( cd "$R" && git add -A >/dev/null 2>&1 && gc -m java ); echo "// e" >> "$R/proj/src/main/java/com/acme/OrderService.java"; ( cd "$R" && git add -A )
LAST="$(cd "$R" && git -c user.email=a@b -c user.name=t commit -q -m sub 2>&1)"; RC=$?; exit_is "project below the git root: the hook (run from the repo top) blocks a Service without a test" 1; has "...naming the right file" "proj/src/main/java/com/acme/OrderService.java|src/main/java/com/acme/OrderService.java"
unset FAKE_OCR_FINDINGS_FILE
fi

############################################################################################################
if want M; then
echo "== M. shipped assets: reviewer agent, token budget of the workflow blocks, samples, no stale references"
AG="$TOOL/assets/agents/plus-design-reviewer.md"
[ "$(ls "$TOOL/assets/agents" | tr '\n' ' ')" = "plus-design-reviewer.md " ] && ok "exactly one reviewer agent is shipped (no accuracy/coverage/impact trio)" || bad "exactly one reviewer agent is shipped"
agent_ok() { local f="$1"; head -1 "$f" | grep -q '^---$' && ! grep -q '^model:' "$f" && grep -q 'Recursion Guard' "$f" \
  && for k in 需求覆盖矩阵 问题清单 假设清单 需人工确认 已检查 '^阻塞：<' '^轮次：<' '^需人工确认：<' 'design-review.md' 'Round: N' 'Changed sections'; do grep -qE -- "$k" "$f" || { echo "missing: $k"; return 1; }; done \
  && ! grep -qE '\[(需求文档|设计文档|代码).*(路径|目录)\]' "$f"; }
check "reviewer agent: frontmatter, no model:, recursion guard, the five output parts, header lines, incremental round 2, no unreplaced [路径] placeholders" 0 - agent_ok "$AG"
cp "$AG" "$WORK/agent.bad"; edit "$WORK/agent.bad" "mode: subagent" $'mode: subagent\nmodel: some-model'
check "reverse: an agent that pins a model is rejected" 1 - agent_ok "$WORK/agent.bad"
cp "$AG" "$WORK/agent.bad2"; edit "$WORK/agent.bad2" "需人工确认：<需人工确认一节的条数>" "（头部被删）"
check "reverse: an agent without the 需人工确认 header line is rejected" 1 "missing: \^需人工确认：<" agent_ok "$WORK/agent.bad2"
# token budget of the per-project workflow blocks (v1.1: 9511 bytes) and the per-turn breadcrumbs (checked in A)
wf_bytes() { cat "$1/assets/workflow/index.md" "$1/assets/workflow/phase1.md" "$1/assets/workflow/phase2.md" | wc -c | tr -d ' '; }
wf_budget() { [ "$(wf_bytes "$1")" -le 7000 ]; }
LAST="$(wf_bytes "$TOOL")"; has "workflow blocks total $LAST bytes (v1.1: 9511)" "^[0-9]+$"
check "workflow blocks stay within 7000 bytes (regression line for the token goal)" 0 - wf_budget "$TOOL"
sec3_clean() { local d="$1" f
  for f in "$d/assets/plus/templates/design.md" "$d/assets/spec/plus-doc-samples/design.md"; do
    sed -n '/^## 3 /,/^## 4 /p' "$f" | grep -qE '^\| 方案 \|' && return 1
    sed -n '/^## 3 /,/^## 4 /p' "$f" | grep -q '方案摘要' || return 1
  done; return 0; }
chk 0 - sec3_clean "$TOOL" && ok "design template and sample: 整体方案 holds only the chosen solution (no alternatives table)" || bad "design template/sample 整体方案 has no alternatives table"
reverse_file "template 整体方案 has no table" assets/plus/templates/design.md 1 '- 方案摘要：【填写：三五句话说清本次采用的方案】

' '- 方案摘要：【填写：三五句话说清本次采用的方案】

| 方案 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| A | x | y | 采用 |

' sec3_clean
reverse_file "sample 整体方案 has no table" assets/spec/plus-doc-samples/design.md 1 '## 3 整体方案

' '## 3 整体方案

| 方案 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| A | x | y | 采用 |

' sec3_clean
wf_text() { local f="$1/assets/workflow"
  grep -q 'Overrides `trellis-brainstorm`: in 1.1 do NOT write design.md / implement.md' "$f/index.md" && grep -q 'if absent or declined, skip it' "$f/index.md" \
  && grep -q 'Do NOT edit yet' "$f/phase1.md" && grep -q 'only after they confirm' "$f/phase2.md" && grep -q 'Fixing, then updating the triage, is enough: no rerun' "$f/phase2.md" \
  && grep -q -- '`--force` needs `--reason`' "$f/phase2.md"; }
chk 0 - wf_text "$TOOL" && ok "workflow text: brainstorm override, optional /grill-me, list-then-confirm for review and OCR, fix+triage needs no rerun, --force needs a reason" || bad "workflow text for this version"
reverse_file "workflow: brainstorm override" assets/workflow/index.md 1 'Overrides `trellis-brainstorm`: in 1.1' 'Note: in 1.1' wf_text
reverse_file "workflow: grill-me is optional" assets/workflow/index.md 1 'if absent or declined, skip it' 'always ask the user to run it' wf_text
reverse_file "workflow: review lists before editing" assets/workflow/phase1.md 1 'Do NOT edit yet' 'Edit at once' wf_text
reverse_file "workflow: OCR lists before editing" assets/workflow/phase2.md 1 'only after they confirm' 'at once' wf_text
reverse_file "workflow: fix + triage needs no rerun" assets/workflow/phase2.md 1 'Fixing, then updating the triage, is enough: no rerun.' 'Fixing needs a rerun.' wf_text
reverse_file "workflow: --force needs a reason" assets/workflow/phase2.md 1 '`--force` needs `--reason`' '`--force` is fine' wf_text
mkdir -p "$WORK/fat/assets/workflow"; cp "$TOOL"/assets/workflow/*.md "$WORK/fat/assets/workflow/"; python3 -c "print('x'*3000)" >> "$WORK/fat/assets/workflow/phase1.md"
check "reverse: bloated workflow blocks are rejected" 1 - wf_budget "$WORK/fat"
# Phase 1 flow: one step per line, in execution order, and it says outright that the ids are not a sequence
flow_ok() { python3 - "$1" <<'PY2'
import re, sys
t = open(sys.argv[1], encoding="utf8").read(); a = t.index("Phase 1 (M/L)"); b = t.index("Phase 2:")
blk = t[a:b]; ids = re.findall(r"^  (1\.\d) ", blk, re.M)
ok = ids == ["1.0", "1.2", "1.1", "1.6", "1.7", "1.3"] and "NOT a sequence" in blk and "→" not in blk
print("steps:", ids, "| not-a-sequence note:", "NOT a sequence" in blk, "| no arrow chain:", "→" not in blk)
sys.exit(0 if ok else 1)
PY2
}
check "workflow index: Phase 1 lists 1.0, 1.2, 1.1, 1.6, 1.7, 1.3 one per line, says the ids are not a sequence, no arrow chain" 0 "steps: \['1.0', '1.2', '1.1', '1.6', '1.7', '1.3'\]" flow_ok "$TOOL/assets/workflow/index.md"
sed 's/NOT a sequence/a sequence/' "$TOOL/assets/workflow/index.md" > "$WORK/index.nonote"; check "reverse: the flow without the 'not a sequence' note is rejected" 1 "not-a-sequence note: False" flow_ok "$WORK/index.nonote"
python3 - "$TOOL/assets/workflow/index.md" "$WORK/index.arrow" <<'PY2'
import sys
t = open(sys.argv[1], encoding="utf8").read(); t = t.replace("  1.6 [new session]", "  → 1.6 [new session]", 1).replace("  1.0 create", "  1.1 create", 1); open(sys.argv[2], "w", encoding="utf8").write(t)
PY2
check "reverse: a flow with wrong order / an arrow chain is rejected" 1 "steps:" flow_ok "$WORK/index.arrow"
# samples and templates
lines_ok() { for f in "$@"; do [ "$(wc -l < "$f")" -le 150 ] || { echo "$f too long"; return 1; }; done; }
check "golden samples are <= 150 lines each" 0 - lines_ok "$SAMPLE/prd.md" "$SAMPLE/design.md"
python3 -c "print('\n' * 160)" > "$WORK/long.md"; check "reverse: a 160-line sample is rejected" 1 "too long" lines_ok "$WORK/long.md"
tpl_ok() { for f in prd design implement code-map; do [ -s "$1/assets/plus/templates/$f.md" ] || return 1; done; [ ! -e "$1/assets/plus/templates/alignment.md" ]; }
check "the four templates exist and the v1.1 alignment template is gone" 0 - tpl_ok "$TOOL"
impl_slim() { local f="$1"; [ "$(wc -c < "$f")" -le 1500 ] && ! grep -qE '验证命令|回滚点|手工验证|提交前验证|Given' "$f"; }
check "implement template is slim: <= 1500 bytes, no per-step test prose / verification command / rollback / manual checklist / pre-commit section" 0 - impl_slim "$TOOL/assets/plus/templates/implement.md"
cp "$TOOL/assets/plus/templates/implement.md" "$WORK/impl.fat"; printf -- '- 验证命令：`mvn -q test`\n- 回滚点：只回退本文件\n' >> "$WORK/impl.fat"
check "reverse: a template with 验证命令 / 回滚点 is rejected" 1 - impl_slim "$WORK/impl.fat"
python3 -c "print('x' * 2000)" >> "$WORK/impl.fat"; cp "$TOOL/assets/plus/templates/implement.md" "$WORK/impl.big"; python3 -c "print('x' * 2000)" >> "$WORK/impl.big"
check "reverse: an oversized template is rejected" 1 - impl_slim "$WORK/impl.big"
check "the lint fixture (a valid plan without 预期 column / per-step extras) is slim as well" 0 - impl_slim "$HERE/fixtures/lint/implement.md"
# skills
skills_ok() { for sk in plus-draft plus-test-gate plus-ocr-review; do f="$1/assets/skills/$sk/SKILL.md"; head -1 "$f" | grep -q '^---$' && grep -q "^name: $sk$" "$f" && grep -q '^description: ' "$f" || { echo "bad skill $sk"; return 1; }; done
  [ ! -e "$1/assets/skills/plus-align" ] && [ ! -e "$1/assets/skills/plus-planning-depth" ]; }
check "skills: plus-draft / plus-test-gate / plus-ocr-review with frontmatter; plus-align and plus-planning-depth are gone" 0 - skills_ok "$TOOL"
# stale references to removed concepts
stale_refs() { grep -rnE 'alignment\.md|plus-align|plus-planning-depth|plus-design-accuracy|plus-req-coverage|plus-impact-analysis|__ALIGN_SKILL__|design-review-rubric|REQ-[0-9]|DES-[0-9]|\bIMP-[0-9]|step 1\.8|idMode' "$1/assets/workflow" "$1/assets/skills" "$1/assets/agents" "$1/assets/spec" "$1/assets/patches" "$1/assets/plus/templates" "$1/assets/plus/plus.config.json" | grep -v 'v1\.x key'; [ $? -eq 1 ]; }
check "no stale references to v1.1 concepts in the shipped assets" 0 - stale_refs "$TOOL"
mkdir -p "$WORK/stale"; cp -r "$TOOL/assets" "$WORK/stale/"; echo "see plus-align" >> "$WORK/stale/assets/skills/plus-draft/SKILL.md"
check "reverse: a leftover reference is detected" 1 "plus-align" stale_refs "$WORK/stale"
# agent patches
for k in implement check; do LAST="$(cat "$TOOL/assets/patches/agent-$k.md")"; has "agent patch $k: tells the sub-agent where the task is (Active task) and what to run (static test gate)" "node ./.trellis/plus/gate.mjs test --task <TASK_DIR>"; done
# one formal `test --run` per task: the sub-agents only run the static check
norun() { ! grep -q 'gate.mjs test --task <TASK_DIR> --run' "$1"; }
check "implement agent patch does not run the formal test --run (static check only)" 0 - norun "$TOOL/assets/patches/agent-implement.md"
check "check agent patch does not run the formal test --run (static check only)" 0 - norun "$TOOL/assets/patches/agent-check.md"
printf 'x `node ./.trellis/plus/gate.mjs test --task <TASK_DIR> --run` y\n' > "$WORK/patch.dup"; check "reverse: a patch that runs test --run again is rejected" 1 - norun "$WORK/patch.dup"
LAST="$(cat "$TOOL"/assets/workflow/*.md | grep -c 'test --task {TASK_DIR} --run')"; has "the workflow runs the formal test --run exactly once (2.4)" "^1$"
once_only() { [ "$(cat "$1"/*.md | grep -c 'test --task {TASK_DIR} --run')" = "1" ]; }
mkdir -p "$WORK/wfdup"; cp "$TOOL"/assets/workflow/*.md "$WORK/wfdup/"; echo 'node ./.trellis/plus/gate.mjs test --task {TASK_DIR} --run' >> "$WORK/wfdup/phase1.md"; check "reverse: a second test --run in the workflow is rejected" 1 - once_only "$WORK/wfdup"
nopc() { ! grep -q 'pre-commit --task <TASK_DIR> --run' "$1"; }
check "plus-ocr-review does not tell the agent to run the tests a second time before commit" 0 - nopc "$TOOL/assets/skills/plus-ocr-review/SKILL.md"
printf 'x pre-commit --task <TASK_DIR> --run y\n' > "$WORK/skill.dup"; check "reverse: a skill that re-runs tests at pre-commit is rejected" 1 - nopc "$WORK/skill.dup"
no17lint() { ! grep -q 'Then `GATE lint-plan' "$1"; }
check "1.7 does not tell the agent to re-run lint-plan by hand (1.4 re-checks)" 0 - no17lint "$TOOL/assets/workflow/phase1.md"
printf 'Then `GATE lint-plan {TASK_DIR}`.\n' > "$WORK/p1.dup"; check "reverse: a repeated manual lint-plan in 1.7 is rejected" 1 - no17lint "$WORK/p1.dup"
# installed state after apply: patched agents + skills present
mkproj "$WORK/m"; for f in .opencode/agents/trellis-implement.md .opencode/agents/trellis-check.md; do grep -q "trellis-plus" "$W/$f" && ok "apply --all patched $f" || bad "apply --all patched $f"; done
for sk in plus-draft plus-test-gate plus-ocr-review; do [ -f "$W/.opencode/skills/$sk/SKILL.md" ] && ok "installed skill $sk" || bad "installed skill $sk"; done
command_ok() { f="$1/.opencode/commands/plus-grill-design.md"; head -1 "$f" | grep -q '^---$' && grep -q '^description: ' "$f" && grep -q 'ONE question at a time' "$f" && grep -q 'Never touch code' "$f" && [ "$(wc -l < "$f")" -le 40 ]; }
check "installed command /plus-grill-design: description, one question at a time, no code edits, <= 40 lines" 0 - command_ok "$W"
cp -r "$W" "$WORK/mbad"; edit "$WORK/mbad/.opencode/commands/plus-grill-design.md" "Never touch code." "Edit code as needed."
check "reverse: a command that may edit code is rejected" 1 - command_ok "$WORK/mbad"
[ -f "$W/.opencode/agents/plus-design-reviewer.md" ] && [ -f "$W/.trellis/spec/guides/plus-doc-samples/design.md" ] && [ -f "$W/.trellis/spec/guides/plus-testing-guide.md" ] && ok "installed reviewer agent, doc samples and the testing guide" || bad "installed reviewer agent, doc samples and the testing guide"
fi

############################################################################################################
if want N; then
echo "== N. gate switches: profile / gates.<name> = error | warn | off, \`gate gates\`"
mkproj "$WORK/n"; cd "$W"
setcfg() { python3 - "$W/.trellis/plus/plus.config.json" "$1" <<'PY2'
import json, sys
f = sys.argv[1]; d = json.load(open(f, encoding="utf8")); d.pop("profile", None); d.pop("gates", None); d.update(json.loads(sys.argv[2])); json.dump(d, open(f, "w", encoding="utf8"), indent=2)
PY2
}
cp "$W/.trellis/plus/plus.config.json" "$WORK/n.cfg"
T="$(mkplan sw L)"
check "gates lists all 7 gates; the default profile is standard" 0 "profile: standard" $G gates
LAST="$($G gates 2>&1)"; [ "$(echo "$LAST" | grep -cE '^  [a-zA-Z]+ +error ')" = "5" ] && [ "$(echo "$LAST" | grep -cE '^  designReview +warn ')" = "1" ] && [ "$(echo "$LAST" | grep -cE '^  manifests +off ')" = "1" ] && ok "...standard: 5 gates error, designReview warn, manifests off" || { bad "...standard: 5 gates error, designReview warn, manifests off"; show; }
std_manifests_off() { setcfg '{"profile":"standard"}'; local o; o="$($G gates 2>&1)"; setcfg '{}'; echo "$o" | grep -qE '^  manifests +off '; }
reverse "standard profile skips manifests" 1 'standard: { designReview: "warn", manifests: "off" }' 'standard: { designReview: "warn", manifests: "warn" }' chk 0 - std_manifests_off
setcfg '{}' # no profile key: the default comes from gate.mjs itself
reverse "default profile is standard" 1 'profile: "standard",' 'profile: "strict",' chk 0 "profile: standard" $G gates
setcfg '{"profile":"strict"}'; LAST="$($G gates 2>&1)"; [ "$(echo "$LAST" | grep -cE '^  [a-zA-Z]+ +error ')" = "7" ] && ok "...strict: exactly 7 gate lines with mode error" || { bad "...strict: exactly 7 gate lines with mode error"; show; }
setcfg '{}'
has "...and says what can never be switched off" "Always on, not switchable"
setcfg '{"profile":"light","gates":{"ocr":"error"}}'; LAST="$($G gates 2>&1)"; has "light profile: designReview off, source shown" "designReview +off +\[profile light\]"; has "...an explicit gates.ocr beats the profile" "ocr +error +\[gates.ocr\]"
setcfg '{}'
# lint-plan under each switch (a plan with a placeholder)
printf '\n【填写：补充说明】\n' >> "$W/$T/design.md"
check "strict: a placeholder in design.md blocks lint-plan" 1 "unresolved placeholder" $G lint-plan "$T"
setcfg '{"gates":{"lintPlan":"warn"}}'
check "gates.lintPlan=warn: the same finding is a warning, exit 0" 0 "WARN  \(gates.lintPlan=warn, would block otherwise\) design.md:[0-9]+ unresolved placeholder" $G lint-plan "$T"
reverse "warn demotes errors to warnings" 1 'if (gateMode(cfg, name) === "warn" && rep.errors.length) {' 'if (false) {' chk 0 "gates.lintPlan=warn" $G lint-plan "$T"
setcfg '{"profile":"light"}'
check "profile light: lintPlan is warn" 0 "gates.lintPlan=warn" $G lint-plan "$T"
setcfg '{"profile":"light","gates":{"lintPlan":"error"}}'
check "an explicit gates.lintPlan=error beats profile light" 1 "unresolved placeholder" $G lint-plan "$T"
reverse "gates.<name> overrides the profile" 1 'if (cfg.gates && cfg.gates[name]) return' 'if (false) return' chk 1 "unresolved placeholder" $G lint-plan "$T"
setcfg '{"gates":{"lintPlan":"off"}}'
check "gates.lintPlan=off: not run, one note" 0 "skipped: lintPlan is off \(gates.lintPlan\)" $G lint-plan "$T"
reverse "off skips the gate" 1 'if (gateMode(cfg, name) === "off") return skippedReport(title, name)' 'if (false) return skippedReport(title, name)' chk 0 "skipped: lintPlan is off" $G lint-plan "$T"
setcfg '{"profile":"strict"}'; sed -i '$d' "$W/$T/design.md"; sed -i '$d' "$W/$T/design.md"
# design-review (L) missing report
check "strict: an L task without a review report fails design-review" 1 "reviews/design-review.md missing" $G design-review "$T"
setcfg '{"gates":{"designReview":"off"}}'
check "gates.designReview=off: skipped" 0 "skipped: designReview is off" $G design-review "$T"
setcfg '{"gates":{"designReview":"warn"}}'
check "gates.designReview=warn: shown as a warning" 0 "WARN  \(gates.designReview=warn, would block otherwise\) reviews/design-review.md missing" $G design-review "$T"
# pre-start (the hard gate behind task.py start) honours the switches
setcfg '{"profile":"strict"}'
check "pre-start strict: the missing review blocks" 1 "reviews/design-review.md missing" $G pre-start "$T"
setcfg '{}'
check "pre-start with the DEFAULT profile (standard): a missing review is a warning, start is allowed" 0 "gates.designReview=warn" $G pre-start "$T"
reverse "default profile reaches pre-start" 1 'profile: "standard",' 'profile: "strict",' chk 0 "gates.designReview=warn" $G pre-start "$T"
setcfg '{"profile":"standard"}'
check "pre-start profile standard: designReview is a warning, start is allowed" 0 "gates.designReview=warn" $G pre-start "$T"
LAST="$($G pre-start "$T" 2>&1)"; has "...and manifests is skipped in standard" "skipped: manifests is off \(profile standard\)"
reverse "pre-start applies the switches" 1 'reps.push(runGate("designReview", cfg, "design-review", () => designReview(taskDir, cfg, ti)))' 'reps.push(designReview(taskDir, cfg, ti))' chk 0 "gates.designReview=warn" $G pre-start "$T"
setcfg '{"profile":"light"}'
check "pre-start profile light: design review and manifests are skipped" 0 "skipped: designReview is off \(profile light\)" $G pre-start "$T"
LAST="$($G pre-start "$T" 2>&1)"; has "...manifests skipped as well" "skipped: manifests is off \(profile light\)"
setcfg '{}'
# align
printf '%s\n' "$(sed 's/对齐状态：已对齐/对齐状态：未对齐/' "$W/$T/prd.md")" > "$WORK/prd.un"; cp "$W/$T/prd.md" "$WORK/prd.ok"; cp "$WORK/prd.un" "$W/$T/prd.md"
check "strict: 未对齐 blocks align" 1 "对齐状态 is 未对齐" $G align "$T"
setcfg '{"gates":{"align":"off"}}'
check "gates.align=off: skipped" 0 "skipped: align is off" $G align "$T"
setcfg '{"gates":{"align":"warn"}}'
check "gates.align=warn: a warning" 0 "gates.align=warn, would block otherwise\) prd.md: 对齐状态 is 未对齐" $G align "$T"
cp "$WORK/prd.ok" "$W/$T/prd.md"; setcfg '{}'
# status follows the switches
setcfg '{"gates":{"designReview":"off"}}'
check "status: a skipped gate counts as passed (next step moves on)" 0 "✓ design-review" $G status "$T"
setcfg '{}'
# ocr off: ocr is not even called
export FAKE_OCR_LOG="$WORK/ocr-n.log"; : > "$FAKE_OCR_LOG"; setcfg '{"gates":{"ocr":"off"}}'
check "gates.ocr=off: --run does not call ocr" 0 "skipped: ocr is off" $G ocr --task "$T" --run
[ ! -s "$FAKE_OCR_LOG" ] && ok "...and the fake ocr log is empty" || bad "...and the fake ocr log is empty"
reverse "ocr off really skips the call" 1 'if (gateMode(cfg, name) === "off") return skippedReport(title, name)' 'if (false) return skippedReport(title, name)' chk 0 "skipped: ocr is off" $G ocr --task "$T" --run
setcfg '{}'
# validation: a typo must not silently mean "everything on"
setcfg '{"gates":{"lintplan":"warn"}}'; check "an unknown gate name is a usage error (exit 2)" 2 "gates.lintplan is unknown" $G gates
setcfg '{"gates":{"align":"maybe"}}'; check "an invalid mode is a usage error (exit 2)" 2 'gates.align = "maybe" is invalid' $G gates
setcfg '{"profile":"loose"}'; check "an unknown profile is a usage error (exit 2)" 2 'profile "loose" is unknown' $G gates
reverse "config validation" 1 '  checkGates(cfg)
  return cfg' '  return cfg' chk 2 "is unknown" $G gates
setcfg '{}'; check "restored: default config is valid" 0 "profile: standard" $G gates
# test gate / hook on the Java scenario
fresh "$WORK/n2"; node "$TOOL/trellis-plus.mjs" apply "$WORK/n2" --all >/dev/null 2>&1
( cd "$WORK/n2" && git add -A >/dev/null 2>&1 && gc -m plus ); bash "$HERE/mkjava.sh" "$WORK/n2" yes >/dev/null; use "$WORK/n2"; cd "$W"
cp "$W/.trellis/plus/plus.config.json" "$WORK/n2.cfg"; T="$(newtask "$W" nt)"
check "strict: the Java scenario (untested controller) fails the test gate" 1 "no unit test found" $G test --task "$T"
setcfg '{"gates":{"test":"warn"}}'
check "gates.test=warn: findings become warnings, exit 0" 0 "gates.test=warn, would block otherwise\) .*OrderController.java" $G test --task "$T"
reverse "test gate honours warn" 1 'reps.push(applyMode(rep, cfg, "test"))
      if (opts.run' 'reps.push(rep)
      if (opts.run' chk 0 "gates.test=warn" $G test --task "$T"
setcfg '{"gates":{"test":"off"}}'
check "gates.test=off: skipped" 0 "skipped: test is off" $G test --task "$T"
reverse "test off skips the gate" 1 'if (gateMode(cfg, "test") === "off") { reps.push(skippedReport("test-gate", "test")); break }' 'if (false) { reps.push(skippedReport("test-gate", "test")); break }' chk 0 "skipped: test is off" $G test --task "$T"
setcfg '{"gates":{"test":"off","ocr":"off"}}'
check "pre-commit (CLI) with gates.test=off skips the test gate" 0 "skipped: test is off" $G pre-commit --task "$T"
reverse "pre-commit honours test off" 1 'if (gateMode(cfg, "test") === "off") reps.push(skippedReport("test-gate", "test"))' 'if (false) reps.push(skippedReport("test-gate", "test"))' chk 0 "skipped: test is off" $G pre-commit --task "$T"
setcfg '{}'
check "hook strict: staged untested controller blocks" 1 "commit blocked by the pre-commit hook" $G pre-commit --hook
setcfg '{"gates":{"hook":"warn"}}'
check "gates.hook=warn: the hook prints what would block and lets the commit through" 0 "\(gates.hook=warn\) the checks above would block this commit" $G pre-commit --hook
reverse "hook warn lets the commit through" 1 'if (code && hook && gateMode(cfg, "hook") === "warn") {' 'if (false) {' chk 0 "gates.hook=warn" $G pre-commit --hook
setcfg '{"gates":{"hook":"off"}}'
check "gates.hook=off: the hook is skipped" 0 "the hook is off \(gates.hook\)" $G pre-commit --hook
reverse "hook off skips" 1 'if (hook && gateMode(cfg, "hook") === "off") {' 'if (false) {' chk 0 "the hook is off" $G pre-commit --hook
cp "$WORK/n2.cfg" "$W/.trellis/plus/plus.config.json"
fi

############################################################################################################
if want P; then
echo "== P. full-stack: one shared PRD on the parent, design + implement per child task"
mkproj "$WORK/p"; cd "$W"
PT="$(newtask "$W" fs)"; $G tier "$PT" L --reason "regression: full stack" >/dev/null
cp "$SAMPLE/prd.md" "$W/$PT/prd.md"
mkchild() { ( cd "$W" && python3 .trellis/scripts/task.py create "$1" --slug "$1" --parent "$PT" --description "child" >/dev/null 2>&1 ); ls -d "$W"/.trellis/tasks/*-"$1" | sed "s#^$W/##"; }
CB="$(mkchild fsb)"; CF="$(mkchild fsf)"
check "a child task inherits the parent's tier" 0 "tier: L .*inherited from parent" $G tier "$CB"
reverse "tier inheritance" 1 'if (TIERS.includes(pt)) return {' 'if (false) return {' chk 0 "inherited from parent" $G tier "$CB"
check "seed on the parent with children creates the prd only" 0 "Next:" $G seed "$PT"
[ ! -f "$W/$PT/design.md" ] && ok "...no design.md / implement.md on the parent" || bad "parent got a design.md"
check "seed on a child creates design + implement and a pointer prd.md" 0 "prd.md is a pointer to the parent's shared PRD" $G seed "$CB"
[ -f "$W/$CB/design.md" ] && [ -f "$W/$CB/implement.md" ] && ok "...design.md and implement.md exist in the child" || bad "child design/implement missing"
run grep -c "$PT/prd.md" "$W/$CB/implement.jsonl" "$W/$CB/check.jsonl"; has "...the parent's prd.md is registered in implement.jsonl" "implement.jsonl:1"; has "...and in check.jsonl" "check.jsonl:1"
check "seed twice does not duplicate the manifest entry" 0 "Next:" $G seed "$CB"
run grep -c "$PT/prd.md" "$W/$CB/implement.jsonl"; has "...(still exactly one entry)" "^1$"
check "align on a child checks the parent's PRD" 0 "inherited from the parent task" $G align "$CB"
reverse "child reads the parent's PRD" 1 'if (par && !/^对齐状态[:：]/m.test(stripComments(read(own) ?? ""))) {' 'if (false) {' chk 0 "inherited from the parent task" $G align "$CB"
# the backend child covers R1 and R3, the frontend child only R2
cp "$SAMPLE/design.md" "$W/$CB/design.md"; cp "$FX/implement.md" "$W/$CB/implement.md"; mkdir -p "$W/$CB/research" "$W/$CF/research"; cp "$FX/code-map.md" "$W/$CB/research/code-map.md"; cp "$FX/code-map.md" "$W/$CF/research/code-map.md"
python3 - "$W/$CB/design.md" <<'PY5'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read()
s = s.replace("| R2 | OrderController | OrderControllerTest#post_duplicate_returns409 |\n", "")
open(f, "w", encoding="utf8").write(s)
PY5
check "child lint-plan: warns about a requirement no child covers yet (R2)" 0 "WARN  requirement\(s\) not yet in the 覆盖矩阵 of any child task.*R2" $G lint-plan "$CB"
reverse "family coverage hint" 1 'if (missing.length) rep[level](' 'if (false) rep[level](' chk 0 "not yet in the 覆盖矩阵 of any child" $G lint-plan "$CB"
cp "$SAMPLE/design.md" "$W/$CF/design.md"; cp "$FX/implement.md" "$W/$CF/implement.md"
python3 - "$W/$CF/design.md" <<'PY6'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read()
s = s.replace("| R1 | OrderService | OrderServiceTest#create_duplicate_throws |\n", "").replace("| R3 | OrderService | OrderServiceTest#create_null_throws |\n", "")
open(f, "w", encoding="utf8").write(s)
PY6
run $G lint-plan "$CB"; hasnt "once both children are drafted, no uncovered requirement is reported" "not yet in the 覆盖矩阵"
check "a child 覆盖矩阵 citing no requirement fails" 1 "覆盖矩阵 cites no requirement" env TRELLIS_PLUS_X=1 bash -c "cd '$W' && python3 - '$W/$CF/design.md' <<'PY7'
import sys,re
f = sys.argv[1]; s = open(f, encoding='utf8').read()
a = s.index('## 10 覆盖矩阵'); b = s.index('上线检查：')
open(f, 'w', encoding='utf8').write(s[:a] + '## 10 覆盖矩阵与上线检查\n\n| 需求 | 模块 | 测试 |\n| --- | --- | --- |\n| 无 | x | y |\n\n' + s[b:])
PY7
node .trellis/plus/gate.mjs lint-plan '$CF'"
cp "$SAMPLE/design.md" "$W/$CF/design.md"
python3 - "$W/$CF/design.md" <<'PY6'
import sys
f = sys.argv[1]; s = open(f, encoding="utf8").read()
s = s.replace("| R1 | OrderService | OrderServiceTest#create_duplicate_throws |\n", "").replace("| R3 | OrderService | OrderServiceTest#create_null_throws |\n", "")
open(f, "w", encoding="utf8").write(s)
PY6
check "parent lint-plan: design/implement live in the children" 0 "parent task with 2 child task\(s\)" $G lint-plan "$PT"
check "matrix on the parent prints the whole family" 0 "\| R2 \| .*OrderController" $G matrix "$PT"
fi

echo
echo "================ passed: $PASS   failed: $FAIL   skipped: $SKIP   (workdir: $WORK)"
exit $FAIL
