#!/usr/bin/env bash
# Isolated regression for install.sh's .git/info/exclude block; no database/network access.
set -eu
TOOLKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass() { printf '  ok %s\n' "$1"; }
install_into() { (cd "$1" && bash "$TOOLKIT/install.sh" --slug "exclude-test" --human-user Tester --verify-command true) > "$WORK/install.log" 2>&1; }
# Paths git status reports as untracked/modified, relative to the repository root.
untracked() { git -C "$REPO" status --porcelain -z --untracked-files=all | tr '\0' '\n' | cut -c4- | sort; }

REPO="$WORK/mono repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
EXCLUDE="$REPO/.git/info/exclude"
printf '# hand-written rule\n/local-notes.txt\n' >> "$EXCLUDE"
A="$REPO/service-a"; B="$REPO/svc [b]"; mkdir -p "$A" "$B"
install_into "$A"
install_into "$B"

# Mock datasets stay on disk and remain invisible in each monorepo service.
for project in "$A" "$B"; do
  mkdir -p "$project/mock-data/manifests"
  printf '{"version":"initial"}\n' > "$project/mock-data/manifests/initial.json"
  mkdir -p "$project/progress/some_feature" && printf 'handoff\n' > "$project/progress/some_feature/impl.md"
done
cp "$A/mock-data/manifests/initial.json" "$WORK/dataset.before"
git -C "$REPO" check-ignore -q "$A/mock-data/manifests/initial.json"
git -C "$REPO" check-ignore -q "$B/mock-data/manifests/initial.json"

# Only project-owned files may show up for commit; harness-owned ones never do.
untracked > "$WORK/visible"
for f in .harness.json CHECKPOINTS.md docs/architecture.md docs/conventions.md \
         docs/verification.md specs/README.md; do
  grep -qxF "service-a/$f" "$WORK/visible"
  grep -qxF "svc [b]/$f" "$WORK/visible"
done
if grep -E '(^|/)(AGENTS\.md|CLAUDE\.md|init\.sh|harness\.db|docs/specs\.md)$|/(harness|state|scripts|mock-data|progress)/|/\.(claude|codex)/agents/' "$WORK/visible"; then
  echo 'harness-owned file visible to git' >&2; exit 1
fi
[ -d "$A/state" ]
pass 'monorepo installs hide every harness-owned file and keep project-owned ones visible'

grep -qxF '/local-notes.txt' "$EXCLUDE"
grep -qxF '/svc \[b\]/harness/' "$EXCLUDE"
pass 'foreign rules are kept and glob characters in the project path are escaped'

cp "$EXCLUDE" "$WORK/exclude.before"
install_into "$A"
install_into "$B"
cmp "$WORK/exclude.before" "$EXCLUDE"
cmp "$WORK/dataset.before" "$A/mock-data/manifests/initial.json"
cmp "$WORK/dataset.before" "$B/mock-data/manifests/initial.json"
[ "$(grep -c '^# >>> harness-managed: /service-a/ ' "$EXCLUDE")" = 1 ]
pass 'reinstall replaces its own block without duplicating rules'

# Project-owned scripts next to the harness ones are never hidden.
printf 'echo project\n' > "$A/scripts/project-tool.sh"
untracked | grep -qxF 'service-a/scripts/project-tool.sh'
pass 'project scripts in scripts/ stay visible'

# Files committed before the exclude existed are reported, not silently kept.
R2="$WORK/legacy"; mkdir -p "$R2"; git -C "$R2" init -q
install_into "$R2"
mkdir -p "$R2/mock-data/manifests"
printf '{"version":"legacy"}\n' > "$R2/mock-data/manifests/legacy.json"
git -C "$R2" add -f state docs/specs.md mock-data
git -C "$R2" -c user.name=t -c user.email=t@t commit -qm legacy
install_into "$R2"
grep -q 'harness-owned files still tracked by git' "$WORK/install.log"
grep -q 'docs/specs.md' "$WORK/install.log"
grep -q 'mock-data/manifests/legacy.json' "$WORK/install.log"
git -C "$R2" ls-files --error-unmatch mock-data/manifests/legacy.json >/dev/null
pass 'reinstall lists harness-owned files that are still tracked'

