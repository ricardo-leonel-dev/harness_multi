#!/usr/bin/env bash
# Explicit PostgreSQL target configuration and resolution; no DB/network access.
set -eu
TOOLKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass() { printf '  ok %s\n' "$1"; }
install_into() { (cd "$1" && bash "$TOOLKIT/install.sh" --slug db-target-test --profile postgres --human-user Tester --verify-command true "${@:2}") > "$WORK/install.log" 2>&1; }

P="$WORK/install"; mkdir -p "$P"
install_into "$P" --postgres-database app_db
jq -e '.postgres_database == "app_db"' "$P/.harness.json" >/dev/null
pass 'fresh postgres install stores explicit database target'
# No-option reinstall must preserve all config bytes.
jq '.custom_sentinel={"keep":true} | .notion_database_id="notion-sentinel"' "$P/.harness.json" > "$WORK/config"
cp "$WORK/config" "$P/.harness.json"
cp "$P/.harness.json" "$WORK/before-no-flag"
install_into "$P"
cmp "$WORK/before-no-flag" "$P/.harness.json"
install_into "$P" --postgres-database updated_db
jq -e '.postgres_database == "updated_db" and .custom_sentinel.keep == true and .notion_database_id == "notion-sentinel"' "$P/.harness.json" >/dev/null
pass 'no-flag reinstall preserves bytes and explicit update preserves custom properties'
cp "$P/.harness.json" "$WORK/before-empty"
if install_into "$P" --postgres-database ''; then exit 1; fi
cmp "$WORK/before-empty" "$P/.harness.json"
printf '{invalid\n' > "$P/.harness.json"
cp "$P/.harness.json" "$WORK/before-invalid"
if install_into "$P" --postgres-database fail_db; then exit 1; fi
cmp "$WORK/before-invalid" "$P/.harness.json"
pass 'empty value and malformed JSON fail without changing config'

# Failures while writing the temporary replacement or renaming it preserve the old config.
cp "$WORK/before-empty" "$P/.harness.json"
cp "$P/.harness.json" "$WORK/before-failure"
REAL_JQ="$(command -v jq)"; REAL_MV="$(command -v mv)"; mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/jq" <<'WRAP'
#!/usr/bin/env bash
for arg in "$@"; do [ "$arg" = '.postgres_database = $database' ] && exit 79; done
exec "$REAL_JQ" "$@"
WRAP
chmod +x "$WORK/fakebin/jq"
if (cd "$P" && REAL_JQ="$REAL_JQ" PATH="$WORK/fakebin:$PATH" bash "$TOOLKIT/install.sh" --slug db-target-test --profile postgres --human-user Tester --verify-command true --postgres-database fail_db) > "$WORK/jq-fail.log" 2>&1; then exit 1; fi
cmp "$WORK/before-failure" "$P/.harness.json"
cat > "$WORK/fakebin/mv" <<'WRAP'
#!/usr/bin/env bash
for arg in "$@"; do [ "$arg" = "$BLOCKED_DEST" ] && exit 78; done
exec "$REAL_MV" "$@"
WRAP
chmod +x "$WORK/fakebin/mv"
if (cd "$P" && REAL_JQ="$REAL_JQ" REAL_MV="$REAL_MV" BLOCKED_DEST="$P/.harness.json" PATH="$WORK/fakebin:$PATH" bash "$TOOLKIT/install.sh" --slug db-target-test --profile postgres --human-user Tester --verify-command true --postgres-database fail_db) > "$WORK/mv-fail.log" 2>&1; then exit 1; fi
cmp "$WORK/before-failure" "$P/.harness.json"
if find "$P" -maxdepth 1 -name '.harness.json.*' | grep -q .; then exit 1; fi
pass 'failed replacement and rename preserve prior config and clean temporary files'

