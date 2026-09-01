#!/bin/sh
set -eu

fail() { printf '%s\n' "$1" >&2; exit 1; }
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
state="$root/.e2e-run"
runtime_env=${E2E_RUNTIME_ENV_FILE:?E2E_RUNTIME_ENV_FILE is required}
secret_env=${E2E_SECRET_ENV_FILE:?E2E_SECRET_ENV_FILE is required}
config=${E2E_TUNNEL_CONFIG_FILE:?E2E_TUNNEL_CONFIG_FILE is required}
credentials=${E2E_TUNNEL_CREDENTIALS_FILE:?E2E_TUNNEL_CREDENTIALS_FILE is required}
export E2E_TUNNEL_CONFIG_FILE="$config" E2E_TUNNEL_CREDENTIALS_FILE="$credentials"

protected_file() {
  test -f "$1" && test ! -L "$1" || fail "$2 must be a regular, non-symlink file."
  test "$(stat -f '%u' "$1")" = "$(id -u)" && test "$(stat -f '%Lp' "$1")" = 600 || \
    fail "$2 must be owned by the current user with mode 0600."
}
protected_file "$runtime_env" 'Runtime environment file'
protected_file "$secret_env" 'Secret environment file'
protected_file "$config" 'Tunnel configuration file'
protected_file "$credentials" 'Tunnel credentials file'
node "$root/scripts/verify-e2e-tunnel-config.mjs" "$config" "$credentials"

set -a
. "$runtime_env"
. "$secret_env"
set +a
missing=''
# CI audits this exact external-input contract.
for name in MONTONIO_ACCESS_KEY MONTONIO_SECRET_KEY COMMERCE_EVENT_HMAC_KEY; do
  eval "value=\${$name-}"
  test -n "$value" || missing="$missing $name"
done
test -z "$missing" || fail "Missing required external names:$missing"
test "${#COMMERCE_EVENT_HMAC_KEY}" -ge 32 || fail 'COMMERCE_EVENT_HMAC_KEY must be at least 32 characters.'
unset SALEOR_API_URL SALEOR_COMMERCE_APP_TOKEN SALEOR_PAYMENT_APP_ID \
  SALEOR_PAYMENT_GATEWAY_ID SALEOR_VENIPAK_PARCEL_LOCKER_METHOD_ID \
  SALEOR_VENIPAK_COURIER_METHOD_ID SALEOR_PAYMENT_WEBHOOK_SECRET \
  SALEOR_CHANNEL SALEOR_STOCK_AVAILABILITY_MODE \
  SALEOR_STOCK_COUNTRY_CODE CATALOG_SOURCE
test ! -e "$state" || fail 'An E2E boundary is already owned; stop it before starting another.'

web_root=$("$root/scripts/prepare-e2e-storefront-worktree.sh")
revision=$(git -C "$web_root" rev-parse HEAD)
test "$(git -C "$web_root" status --porcelain)" = '' || fail 'Managed E2E worktree is not clean.'
umask 077
mkdir "$state" || fail 'Could not acquire the E2E owner state.'
export E2E_INFRA_ROOT="$root" E2E_RUN_STATE_DIR="$state" E2E_STOREFRONT_WORKTREE="$web_root" APP_VERSION="$revision"

database_password=$(openssl rand -hex 32)
saleor_secret=$(openssl rand -hex 64)
payment_webhook_secret=$(openssl rand -hex 32)
printf '%s\n' \
  "APP_VERSION=$revision" \
  "E2E_INFRA_ROOT=$root" \
  "E2E_RUN_STATE_DIR=$state" \
  "E2E_STOREFRONT_WORKTREE=$web_root" \
  "SALEOR_DATABASE_PASSWORD=$database_password" \
  "SALEOR_SECRET_KEY=$saleor_secret" \
  "SALEOR_PAYMENT_WEBHOOK_SECRET=$payment_webhook_secret" > "$state/saleor.env"
printf '%s\n' "$revision" "$web_root" "$runtime_env" "$secret_env" "$config" "$credentials" > "$state/owner"
chmod 600 "$state/saleor.env" "$state/owner"
set -a
. "$state/saleor.env"
set +a

compose_base() {
  docker compose --project-name terrahorse-web-e2e \
    --env-file "$runtime_env" --env-file "$secret_env" --env-file "$state/saleor.env" \
    -f "$root/compose.e2e.yml" --profile tunnel --profile setup --profile verify "$@"
}
compose_full() {
  docker compose --project-name terrahorse-web-e2e \
    --env-file "$runtime_env" --env-file "$secret_env" \
    --env-file "$state/saleor.env" --env-file "$state/runtime.env" \
    -f "$web_root/compose.yml" -f "$web_root/compose.preview.yml" \
    -f "$root/compose.e2e.yml" --profile tunnel --profile verify "$@"
}
cleanup() {
  code=$?
  trap - EXIT INT TERM
  if compose_base down --volumes --remove-orphans >/dev/null 2>&1 &&
    remaining_containers=$(docker ps -aq --filter label=com.docker.compose.project=terrahorse-web-e2e) &&
    remaining_volumes=$(docker volume ls -q --filter label=com.docker.compose.project=terrahorse-web-e2e) &&
    test -z "$remaining_containers" && test -z "$remaining_volumes"; then
    case "$state" in "$root/.e2e-run") rm -rf "$state" ;; *) fail 'Refusing unexpected run-state cleanup target.' ;; esac
  else
    printf '%s\n' 'Project cleanup incomplete; owner state retained for project-scoped recovery.' >&2
  fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

compose_base config --quiet
compose_base up -d --wait --wait-timeout 60 saleor-db saleor-cache
compose_base up -d saleor-setup
compose_base wait saleor-setup
protected_file "$state/runtime.env" 'Generated Saleor runtime file'
set -a
. "$state/runtime.env"
set +a

export NUXT_PUBLIC_SITE_URL=https://e2e.terrahorse.lt
export PAYMENT_CALLBACK_ORIGIN=https://e2e.terrahorse.lt
compose_full config --quiet
compose_full up -d --wait --wait-timeout 120 saleor-api saleor-worker saleor-beat
compose_full run --rm --no-deps saleor-verify

for service in saleor-api saleor-worker saleor-beat; do
  count=$(docker ps --filter label=com.docker.compose.project=terrahorse-web-e2e \
    --filter "label=com.docker.compose.service=$service" --format '{{.ID}}' | wc -l | tr -d ' ')
  test "$count" = 1 || fail "Expected exactly one running $service container."
done

compose_full up -d --build --wait --wait-timeout 180 storefront cloudflared
curl -fsS --max-time 10 http://127.0.0.1:4100/health | \
  node -e 'let s="";process.stdin.on("data",x=>s+=x);process.stdin.on("end",()=>{const x=JSON.parse(s);process.exit(x.environment==="preview"&&x.version===process.env.APP_VERSION?0:1)})'
ready=false
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if E2E_STOREFRONT_SHA="$revision" "$root/scripts/verify-e2e-boundary.sh" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if test "$ready" != true; then
  E2E_STOREFRONT_SHA="$revision" "$root/scripts/verify-e2e-boundary.sh" || true
  fail 'Public E2E boundary did not become ready.'
fi
E2E_STOREFRONT_SHA="$revision" "$root/scripts/verify-e2e-boundary.sh"
trap - EXIT INT TERM
printf '%s\n' "E2E storefront $revision and disposable Saleor started."
