#!/bin/bash
set -euo pipefail

# This service is deliberately absent from production cloud-init.
region=eu-north-1
account=462432303731
prefix=/terrahorse/dev/ec2
root=/opt/terrahorse/shipment
project=terrahorse-shipment-operator
network=terrahorse-product-editor
certificate=/opt/terrahorse/data/tls/api.crt

fail() { echo "Shipment dev deployment: $1" >&2; exit 1; }
[ "$(aws sts get-caller-identity --query Account --output text)" = "$account" ] || fail 'unexpected AWS account'
metadata_token=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
instance_id=$(curl -fsS -H "X-aws-ec2-metadata-token: $metadata_token" http://169.254.169.254/latest/meta-data/instance-id)
exec 9>/run/terrahorse-reconcile.lock
flock -n 9 || exit 0

status=$(aws ssm get-parameter --region "$region" --name "$prefix/deploy/status" --query Parameter.Value --output text)
[ "$(jq -er '.state' <<< "$status")" = succeeded ] || exit 0
[ "$(jq -er '.instance_id' <<< "$status")" = "$instance_id" ] || fail 'release belongs to another host'
release=$(jq -er '.release' <<< "$status")
registry="$account.dkr.ecr.$region.amazonaws.com"
[[ "$release" =~ ^$account\.dkr\.ecr\.$region\.amazonaws\.com/terrahorse-release@sha256:[a-f0-9]{64}$ ]] || fail 'release must be an owned immutable digest'
[ -f "$certificate" ] && openssl x509 -in "$certificate" -noout >/dev/null || fail 'internal Saleor CA is missing or invalid'
if [ -e "$root/active" ] && [ ! -L "$root/active" ]; then
  fail 'active runtime must be the managed symlink'
fi
if [ -L "$root/active" ] && [ ! -d "$root/active" ]; then
  fail 'active runtime symlink must reference an existing directory'
fi

# The parent reconciler owns this network. Never attach to an unknown shared network.
details=$(docker network inspect "$network")
[ "$(jq -er '.[0].Driver' <<< "$details")" = bridge ] && [ "$(jq -er '.[0].Scope' <<< "$details")" = local ] || fail 'unexpected private network'
api_found=false
cache_found=false
for id in $(jq -r '.[0].Containers // {} | keys[]' <<< "$details"); do
  owner=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}:{{index .Config.Labels "com.docker.compose.service"}}' "$id")
  case "$owner" in
    terrahorse-ec2:api) api_found=true ;;
    terrahorse-ec2:cache) cache_found=true ;;
    terrahorse-product-editor:product-editor|terrahorse-shipment-operator:shipment-operator) ;;
    *) fail 'unexpected private network member' ;;
  esac
done
[ "$api_found" = true ] && [ "$cache_found" = true ] || fail 'private Saleor and Valkey must already be running'
media_id=$(docker ps --filter label=com.docker.compose.project=terrahorse-ec2 --filter label=com.docker.compose.service=media --format '{{.ID}}')
[[ "$media_id" =~ ^[a-f0-9]{12,64}$ ]] || fail 'one active owning media proxy is required'
asset_image=$(docker inspect --format '{{.Image}}' "$media_id")
[[ "$asset_image" =~ ^sha256:[a-f0-9]{64}$ ]] || fail 'media proxy must have an immutable local image'

umask 077
install -d -m 0700 "$root/releases"
candidate=$(mktemp -d "$root/releases/candidate.XXXXXX")
container=
retain=false
previous=
candidate_started=false
cleanup() {
  # A start timeout can arrive while EXIT cleanup is already restoring the project.
  # Let an interrupted Compose command fail into teardown instead of exiting this trap.
  trap '' TERM INT
  if [ "$candidate_started" = true ]; then
    if restore_runtime; then
      retain=false
      echo 'Previous shipment runtime restored or first candidate removed.' >&2
    else
      retain=true
      if compose "$candidate" down --remove-orphans --timeout 10 >/dev/null; then
        echo 'Shipment rollback failed; exact project stopped and private inputs retained.' >&2
      else
        echo 'Shipment rollback and teardown failed; operator intervention required.' >&2
      fi
    fi
  fi
  if [ -n "$container" ]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
  if [ "$retain" != true ]; then rm -rf -- "$candidate"; fi
}
trap cleanup EXIT
trap 'exit 143' TERM INT
aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry" >/dev/null
docker pull "$release" >/dev/null
[ "$(docker image inspect --format '{{index .Config.Labels "lt.terrahorse.release.shipment-operator-contract"}}' "$release")" = 1 ] || fail 'release lacks shipment contract v1'
container=$(docker create "$release")
for file in compose.shipment-operator.yml compose.shipment-operator.ec2.yml release.json; do
  docker cp "$container:/release/$file" "$candidate/$file"