# Install runner at its normal location with fake psql, recording only argv.
R="$WORK/runner"; mkdir -p "$R/scripts" "$R/tests" "$R/fakebin"
cp "$TOOLKIT/profiles/postgres/run_tests.sh" "$R/scripts/run_tests.sh"
printf 'SELECT 1;\n' > "$R/tests/one.sql"
cat > "$R/fakebin/psql" <<'PSQL'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$PSQL_ARGS_FILE"
exit "${FAKE_PSQL_EXIT:-0}"
PSQL
chmod +x "$R/fakebin/psql"
cat > "$R/.harness.json" <<'JSON'
{"project_slug":"rushr-campaigns-db","postgres_database":"campaigns_db"}
JSON
run_clean() { (cd "$R" && env -u PGDATABASE -u PGHOST -u PGPORT -u PGUSER -u PGPASSWORD PSQL_BIN="$R/fakebin/psql" PSQL_ARGS_FILE="$WORK/args" bash scripts/run_tests.sh --all) > "$WORK/run.log" 2>&1; }
arg_after() { awk -v k="$1" 'last==k {print; exit} {last=$0}' "$WORK/args"; }
run_clean
[ "$(arg_after -d)" = campaigns_db ]
(cd "$R" && env PSQL_BIN="$R/fakebin/psql" PSQL_ARGS_FILE="$WORK/args" PGDATABASE=env_db PGHOST=dbhost PGPORT=5440 PGUSER=runner PGPASSWORD=hidden bash scripts/run_tests.sh --all) > "$WORK/run.log" 2>&1
[ "$(arg_after -d)" = env_db ] && [ "$(arg_after -h)" = dbhost ] && [ "$(arg_after -p)" = 5440 ] && [ "$(arg_after -U)" = runner ]
printf '%s\n' '{"project_slug":"rushr-web-display-db"}' > "$R/.harness.json"
run_clean
[ "$(arg_after -d)" = web-display ]
printf '%s\n' '{"project_slug":"rushr-social-media-db"}' > "$R/.harness.json"
if run_clean; then exit 1; fi
grep -q 'set PGDATABASE or .harness.json::postgres_database' "$WORK/run.log"
if grep -q 'Berlin2020\|hidden' "$WORK/run.log"; then exit 1; fi
if (cd "$R" && env PSQL_BIN="$R/fakebin/psql" PSQL_ARGS_FILE="$WORK/args" PGDATABASE=env_db FAKE_PSQL_EXIT=23 bash scripts/run_tests.sh --all) > "$WORK/failed-run.log" 2>&1; then exit 1; fi
pass 'runner honors PGDATABASE/config/Web Display-only fallback and propagates psql failure safely'

# Helper resolver: project config outranks verify-command db substitution, including postgres/template1.
H="$WORK/helper"; mkdir -p "$H"
printf '%s\n' '{"postgres_database":"configured_db","verify_command":"PGPASSWORD=sentinel psql -h dbhost -p 5439 -U app -d postgres -tAc \"SELECT 1 FROM pg_database WHERE datname=\u0027other_db\u0027;\" | grep -q 1"}' > "$H/.harness.json"
helper_resolve() { env -u PSQL_HOST -u PSQL_PORT -u PSQL_USER -u PSQL_DB -u PGHOST -u PGPORT -u PGUSER -u PGDATABASE -u PGPASSWORD PROJECT_DIR="$H" SCRIPT_DIR="$TOOLKIT/profiles/postgres/test_helpers" bash -c '. "$1/lib_conn.sh"; resolve_psql_conn; printf "%s %s %s %s %s" "$PSQL_HOST" "$PSQL_PORT" "$PSQL_USER" "$PSQL_DB" "$PGPASSWORD"' _ "$TOOLKIT/profiles/postgres/test_helpers"; }
[ "$(helper_resolve)" = 'dbhost 5439 app configured_db sentinel' ]
for configured in postgres template1; do
  jq --arg db "$configured" '.postgres_database=$db' "$H/.harness.json" > "$WORK/helper-config"
  cp "$WORK/helper-config" "$H/.harness.json"
  [ "$(helper_resolve)" = "dbhost 5439 app $configured sentinel" ]
done
jq '.postgres_database="configured_db"' "$H/.harness.json" > "$WORK/helper-config"
cp "$WORK/helper-config" "$H/.harness.json"
[ "$(env -u PSQL_HOST -u PSQL_PORT -u PSQL_USER -u PSQL_DB -u PGHOST -u PGPORT -u PGUSER -u PGPASSWORD PROJECT_DIR="$H" SCRIPT_DIR="$TOOLKIT/profiles/postgres/test_helpers" PGDATABASE=template1 bash -c '. "$1/lib_conn.sh"; resolve_psql_conn; printf "%s" "$PSQL_DB"' _ "$TOOLKIT/profiles/postgres/test_helpers")" = template1 ]
# The old existence-check behavior remains when verify_command itself supplies -d postgres.
jq 'del(.postgres_database)' "$H/.harness.json" > "$WORK/helper-config"
cp "$WORK/helper-config" "$H/.harness.json"
[ "$(helper_resolve)" = 'dbhost 5439 app other_db sentinel' ]
pass 'helper preserves explicit postgres/template1 and PGDATABASE while retaining legacy verify-command inference'
echo 'All PostgreSQL runner config regressions passed.'
