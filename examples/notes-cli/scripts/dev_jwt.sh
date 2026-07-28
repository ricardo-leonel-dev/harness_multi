#!/usr/bin/env bash
# dev_jwt.sh — signs a local-dev-only HS256 JWT matching docker-compose.yml's
# PGRST_JWT_SECRET, and prints export statements for SUPABASE_URL /
# SUPABASE_ANON_KEY. Not for anything beyond the local Postgres+PostgREST
# stack this repo's docker-compose.yml stands up.
#
# Usage: source <(bash scripts/dev_jwt.sh)
set -eu

SECRET="harness-local-dev-jwt-secret-at-least-32-chars"

b64url() {
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
payload=$(printf '{"role":"postgres","iss":"harness-local-dev"}' | b64url)
signing_input="${header}.${payload}"
sig=$(printf '%s' "$signing_input" | openssl dgst -sha256 -hmac "$SECRET" -binary | b64url)
token="${signing_input}.${sig}"

echo "export SUPABASE_URL=http://localhost:3001"
echo "export SUPABASE_ANON_KEY=$token"
echo "# .harness.json needs: \"supabase_rest_path\": \"\"  (bare PostgREST has no /rest/v1 prefix)" >&2
