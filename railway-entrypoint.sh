#!/bin/sh
# AppFlowy Cloud on Railway — boot sequence for the consolidated container.
#
# Order matters: the admin account is seeded (and its password re-applied)
# BEFORE any process binds a port, so the first request the public URL ever
# serves is against a claimed instance.
set -eu

log() { echo "[railway-entrypoint] $*"; }
die() { echo "[railway-entrypoint] FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- credentials
[ -n "${APPFLOWY_ADMIN_PASSWORD:-}" ] || die "APPFLOWY_ADMIN_PASSWORD is empty. Refusing to boot: an AppFlowy instance with no admin account is claimed by whoever loads the URL first."
[ -n "${APPFLOWY_ADMIN_EMAIL:-}" ] || die "APPFLOWY_ADMIN_EMAIL is empty."
[ -n "${GOTRUE_JWT_SECRET:-}" ] || die "GOTRUE_JWT_SECRET is empty."

# ------------------------------------------------------------------- base URL
if [ -z "${APPFLOWY_BASE_URL:-}" ]; then
  [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ] || die "Neither APPFLOWY_BASE_URL nor RAILWAY_PUBLIC_DOMAIN is set."
  APPFLOWY_BASE_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi
PUBLIC_HOST=$(echo "$APPFLOWY_BASE_URL" | sed -e 's|^https\{0,1\}://||' -e 's|/.*$||')
case "$APPFLOWY_BASE_URL" in
  https://*) WS_SCHEME=wss ;;
  *)         WS_SCHEME=ws  ;;
esac
export APPFLOWY_BASE_URL
export APPFLOWY_WEB_URL="$APPFLOWY_BASE_URL"
export APPFLOWY_CLOUD_BASE_URL="$APPFLOWY_BASE_URL"
export APPFLOWY_WS_BASE_URL="${WS_SCHEME}://${PUBLIC_HOST}/ws/v2"
export APPFLOWY_PUBLIC_GOTRUE_URL="${APPFLOWY_BASE_URL}/gotrue"

# ------------------------------------------------------------------- database
[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is empty."
case "$DATABASE_URL" in
  *\?*) GOTRUE_DB_URL="${DATABASE_URL}&search_path=auth" ;;
  *)    GOTRUE_DB_URL="${DATABASE_URL}?search_path=auth" ;;
esac
DB_NAME=$(echo "$DATABASE_URL" | sed -e 's|^.*/||' -e 's|?.*$||')

export APPFLOWY_DATABASE_URL="$DATABASE_URL"
export APPFLOWY_WORKER_DATABASE_URL="$DATABASE_URL"
export APPFLOWY_WORKER_DATABASE_NAME="$DB_NAME"
export APPFLOWY_INDEXER_DATABASE_URL="$DATABASE_URL"
export GOTRUE_DATABASE_URL="$GOTRUE_DB_URL"
export GOTRUE_DB_DATABASE_URL="$GOTRUE_DB_URL"

# ---------------------------------------------------------------------- redis
[ -n "${REDIS_URL:-}" ] || die "REDIS_URL is empty."
export APPFLOWY_REDIS_URI="$REDIS_URL"
export APPFLOWY_WORKER_REDIS_URL="$REDIS_URL"
export APPFLOWY_INDEXER_REDIS_URL="$REDIS_URL"

# ---------------------------------------------------------------------- minio
DATA_DIR="${APPFLOWY_DATA_DIR:-/data}"
export APPFLOWY_MINIO_DIR="${DATA_DIR}/minio"
mkdir -p "$APPFLOWY_MINIO_DIR"
[ -n "${MINIO_ROOT_USER:-}" ] || export MINIO_ROOT_USER="appflowy"
[ -n "${MINIO_ROOT_PASSWORD:-}" ] || die "MINIO_ROOT_PASSWORD is empty."
export MINIO_ROOT_USER MINIO_ROOT_PASSWORD
export APPFLOWY_S3_MINIO_URL="http://127.0.0.1:9000"
export APPFLOWY_S3_ACCESS_KEY="$MINIO_ROOT_USER"
export APPFLOWY_S3_SECRET_KEY="$MINIO_ROOT_PASSWORD"
# Without this, presigned upload URLs are handed to the browser pointing at the
# INTERNAL S3 endpoint, which no client outside the deploy can reach.
export APPFLOWY_S3_PRESIGNED_URL_ENDPOINT="${APPFLOWY_BASE_URL}/minio-api"

