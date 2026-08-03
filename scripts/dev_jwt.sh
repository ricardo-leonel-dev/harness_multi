#!/usr/bin/env bash
# dev_jwt.sh — signs a local-dev-only HS256 JWT matching docker-compose.yml's
# PGRST_JWT_SECRET, and prints commands that set SUPABASE_URL /
# SUPABASE_ANON_KEY in your shell. Not for anything beyond the local
# Postgres+PostgREST stack this repo's docker-compose.yml stands up.
#
# Usage:
#   bash/zsh:  source <(bash scripts/dev_jwt.sh)
#   fish:      bash scripts/dev_jwt.sh --fish | source
set -eu

SECRET="harness-local-dev-jwt-secret-at-least-32-chars"

SHELL_FORMAT="posix"
if [ "${1:-}" = "--fish" ]; then
  SHELL_FORMAT="fish"
fi

b64url() {
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
payload=$(printf '{"role":"postgres","iss":"harness-local-dev"}' | b64url)
signing_input="${header}.${payload}"
sig=$(printf '%s' "$signing_input" | openssl dgst -sha256 -hmac "$SECRET" -binary | b64url)
token="${signing_input}.${sig}"

if [ "$SHELL_FORMAT" = "fish" ]; then
  echo "set -gx SUPABASE_URL http://localhost:3001"
  echo "set -gx SUPABASE_ANON_KEY $token"
else
  echo "export SUPABASE_URL=http://localhost:3001"
  echo "export SUPABASE_ANON_KEY=$token"
fi
echo "# .harness.json needs: \"supabase_rest_path\": \"\"  (bare PostgREST has no /rest/v1 prefix)" >&2
