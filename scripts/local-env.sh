#!/usr/bin/env bash
# Writes .env.local for the local stack from `supabase status`. Keys stay in the file
# (git-ignored) and are never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
eval "$(npx supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY)=')"
cat > .env.local <<ENV
NEXT_PUBLIC_SUPABASE_URL=${API_URL}
NEXT_PUBLIC_SUPABASE_ANON_KEY=${ANON_KEY}
SUPABASE_SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
SITE_URL=http://localhost:3000
SMTP_HOST=127.0.0.1
SMTP_PORT=55625
MAIL_FROM="Octra Access <no-reply@octra.local>"
ENV
echo "wrote .env.local"
