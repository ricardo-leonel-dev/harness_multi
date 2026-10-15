#!/usr/bin/env bash
# Isolated installer and evidence-index regression; no database/network access.
set -eu
TOOLKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass() { printf '  ok %s\n' "$1"; }
install_into() { (cd "$1" && bash "$TOOLKIT/install.sh" --slug database-test "${@:2}") > "$WORK/install.log" 2>&1; }
P="$WORK/project with spaces"; mkdir -p "$P"
install_into "$P" --human-user Tester --verify-command true
[ ! -e "$P/scripts/build_traceability.sh" ]
[ ! -e "$P/harness/instructions/postgres.md" ]
[ -f "$P/harness/instructions/coverage.md" ]
cmp "$TOOLKIT/shared/persona.md" "$P/harness/instructions/persona.md"
pass 'generic profile installs only generic shared guidance'
# Fresh checkpoints and generated agents must retain the accepted-baseline safeguards.
grep -Fq 'all active feature tests and changed relevant tests pass without suppression' "$P/CHECKPOINTS.md"
for runtime in .claude/agents .codex/agents; do
  case "$runtime" in .claude/*) suffix=md ;; *) suffix=toml ;; esac
  impl="$P/$runtime/implementer.$suffix"
  review="$P/$runtime/reviewer.$suffix"
  grep -Fq 'Without an' "$impl"
  grep -Fq 'accepted applicable baseline, require ordinary green tests' "$impl"
  grep -Fq 'Never widen/rewrite a baseline' "$impl"
  grep -Fq 'filename matching alone cannot prove no new regression' "$impl"
  grep -Fq 'independently run `bash scripts/run_tests.sh --all --baseline' "$review"
  grep -Fq 'every active acceptance/spec requirement must pass' "$review"
  grep -Fq 'before changes, its acceptance and revision/' "$review"
  grep -Fq 'local alignment before approval; do not silently override it' "$review"
  if grep -Fq 'Never pass with red tests.' "$review"; then exit 1; fi
done
pass 'fresh checkpoints and both generated runtimes enforce accepted-baseline safeguards'

# Runtime settings and project-owned artifacts must survive profile adoption.
jq '.verify_command="true" | .custom_field="keep" | .notion_database_id=""' "$P/.harness.json" > "$WORK/config"
cp "$WORK/config" "$P/.harness.json"
mkdir -p "$P/tests" "$P/specs/custom"
for f in docs/architecture.md docs/conventions.md docs/verification.md docs/specs.md CHECKPOINTS.md tests/custom.sql specs/custom/requirements.md .claude/settings.json; do
  printf 'project-owned sentinel %s\n' "$f" > "$P/$f"
done
cp -R "$P/docs" "$WORK/docs"
install_into "$P" --profile postgres --verify-command false --human-user Replacement </dev/null
cmp "$WORK/config" "$P/.harness.json"
for f in architecture conventions verification; do cmp "$WORK/docs/$f.md" "$P/docs/$f.md"; done
# docs/specs.md is harness-owned: a reinstall refreshes it from the toolkit.
cmp "$TOOLKIT/templates/docs/specs.md.tmpl" "$P/docs/specs.md"
for f in CHECKPOINTS.md tests/custom.sql specs/custom/requirements.md .claude/settings.json; do
  [ "$(cat "$P/$f")" = "project-owned sentinel $f" ]
done
[ -x "$P/scripts/build_traceability.sh" ]
[ -f "$P/scripts/templates/acceptance_test_prologue.sql" ]
pass 'postgres adoption preserves all project-owned content and configuration'
printf 'stale tool\n' > "$P/scripts/build_traceability.sh"
printf 'stale shared instructions\n' > "$P/harness/instructions/postgres.md"
install_into "$P" --profile postgres </dev/null
cmp "$TOOLKIT/profiles/postgres/build_traceability.sh" "$P/scripts/build_traceability.sh"
cmp "$TOOLKIT/profiles/postgres/verification.md" "$P/harness/instructions/postgres.md"
grep -Fq 'A generated file alone is not approval' "$P/harness/instructions/postgres.md"
grep -Fq 'Never widen/rewrite a baseline' "$P/harness/instructions/postgres.md"
grep -Fq 'execute explicitly selected files' "$P/harness/instructions/postgres.md"
grep -Fq 'New regressions, changed behavior without passing' "$P/harness/instructions/postgres.md"
grep -Fq 'shared guidance does not silently override stricter criteria' "$P/harness/instructions/postgres.md"
grep -Fq '`.harness.json::postgres_database`' "$P/harness/instructions/postgres.md"
grep -Fq 'only the Web Display project retains its legacy' "$P/harness/instructions/postgres.md"
pass 'reinstalled postgres profile carries provenance, unsuppressed evidence and local policy rules'

cmp "$WORK/config" "$P/.harness.json"
(cd "$P" && ./init.sh) > "$WORK/init.log" 2>&1
pass 'profile reinstall refreshes shared assets and preserved verification remains green'
if install_into "$P" --profile typo; then echo 'invalid profile accepted' >&2; exit 1; fi
cmp "$WORK/config" "$P/.harness.json"
pass 'unknown profile refused without config mutation'
mkdir -p "$P/specs/feature_a"
printf '## R1\n## R2\n## R10\n' > "$P/specs/feature_a/requirements.md"
cat > "$P/tests/chosen evidence.sql" <<'SQL'
SELECT 'PASS' AS result,
       't1_grouped_r1_r2' AS test_case;
SELECT 'PASS' AS result, 't2_preserved_r10' AS test_case;
SELECT 'PASS' AS result, 't3_boundary_r100' AS test_case;
SQL
printf "SELECT 'PASS' AS result, 't9_wrong_feature_r1_r2_r10' AS test_case;\n" > "$P/tests/other_acceptance.sql"
(cd "$P" && scripts/build_traceability.sh feature_a --test 'tests/chosen evidence.sql') > "$WORK/index"
grep -Fq '| R1 | `t1_grouped_r1_r2` (tests/chosen evidence.sql:2)' "$WORK/index"
grep -Fq '| R2 | `t1_grouped_r1_r2`' "$WORK/index"
grep -Fq '| R10 | `t2_preserved_r10`' "$WORK/index"
if grep -q 't3_boundary\|t9_wrong' "$WORK/index"; then exit 1; fi
(cd "$P" && scripts/build_traceability.sh feature_a --test-file 'tests/chosen evidence.sql') > "$WORK/alias"
cmp "$WORK/index" "$WORK/alias"
pass 'explicit test, compatibility alias, multiline grouped evidence, exact R tokens and stable locations'
if (cd "$P" && scripts/build_traceability.sh feature_a) > "$WORK/error" 2>&1; then exit 1; fi
if (cd "$P" && scripts/build_traceability.sh feature_a --test missing.sql) > "$WORK/error" 2>&1; then exit 1; fi
printf '## R3\n' >> "$P/specs/feature_a/requirements.md"
if (cd "$P" && scripts/build_traceability.sh feature_a --test 'tests/chosen evidence.sql') > "$WORK/gaps" 2>&1; then exit 1; fi
grep -Fq '| R3 | **MISSING named reference** |' "$WORK/gaps"
printf '## R3\n' >> "$P/specs/feature_a/requirements.md"
if (cd "$P" && scripts/build_traceability.sh feature_a --test 'tests/chosen evidence.sql') > "$WORK/error" 2>&1; then exit 1; fi
grep -q 'Duplicate requirement R3' "$WORK/error"
pass 'missing paths, implicit selection, missing references and duplicate ids fail'
# Template structural checks; actual SQL execution is deliberately not claimed.
T="$P/scripts/templates/acceptance_test_prologue.sql"
[ "$(tail -n 1 "$T")" = 'ROLLBACK;' ]
awk '/^DO \$\$/ {inside=1} /^\$\$;/ {inside=0} inside && /:\047/ {exit 1}' "$T"
grep -q 'INTO STRICT cfg FROM acceptance_config' "$T"
grep -q 'IF table_exists THEN' "$T"
grep -q "format('SELECT count(\*) FROM %I.%I'" "$T"
pass 'SQL template explicitly rolls back and uses guarded identifiers/config outside dollar quotes'
echo 'All database profile regressions passed.'
