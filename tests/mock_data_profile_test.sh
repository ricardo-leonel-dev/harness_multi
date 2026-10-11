#!/usr/bin/env bash
set -eu
TOOLKIT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/project"
cd "$WORK/project"
bash "$TOOLKIT/install.sh" --slug mock-test --human-user Tester --profile postgres --postgres-database test --postgres-schemas '["a","b"]' > "$WORK/install.log" 2>&1
jq -e '.postgres_schemas == ["a","b"]' .harness.json >/dev/null
[ -f scripts/mock_data.py ]
[ -f harness/instructions/mock-data.md ]
scripts/harness.sh mock-data-generate --help | grep -q -- '--selection'
scripts/harness.sh mock-data-load --help | grep -q -- '--target-database'
mkdir mock-data
printf '{"tables":[]}\n' > mock-data/selection.json
cp .harness.json "$WORK/config-original"
if bash "$TOOLKIT/install.sh" --slug mock-test --human-user Tester --profile postgres --postgres-schemas 'a,b' > "$WORK/invalid.log" 2>&1; then exit 1; fi
cmp .harness.json "$WORK/config-original"
grep -q "requires --profile postgres" "$WORK/invalid.log"
if grep -q "Copying harness-core" "$WORK/invalid.log"; then exit 1; fi
bash "$TOOLKIT/install.sh" --slug mock-test --human-user Tester --profile postgres > "$WORK/reinstall.log" 2>&1
cmp .harness.json "$WORK/config-original"
[ -f mock-data/selection.json ]
printf '[OK] mock-data installer configuration, help, validation and project data preservation\n'
