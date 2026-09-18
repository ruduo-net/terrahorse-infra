#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

if [ "$(uname -s)" != Darwin ] || [ -n "${DOCKER_HOST:-}" ] || [ -n "${DOCKER_CONTEXT:-}" ]; then
  echo 'Use this script on the Mac with the local Docker Desktop context and no Docker overrides' >&2
  exit 1
fi

if [ "$(docker context show)" != desktop-linux ] \
  || [ "$(docker context inspect desktop-linux --format '{{ .Endpoints.docker.Host }}')" != "unix://$HOME/.docker/run/docker.sock" ] \
  || [ "$(docker info --format '{{.Name}}|{{.OperatingSystem}}')" != 'docker-desktop|Docker Desktop' ]; then
  echo 'The active Docker daemon is not the expected local Docker Desktop' >&2
  exit 1
fi

docker compose -f compose.ci-runner.yml config --quiet
gh auth status >/dev/null

check_runner() {
  service=$1
  name=$2
  registered=$(gh api repos/ruduo-net/terrahorse-web/actions/runners --jq ".runners[] | select(.name == \"$name\") | .busy")

  if [ "$registered" = true ]; then
    echo "$name is accepting a job; wait for it to finish before changing the runner" >&2
    exit 1
  fi

  if docker compose -f compose.ci-runner.yml run --rm --no-deps -e RUNNER_PREFLIGHT_ONLY=1 "$service"; then
    return
  else
    status=$?
    if [ "$status" != 10 ]; then
      echo "$service failed its persisted-registration preflight" >&2
      exit "$status"
    fi
  fi

  if [ -n "$registered" ]; then
    echo "$name is already registered but its local state is missing; resolve the collision explicitly" >&2
    exit 1
  fi

  registration_token=$(gh api -X POST repos/ruduo-net/terrahorse-web/actions/runners/registration-token --jq .token)
  RUNNER_REGISTRATION_TOKEN="$registration_token" docker compose -f compose.ci-runner.yml run --rm --no-deps \
    -e RUNNER_SETUP_ONLY=1 -e RUNNER_REGISTRATION_TOKEN "$service"
  unset registration_token
}

docker compose -f compose.ci-runner.yml build application-runner
docker compose -f compose.ci-runner.yml up -d --no-build --no-recreate --no-deps runtime-docker
check_runner application-runner terrahorse-m4-app
check_runner runtime-runner terrahorse-m4-runtime
docker compose -f compose.ci-runner.yml up -d --no-build --no-recreate
gh api repos/ruduo-net/terrahorse-web/actions/runners \
  --jq '.runners[] | select(.name == "terrahorse-m4-app" or .name == "terrahorse-m4-runtime") | {name,status,busy,labels:[.labels[].name]}'