done
docker rm "$container" >/dev/null
container=
image=$(jq -er '.storefront_image' "$candidate/release.json")
version=$(jq -er '.release' "$candidate/release.json")
[[ "$image" =~ ^$account\.dkr\.ecr\.$region\.amazonaws\.com/terrahorse@sha256:[a-f0-9]{64}$ ]] || fail 'runtime must be an owned immutable digest'
config=$(aws ssm get-parameter --region "$region" --name "$prefix/config" --query Parameter.Value --output text)
[ "$(jq -er '.SHIPMENT_OPERATOR_PUBLIC_URL' <<< "$config")" = https://dev.terrahorse.lt ] || fail 'unexpected panel origin'
[ "$(jq -er '.SALEOR_OPERATOR_API_URL' <<< "$config")" = https://api:8443/graphql/ ] || fail 'unexpected private Saleor endpoint'
[ "$(jq -er '.NUXT_PUBLIC_SALEOR_API_URL' <<< "$config")" = https://api-dev.terrahorse.lt/graphql/ ] || fail 'unexpected public Saleor endpoint'

write_value() {
  local key="$1" value="$2"
  [ -n "$value" ] && [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *"'"* && "$value" != *'\'* ]] || fail "invalid $key"
  printf "%s='%s'\n" "$key" "$value" >> "$candidate/.env"
}
for key in SHIPMENT_OPERATOR_PUBLIC_URL SALEOR_OPERATOR_API_URL NUXT_PUBLIC_SALEOR_API_URL SALEOR_DASHBOARD_URL SALEOR_CHANNEL SALEOR_VENIPAK_PARCEL_LOCKER_METHOD_ID SALEOR_VENIPAK_COURIER_METHOD_ID; do
  value=$(jq -er --arg key "$key" '.[$key] | select(type == "string" and length > 0)' <<< "$config") || fail "missing $key"
  write_value "$key" "$value"
done
for key in SALEOR_COMMERCE_APP_TOKEN MONTONIO_ACCESS_KEY MONTONIO_SECRET_KEY SALEOR_SHIPMENT_PAGE_TYPE_ID; do
  value=$(aws ssm get-parameter --region "$region" --name "$prefix/$key" --with-decryption --query Parameter.Value --output text) || fail "missing $key"
  write_value "$key" "$value"
done
write_value SHIPMENT_OPERATOR_IMAGE "$image"
write_value APP_VERSION "$version"
write_value NUXT_PUBLIC_ENVIRONMENT preview
write_value SHIPMENT_OPERATOR_NETWORK "$network"
write_value SHIPMENT_OPERATOR_REDIS_URL redis://cache:6379/2
write_value LOG_LEVEL info
write_value SHIPMENT_ASSET_PROXY_IMAGE "$asset_image"

write_asset_overlay() {
  cat > "$1/compose.shipment-assets.yml" <<'COMPOSE'
services:
  shipment-operator:
    environment:
      NUXT_APP_CDN_URL: https://dev.terrahorse.lt/shipment-operator/assets
    networks:
      - shipment-assets
  shipment-assets:
    image: ${SHIPMENT_ASSET_PROXY_IMAGE:?SHIPMENT_ASSET_PROXY_IMAGE is required}
    pull_policy: never
    entrypoint: [nginx, -c, /etc/nginx/shipment-assets.conf, -g, "daemon off;"]
    restart: unless-stopped
    read_only: true
    user: '101:101'
    mem_limit: 64m
    cpus: 0.25
    pids_limit: 32
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    tmpfs: [/tmp:size=8m,mode=1777,nosuid,nodev,noexec]
    volumes:
      - ./shipment-assets.conf:/etc/nginx/shipment-assets.conf:ro
    ports:
      - 127.0.0.1:3210:8080
    networks:
      - shipment-ingress
      - shipment-assets
    depends_on:
      shipment-operator:
        condition: service_healthy
    healthcheck:
      test: [CMD-SHELL, "wget -q -O /dev/null http://127.0.0.1:8080/health"]
      interval: 10s
      timeout: 3s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: 16m
        max-file: '2'
networks:
  shipment-ingress: {}
  shipment-assets:
    internal: true
COMPOSE
  cat > "$1/shipment-assets.conf" <<'NGINX'
pid /tmp/nginx.pid;
error_log stderr warn;
events { worker_connections 64; }
http {
  access_log off;
  resolver 127.0.0.11 valid=1s ipv6=off;
  upstream shipment_runtime {
    zone shipment_runtime 32k;
    server shipment-operator:3000 resolve;
  }
  client_body_temp_path /tmp/client;
  proxy_temp_path /tmp/proxy;
  fastcgi_temp_path /tmp/fastcgi;
  uwsgi_temp_path /tmp/uwsgi;
  scgi_temp_path /tmp/scgi;
  server {
    listen 8080;
    location = /health { return 200 'ok'; }
    location ^~ /shipment-operator/assets/_nuxt/ {
      limit_except GET { deny all; }
      proxy_set_header Authorization '';
      proxy_set_header Cookie '';
      proxy_pass http://shipment_runtime/_nuxt/;
    }
    location / { return 404; }
  }
}
NGINX
  chmod 0644 "$1/shipment-assets.conf"
}
write_asset_overlay "$candidate"
compose() {
  docker compose --project-name "$project" --env-file "$1/.env" -f "$1/compose.shipment-operator.yml" -f "$1/compose.shipment-operator.ec2.yml" -f "$1/compose.shipment-assets.yml" "${@:2}"
}
restore_runtime() {
  if [ -n "$previous" ]; then
    compose "$previous" up -d --remove-orphans --wait --wait-timeout 60 >/dev/null || return 1
    verify_assets || return 1
    ln -sfn "$previous" "$root/active.next" && mv -Tf "$root/active.next" "$root/active"
  else
    compose "$candidate" down --remove-orphans >/dev/null || return 1
    if [ -L "$root/active" ] && [ "$(readlink -f "$root/active")" = "$candidate" ]; then rm "$root/active"; fi
  fi
}
verify_assets() {
  local html asset
  html=$(curl -fsS --max-time 10 http://127.0.0.1:3200/en/shipment-operator) || return 1
  asset=$(printf '%s' "$html" | grep -oE 'https://dev\.terrahorse\.lt/shipment-operator/assets/_nuxt/[A-Za-z0-9_.-]+\.js' | sed -n '1p') || return 1
  [ -n "$asset" ] || return 1
  curl -fsS --max-time 10 "http://127.0.0.1:3210${asset#https://dev.terrahorse.lt}" >/dev/null
}
compose "$candidate" config --quiet
compose "$candidate" pull shipment-operator >/dev/null
if [ -L "$root/active" ]; then previous=$(readlink -f "$root/active"); fi
if [ -n "$previous" ]; then
  case "$previous" in "$root/releases/"*) ;; *) fail 'unexpected active shipment directory' ;; esac
  # Legacy candidates must also serve their own assets when used for rollback.
  write_asset_overlay "$previous"
  if ! grep -q '^SHIPMENT_ASSET_PROXY_IMAGE=' "$previous/.env"; then
    printf "SHIPMENT_ASSET_PROXY_IMAGE='%s'\n" "$asset_image" >> "$previous/.env"
  fi
  if cmp -s "$previous/.env" "$candidate/.env" &&
    cmp -s "$previous/compose.shipment-operator.yml" "$candidate/compose.shipment-operator.yml" &&
    cmp -s "$previous/compose.shipment-operator.ec2.yml" "$candidate/compose.shipment-operator.ec2.yml" &&
    cmp -s "$previous/compose.shipment-assets.yml" "$candidate/compose.shipment-assets.yml"; then
    candidate_started=true
    compose "$previous" up -d --remove-orphans --wait --wait-timeout 60 >/dev/null
    verify_assets || fail 'active shipment asset route failed health'
    candidate_started=false
    exit 0
  fi
fi
retain=true
candidate_started=true
if compose "$candidate" up -d --remove-orphans --wait --wait-timeout 60 >/dev/null &&
  curl -fsS --max-time 10 http://127.0.0.1:3200/health | jq -e --arg version "$version" '.status == "ok" and .service == "shipment-operator" and .version == $version' >/dev/null &&
  verify_assets; then
  ln -sfn "$candidate" "$root/active.next"
  mv -Tf "$root/active.next" "$root/active"
  candidate_started=false
  echo 'Shipment dev runtime healthy; booking remains disabled.'
else
  fail 'candidate failed health; restoring previous runtime or removing first candidate'
fi
