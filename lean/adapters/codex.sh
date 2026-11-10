#!/usr/bin/env bash
# codex.sh — open one sandboxed Codex CLI session for a lean step.
#
#   lean/adapters/codex.sh <project> <interactive|headless|check> <model|-> <system_prompt_file> <prompt> [<result_json>]
#
# interactive: the Codex TUI in the user's terminal, the step prompt as the first message,
#   approval policy `never` as in headless: a command the sandbox blocks fails back to the
#   model; nothing can be approved to run outside the profile (the Claude sessions'
#   allowUnsandboxedCommands: false).
# headless: `codex exec --json`, its events turned into one result JSON at <result_json>
#   (usage, duration, is_error, num_turns: the shape claude -p writes, total_cost_usd null).
# check: only the sandbox self-check below, then exit 0 (nothing is sent to a model).
#
# The sandbox is a Codex permission profile built from lean/sandbox.sh's lists (verified with
# codex-cli 0.166.0 on macOS, progress/design_lean_flow.md §10):
#   - base `:read-only`, then `write` on the project and a fresh session TMPDIR only (no
#     /tmp, no user temp dir), `read` on sandbox.sh's write-denied paths (harness-owned
#     files, the git state), `deny` on its read-denied paths ($HOME entries but the carve-outs,
#     credentials, the lean state with the frozen manifest, the secret files in the project and
#     its repository and the LEAN_SECRET_GLOBS globs: lean/lib.sh), and `deny` globs on CLAUDE.md,
#     CLAUDE.local.md, AGENTS.md, AGENTS.override.md, .claude/ and .codex/ anywhere in the
#     project (Codex only accepts `deny` on globs: those are unreadable to commands too;
#     Codex itself still loads AGENTS.md);
#   - network through Codex's own proxy (feature `network_proxy`): localhost and
#     .harness.json::lean.allowed_domains only; unix sockets only in the project and the
#     local database sockets (sandbox.sh's list);
#   - no approvals in either mode (`approval_policy = "never"`: a blocked command fails, no
#     escalation out of the profile), `approvals_reviewer = "user"` (never a model reviewer);
#     headless also ignores the execpolicy rules.
# Never passed: --dangerously-bypass-approvals-and-sandbox, --dangerously-bypass-hook-trust,
# --approve-for-me, a `danger-full-access` sandbox or profile.
#
# Fail closed: before the session, `codex sandbox` runs a self-check with the same flags
# (seatbelt active, a canary in the lean state unreadable and unwritable, the first secret file
# found in the project, if any, unreadable, the session TMPDIR writable, Codex's network proxy in
# place). Every proxy variable of the caller (any name
# ending in "proxy", any case) and Codex's own sandbox/proxy markers are unset for the check
# and the session, so a loopback HTTPS_PROXY inside can only come from Codex's proxy: an
# inherited one (a local Proxyman/Charles/mitmproxy) can't pass the check with the network
# open. Codex's own API traffic doesn't use the caller's proxy either. Any failure, or an unknown flag/key in the
# installed Codex, refuses to start. macOS only (the check expects CODEX_SANDBOX=seatbelt).
#
# The environment: the secret-looking variables are dropped as for the claude adapters
# (lean/lib.sh lean_env_args), except Codex's own OPENAI_* / CODEX_* (it needs them to run),
# which shell_environment_policy then keeps out of the commands' environment.
set -euo pipefail

LEAN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
project="$1" mode="$2" model="$3" system_file="$4" prompt="$5" result="${6:-}"
case "$mode" in interactive|headless|check) ;; *) echo "mode must be interactive, headless or check" >&2; exit 2 ;; esac
[ "$mode" != headless ] || [ -n "$result" ] || { echo "headless needs a result file" >&2; exit 2; }
project="$(cd "$project" && pwd)"
command -v codex >/dev/null 2>&1 || { echo "lean: codex is not on PATH" >&2; exit 2; }
# shellcheck source=../lib.sh
. "$LEAN_DIR/lib.sh"

# The canary for the self-check lives in the lean state (where the frozen manifest is), made
# before sandbox.sh lists $HOME so it is covered like the manifest.
state=$(lean_state_dir "$project")
mkdir -p "$state/tmp" && canary=$(mktemp -d "$state/tmp/codex-check.XXXXXX") \
  || { echo "lean: can't create the sandbox check folder in $state/tmp" >&2; exit 1; }
