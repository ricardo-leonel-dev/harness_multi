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
done
cp "$A/mock-data/manifests/initial.json" "$WORK/dataset.before"
git -C "$REPO" check-ignore -q "$A/mock-data/manifests/initial.json"
git -C "$REPO" check-ignore -q "$B/mock-data/manifests/initial.json"

# Only project-owned files may show up for commit; harness-owned ones never do.
untracked > "$WORK/visible"
for f in .gitignore .harness.json CHECKPOINTS.md docs/architecture.md docs/conventions.md \
         docs/verification.md specs/README.md .claude/settings.json; do
  grep -qxF "service-a/$f" "$WORK/visible"
  grep -qxF "svc [b]/$f" "$WORK/visible"
done
if grep -E '(^|/)(AGENTS\.md|CLAUDE\.md|init\.sh|harness\.db|docs/specs\.md)$|/(harness|state|scripts|mock-data)/|/\.(claude|codex)/agents/' "$WORK/visible"; then
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

N="$WORK/not a repo"; mkdir -p "$N"
install_into "$N"
grep -q 'not inside a git repository' "$WORK/install.log"
pass 'installs outside git skip the exclude step'
echo 'All install git-exclude regressions passed.'
