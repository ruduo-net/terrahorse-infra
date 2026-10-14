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

umask 077
install -d -m 0700 "$root/releases"
candidate=$(mktemp -d "$root/releases/candidate.XXXXXX")
container=
retain=false
cleanup() {
  if [ -n "$container" ]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
  if [ "$retain" != true ]; then rm -rf -- "$candidate"; fi
}
trap cleanup EXIT
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

compose() {
  docker compose --project-name "$project" --env-file "$1/.env" -f "$1/compose.shipment-operator.yml" -f "$1/compose.shipment-operator.ec2.yml" "${@:2}"
}
compose "$candidate" config --quiet
compose "$candidate" pull >/dev/null
previous=
if [ -L "$root/active" ]; then previous=$(readlink -f "$root/active"); fi
if [ -n "$previous" ]; then
  case "$previous" in "$root/releases/"*) ;; *) fail 'unexpected active shipment directory' ;; esac
  if cmp -s "$previous/.env" "$candidate/.env" &&
    cmp -s "$previous/compose.shipment-operator.yml" "$candidate/compose.shipment-operator.yml" &&
    cmp -s "$previous/compose.shipment-operator.ec2.yml" "$candidate/compose.shipment-operator.ec2.yml"; then
    compose "$previous" up -d --wait --wait-timeout 60 >/dev/null
    exit 0
  fi
fi
retain=true
if compose "$candidate" up -d --wait --wait-timeout 60 >/dev/null &&
  curl -fsS --max-time 10 http://127.0.0.1:3200/health | jq -e --arg version "$version" '.status == "ok" and .service == "shipment-operator" and .version == $version' >/dev/null; then
  ln -sfn "$candidate" "$root/active.next"
  mv -Tf "$root/active.next" "$root/active"
  echo 'Shipment dev runtime healthy; booking remains disabled.'
else
  if [ -n "$previous" ]; then
    compose "$previous" up -d --wait --wait-timeout 60 >/dev/null || fail 'candidate failed and previous shipment runtime could not be restored'
  else
    compose "$candidate" down >/dev/null || fail 'candidate teardown failed'
  fi
  retain=false
  fail 'candidate failed health; previous shipment runtime restored or candidate removed'
fi