# --------------------------------------------------------------------- gotrue
export GOTRUE_SITE_URL="$APPFLOWY_BASE_URL"
export API_EXTERNAL_URL="${APPFLOWY_BASE_URL}/gotrue"
export GOTRUE_MAILER_EXTERNAL_HOSTS="$PUBLIC_HOST"
export GOTRUE_JWT_ADMIN_GROUP_NAME="supabase_admin"
export GOTRUE_JWT_AUD="authenticated"
export APPFLOWY_GOTRUE_JWT_SECRET="$GOTRUE_JWT_SECRET"
export APPFLOWY_GOTRUE_BASE_URL="http://127.0.0.1:9999"
# AppFlowy-Cloud talks to GoTrue's admin API with its own service account. That
# account MUST be a GoTrue system admin, and a system admin is exactly what the
# deployer's login must NOT be: AppFlowy-Cloud refuses to create an af_user row
# (and therefore a workspace) for one, so signing in as it yields
# `{"code":1024,"message":"User not found"}` forever. The two accounts are
# therefore separate, and only the second one is handed to the deployer.
SYSTEM_ADMIN_EMAIL="appflowy-system-admin@internal.invalid"
SYSTEM_ADMIN_PASSWORD=$(printf '%s' "gotrue-system-admin:${GOTRUE_JWT_SECRET}" | sha256sum | cut -c1-48)
export APPFLOWY_GOTRUE_ADMIN_EMAIL="$SYSTEM_ADMIN_EMAIL"
export APPFLOWY_GOTRUE_ADMIN_PASSWORD="$SYSTEM_ADMIN_PASSWORD"
export GOTRUE_ADMIN_EMAIL="$SYSTEM_ADMIN_EMAIL"
export GOTRUE_ADMIN_PASSWORD="$SYSTEM_ADMIN_PASSWORD"
# Public sign-up is off unless the deployer asks for it: the URL is public from
# the moment Railway publishes it.
case "$(echo "${APPFLOWY_ALLOW_SIGNUP:-false}" | tr 'A-Z' 'a-z')" in
  true|1|yes) export GOTRUE_DISABLE_SIGNUP="false" ;;
  *)          export GOTRUE_DISABLE_SIGNUP="true"  ;;
esac
# AppFlowy's own mailer only sends workspace invitations; with no SMTP account
# configured, keep e-mail confirmation off so accounts are usable immediately.
if [ -z "${GOTRUE_SMTP_HOST:-}" ]; then
  export GOTRUE_MAILER_AUTOCONFIRM="true"
fi

# --------------------------------------------------------------- wait for pg
log "waiting for Postgres"
i=0
until psql "$DATABASE_URL" -tAc 'select 1' >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 120 ] || die "Postgres did not become reachable"
  sleep 2
done
log "Postgres reachable"

# --------------------------------------------------- gotrue migrate + seeding
cd /gotrue
log "running GoTrue migrations"
/usr/local/bin/gotrue migrate

# Re-applying the password on every boot makes a redeploy a working password
# reset: GoTrue has no updateuser subcommand, and AppFlowy's recovery flow needs
# an SMTP account this template deliberately avoids.
seed_account() {
  seed_email="$1"; seed_password="$2"; seed_admin="$3"
  if [ "$seed_admin" = "admin" ]; then
    out=$(/usr/local/bin/gotrue admin createuser --admin --confirm "$seed_email" "$seed_password" 2>&1) && rc=0 || rc=$?
  else
    out=$(/usr/local/bin/gotrue admin createuser --confirm "$seed_email" "$seed_password" 2>&1) && rc=0 || rc=$?
  fi
  if [ "$rc" = 0 ]; then
    log "created account ${seed_email}"
    return 0
  fi
  case "$out" in
    *"already exists"*|*"duplicate key"*)
      log "account ${seed_email} exists — re-applying password"
      psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
        -c "CREATE EXTENSION IF NOT EXISTS pgcrypto" \
        -c "UPDATE auth.users SET encrypted_password = crypt('${seed_password}', gen_salt('bf')), updated_at = now() WHERE email = '${seed_email}'"
      ;;
    *) die "creating the account ${seed_email} failed: $out" ;;
  esac
}

log "seeding GoTrue service account and admin account ${APPFLOWY_ADMIN_EMAIL}"
seed_account "$SYSTEM_ADMIN_EMAIL" "$SYSTEM_ADMIN_PASSWORD" admin
seed_account "$APPFLOWY_ADMIN_EMAIL" "$APPFLOWY_ADMIN_PASSWORD" user

# --------------------------------------------------------------- web frontend
# The stock appflowy_web entrypoint injects the runtime config into the served
# HTML; this container replaces that entrypoint, so do it here.
CONFIG_SCRIPT="<script>window.__APP_CONFIG__={APPFLOWY_BASE_URL:'${APPFLOWY_BASE_URL}',APPFLOWY_GOTRUE_BASE_URL:'${APPFLOWY_PUBLIC_GOTRUE_URL}',APPFLOWY_WS_BASE_URL:'${APPFLOWY_WS_BASE_URL}'};</script>"
for html in /usr/share/nginx/html/index.html /app/dist/index.html; do
  [ -f "$html" ] || continue
  [ -f "${html}.orig" ] || cp "$html" "${html}.orig"
  sed "s|</head>|${CONFIG_SCRIPT}</head>|g" "${html}.orig" > "$html"
done

# --------------------------------------------------------------------- nginx
PORT="${PORT:-8080}"
AUTH_RATE="${APPFLOWY_AUTH_RATE_PER_MIN:-20}"
AUTH_BURST="${APPFLOWY_AUTH_BURST:-5}"
sed -e "s|__PORT__|${PORT}|g" \
    -e "s|__AUTH_RATE__|${AUTH_RATE}|g" \
    -e "s|__AUTH_BURST__|${AUTH_BURST}|g" \
    /etc/appflowy/nginx.conf.template > /etc/nginx/nginx.conf
nginx -t

log "signup_disabled=${GOTRUE_DISABLE_SIGNUP} base_url=${APPFLOWY_BASE_URL} port=${PORT} data_dir=${DATA_DIR}"
mkdir -p /var/log/supervisor
exec supervisord -c /etc/appflowy/supervisord.conf