echo canary > "$canary/canary"
tmp_root="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)"; tmp_root="${tmp_root%/}"
session_tmp=$(mktemp -d "$tmp_root/lean-session.XXXXXX") && session_tmp=$(cd "$session_tmp" && pwd -P) \
  || { rm -rf "$canary"; echo "lean: can't create the session temp folder in $tmp_root" >&2; exit 1; }
# Removed when this script ends (headless, check, or a refusal); an interactive session
# replaces it (exec), so its TMPDIR stays for the OS to clear with the user temp dir.
trap 'rm -rf "$canary"; chmod -R u+w "$session_tmp" 2>/dev/null; rm -rf "$session_tmp"' EXIT

settings="$("$LEAN_DIR/sandbox.sh" "$project")"
domains=$(jq -c '.lean.allowed_domains // []' "$project/.harness.json" 2>/dev/null || echo '[]')
project_real=$(cd "$project" && pwd -P)
# toml <jq expression over the settings JSON> — a TOML inline table; JSON strings are valid
# TOML basic strings.
toml() { jq -r "$1"' | to_entries | map("\(.key | tojson)=\(.value | tojson)") | "{" + join(",") + "}"' <<<"$settings"; }
fs=$(jq -c --arg p "$project" --arg pr "$project_real" --arg t "$session_tmp" '
  ([.sandbox.filesystem.denyRead[] | {key: ., value: "deny"}]
   + [.sandbox.filesystem.denyWrite[] | {key: ., value: "read"}]
   + [$p, $pr, $t | {key: ., value: "write"}]
   + [$p, $pr | ., "\(.)/**/CLAUDE.md", "\(.)/**/CLAUDE.local.md", "\(.)/**/AGENTS.md",
       "\(.)/**/AGENTS.override.md", "\(.)/**/.claude/**", "\(.)/**/.codex/**"
       | select(contains("/**/")) | {key: ., value: "deny"}]) | from_entries' <<<"$settings")
settings=$(jq -c --argjson fs "$fs" --argjson d "$domains" '. + {codex_fs: $fs, codex_domains: ($d | map({key: ., value: "allow"}) | from_entries),
  codex_socks: (.sandbox.network.allowUnixSockets | map({key: ., value: "allow"}) | from_entries)}' <<<"$settings")
net="{enabled=true,allow_local_binding=true,domains=$(toml .codex_domains),unix_sockets=$(toml .codex_socks)}"

# The flags every invocation (check and session) shares.
common=(--enable network_proxy
  -c 'default_permissions="lean"'
  -c 'permissions.lean.extends=":read-only"'
  -c "permissions.lean.filesystem=$(toml .codex_fs)"
  -c "permissions.lean.network=$net"
  -c 'approvals_reviewer="user"'
  -c 'shell_environment_policy.exclude=["OPENAI_*","CODEX_API_KEY"]'
  -c "shell_environment_policy.set.TMPDIR=$(jq -Rn --arg t "$session_tmp/" '$t')"
  -c 'shell_environment_policy.set.GIT_CONFIG_GLOBAL="/dev/null"'
  -c 'shell_environment_policy.set.GIT_OPTIONAL_LOCKS="0"'
  -c 'shell_environment_policy.set.RUSTC_WRAPPER=""'
  -c 'shell_environment_policy.set.CARGO_BUILD_RUSTC_WRAPPER=""'
  -c 'shell_environment_policy.set.SSH_AUTH_SOCK=""')

lean_env_args "$project" '^(OPENAI_|CODEX_)' || exit 1
# No proxy variable of the caller reaches Codex (lean_env_args keeps them, credentials
# stripped): -u for each, and their NAME=value assignments dropped; the same for the markers
# Codex sets inside its sandbox, so only Codex can set them.
unset_args=() env_args=()
while IFS= read -r -d '' n; do
  if printf '%s\n' "$n" | grep -qiE 'proxy$|^CODEX_(SANDBOX|NETWORK_)'; then unset_args+=(-u "$n"); fi
done < <(lean_env_names)
for a in "${LEAN_ENV_ARGS[@]}"; do
  case "$a" in *=*) ! printf '%s\n' "${a%%=*}" | grep -qiE 'proxy$' || continue ;; esac
  env_args+=("$a")
done
cmd=(env ${unset_args[@]+"${unset_args[@]}"} "${env_args[@]}" TMPDIR="$session_tmp/" SSH_AUTH_SOCK= codex)