# A worktree has no exclude file of its own: the block must land in the shared one.
R3="$WORK/shared"; mkdir -p "$R3"; git -C "$R3" init -q
git -C "$R3" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$R3" worktree add -q "$WORK/wt" 2>/dev/null
mkdir -p "$WORK/wt/sub"
install_into "$WORK/wt/sub"
grep -qxF '/sub/AGENTS.md' "$R3/.git/info/exclude"
mkdir -p "$WORK/wt/sub/mock-data"
printf 'retained\n' > "$WORK/wt/sub/mock-data/selection.json"
git -C "$WORK/wt" check-ignore -q sub/mock-data/selection.json
[ -f "$WORK/wt/sub/mock-data/selection.json" ]
if git -C "$WORK/wt" status --porcelain --untracked-files=all | grep -q 'sub/AGENTS.md'; then exit 1; fi
pass 'worktree installs write to the shared exclude file'

# Old installs scaffolded Claude-only hooks; a reinstall removes exactly those.
[ ! -e "$A/.claude/settings.json" ]
OLD_STOP='{"hooks":[{"type":"command","command":"./init.sh > /tmp/harness_init.log 2>&1 && echo ok"}]}'
OLD_SUB='{"hooks":[{"type":"command","command":"cd x; bash scripts/harness.sh record-usage \"$@\" >/dev/null 2>&1; exit 0"}]}'
OWN='{"hooks":[{"type":"command","command":"echo mine"}]}'
printf '{"hooks":{"Stop":[%s],"SubagentStop":[%s]}}\n' "$OLD_STOP" "$OLD_SUB" > "$A/.claude/settings.json"
printf '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[%s,%s],"SubagentStop":[%s]}}\n' "$OLD_STOP" "$OWN" "$OLD_SUB" > "$B/.claude/settings.json"
install_into "$A"
install_into "$B"
[ ! -e "$A/.claude/settings.json" ]
jq -e '.permissions.allow == ["Bash(ls)"] and (.hooks.Stop | length) == 1 and .hooks.Stop[0].hooks[0].command == "echo mine" and (.hooks | has("SubagentStop") | not)' "$B/.claude/settings.json" >/dev/null
pass 'reinstall removes the old harness hooks and keeps everything else'

# Claude Code allow rules: the routine commands only, merged into the project's own, never duplicated.
L="$A/.claude/settings.local.json"
jq -e '.permissions.allow | index("Bash(./init.sh:*)") and index("Bash(scripts/harness.sh record-review:*)") and index("Bash(scripts/harness.sh log-out:*)")' "$L" >/dev/null
if jq -e '.permissions.allow[] | select(test("approve-spec|cancel-session|supersede|harness\\.sh:\\*"))' "$L" >/dev/null; then
  echo 'allow rules cover a gated harness command' >&2; exit 1
fi
printf '{"model":"x","permissions":{"allow":["Bash(ls)"],"deny":["Bash(rm:*)"]}}\n' > "$L"
install_into "$A"
cp "$L" "$WORK/local.before"
install_into "$A"
cmp "$WORK/local.before" "$L"
jq -e '.model == "x" and .permissions.deny == ["Bash(rm:*)"] and .permissions.allow[0] == "Bash(ls)" and (.permissions.allow | length) == 15' "$L" >/dev/null
if untracked | grep -q 'settings.local.json'; then echo 'settings.local.json visible to git' >&2; exit 1; fi
printf 'not json' > "$L"
install_into "$A"
grep -q 'settings.local.json is not valid JSON' "$WORK/install.log"
[ "$(cat "$L")" = 'not json' ]
pass 'reinstall merges the Claude Code allow rules into settings.local.json and hides it from git'

N="$WORK/not a repo"; mkdir -p "$N"
install_into "$N"
grep -q 'not inside a git repository' "$WORK/install.log"
pass 'installs outside git skip the exclude step'
echo 'All install git-exclude regressions passed.'