# Self-check: the same profile, applied by `codex sandbox` (no model).
check='[ "${CODEX_SANDBOX:-}" = seatbelt ] || { echo "seatbelt is not active"; exit 1; }
if (echo x > "$1/written") 2>/dev/null; then echo "a write outside the project went through"; exit 1; fi
if cat "$1/canary" >/dev/null 2>&1; then echo "the lean state is readable"; exit 1; fi
if [ -n "$3" ] && cat "$3" >/dev/null 2>&1; then echo "a secret file in the project is readable: $3"; exit 1; fi
( : > "$2/lean-check" ) 2>/dev/null || { echo "the session TMPDIR is not writable"; exit 1; }
[ "${CODEX_NETWORK_PROXY_ACTIVE:-}" = 1 ] || { echo "no network proxy (outbound network would be open)"; exit 1; }
for v in "${HTTPS_PROXY:-}" "${HTTP_PROXY:-}"; do
  case "$v" in http://127.0.0.1:*) ;; *) echo "no network proxy (outbound network would be open)"; exit 1 ;; esac
done
echo LEAN-CODEX-SANDBOX-OK'
# A secret file the profile must deny (lean/lib.sh lean_secret_files; a regular file).
secret=""
while IFS= read -r -d '' f; do [ -L "$f" ] || [ ! -f "$f" ] || { secret="$f"; break; }; done < <(lean_secret_files "$project")
out=$(cd "$project" && "${cmd[@]}" sandbox "${common[@]}" -- /bin/sh -c "$check" sh "$canary" "$session_tmp" "$secret" 2>&1 < /dev/null) || true
if [ "$(printf '%s\n' "$out" | tail -1)" != LEAN-CODEX-SANDBOX-OK ]; then
  echo "lean: the Codex sandbox could not be confirmed, refusing to start: $(printf '%s\n' "$out" | tail -3 | tr '\n' ' ' | cut -c1-300)" >&2
  exit 3
fi
rm -rf "$canary"   # before exec (interactive), which skips the EXIT trap
[ "$mode" != check ] || { echo "lean: Codex sandbox confirmed for $project"; exit 0; }

system_toml=$(jq -Rs . < "$system_file")
model_args=()
[ "$model" = - ] || model_args=(-m "$model")

cd "$project"
case "$mode" in
  interactive)
    exec "${cmd[@]}" "${common[@]}" -c 'approval_policy="never"' -c "developer_instructions=$system_toml" \
      ${model_args[@]+"${model_args[@]}"} -C "$project" "$prompt" ;;
  headless)
    events="${result%.json}.events.jsonl" last="${result%.json}.last.txt"
    start=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
    rc=0
    "${cmd[@]}" exec "${common[@]}" -c 'approval_policy="never"' -c "developer_instructions=$system_toml" \
      --ignore-rules ${model_args[@]+"${model_args[@]}"} -C "$project" --json -o "$last" "$prompt" \
      < /dev/null > "$events" || rc=$?
    end=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
    # The events, read tolerantly (a line that isn't a JSON object is skipped).
    jq -R 'fromjson? | select(type == "object")' "$events" | jq -s \
      --argjson rc "$rc" --argjson ms "$((end - start))" --rawfile last <(cat "$last" 2>/dev/null || true) \
      --arg events "$events" '
      def n: if type == "number" then . else 0 end;
      ([.[] | select(.type == "turn.completed") | .usage // {}]) as $u
      | ([.[] | select(.type == "turn.failed" or .type == "error")]) as $errs
      | {type: "result", tool: "codex",
         is_error: ($rc != 0 or ($errs | length) > 0 or ($u | length) == 0),
         duration_ms: $ms,
         num_turns: ([.[] | select(.type == "item.completed")] | length),
         result: $last,
         session_id: ([.[] | select(.type == "thread.started") | .thread_id][0]),
         total_cost_usd: null,
         usage: {input_tokens: ([$u[] | .input_tokens | n] | add // 0),
                  cache_read_input_tokens: ([$u[] | .cached_input_tokens | n] | add // 0),
                  cache_creation_input_tokens: ([$u[] | .cache_write_input_tokens | n] | add // 0),
                  output_tokens: ([$u[] | .output_tokens | n] | add // 0),
                  reasoning_output_tokens: ([$u[] | .reasoning_output_tokens | n] | add // 0)},
         exit_code: $rc,
         errors: [$errs[] | (.error.message // .message // tostring)],
         events_file: $events}' > "$result"
    rm -f "$last"
    exit "$rc" ;;
esac
