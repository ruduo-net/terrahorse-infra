#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

compose() {
  docker compose --project-name terrahorse-pr-runner -f compose.ci-runner.yml "$@"
}

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ] \
  || [ -n "${DOCKER_HOST:-}" ] || [ -n "${DOCKER_CONTEXT:-}" ] \
  || { [ -n "${DOCKER_DEFAULT_PLATFORM:-}" ] && [ "$DOCKER_DEFAULT_PLATFORM" != linux/arm64 ]; }; then
  echo 'Use this script on an ARM64 Mac with local Docker Desktop and no conflicting Docker overrides' >&2
  exit 1
fi

if [ "$(docker context show)" != desktop-linux ] \
  || [ "$(docker context inspect desktop-linux --format '{{ .Endpoints.docker.Host }}')" != "unix://$HOME/.docker/run/docker.sock" ] \
  || [ "$(docker info --format '{{.Name}}|{{.OperatingSystem}}|{{.Architecture}}')" != 'docker-desktop|Docker Desktop|aarch64' ]; then
  echo 'The active Docker daemon is not the expected local ARM64 Docker Desktop' >&2
  exit 1
fi

compose config --quiet
gh auth status >/dev/null

preflight_runner() {
  service=$1
  name=$2
  expected_label=$3
  registered=$(gh api --paginate repos/ruduo-net/terrahorse-web/actions/runners --jq ".runners[] | select(.name == \"$name\") | [.id, .busy, ([.labels[].name] | sort | join(\",\"))] | @tsv")
  registered_id=$(printf '%s\n' "$registered" | cut -f1)
  registered_busy=$(printf '%s\n' "$registered" | cut -f2)
  registered_labels=$(printf '%s\n' "$registered" | cut -f3)

  if [ "$registered_busy" = true ]; then
    echo "$name is accepting a job; wait for it to finish before changing the runner" >&2
    exit 1
  fi

  if [ -n "$registered_id" ] && [ "$registered_labels" != "$expected_label" ]; then
    echo "$name has unexpected GitHub labels; resolve them before starting the runner" >&2
    exit 1
  fi

  if compose run --rm --no-deps -e RUNNER_PREFLIGHT_ONLY=1 -e RUNNER_EXPECTED_ID="$registered_id" "$service"; then
    if [ -z "$registered_id" ]; then
      echo "$name has local state but no GitHub registration; resolve the mismatch explicitly" >&2
      exit 1
    fi
    return 0
  else
    status=$?
    if [ "$status" != 10 ]; then
      echo "$service failed its persisted-registration preflight" >&2
      exit "$status"
    fi
  fi

  if [ -n "$registered_id" ]; then
    echo "$name is already registered but its local state is missing; resolve the collision explicitly" >&2
    exit 1
  fi

  return 10
}

register_runner() {
  service=$1
  registration_token=$(gh api -X POST repos/ruduo-net/terrahorse-web/actions/runners/registration-token --jq .token)
  RUNNER_REGISTRATION_TOKEN="$registration_token" compose run --rm --no-deps \
    -e RUNNER_SETUP_ONLY=1 -e RUNNER_REGISTRATION_TOKEN "$service"
  unset registration_token
}

compose build application-runner
if preflight_runner application-runner terrahorse-m4-app terrahorse-pr-app; then
  app_registration_needed=0
else
  app_registration_needed=$?
  [ "$app_registration_needed" = 10 ] || exit "$app_registration_needed"
fi
if preflight_runner runtime-runner terrahorse-m4-runtime terrahorse-pr-runtime; then
  runtime_registration_needed=0
else
  runtime_registration_needed=$?
  [ "$runtime_registration_needed" = 10 ] || exit "$runtime_registration_needed"
fi

if [ "$app_registration_needed" = 10 ]; then
  register_runner application-runner
fi
if [ "$runtime_registration_needed" = 10 ]; then
  register_runner runtime-runner
fi

compose up -d --no-build --no-recreate --no-deps runtime-docker
compose up -d --no-build --no-recreate
gh api --paginate repos/ruduo-net/terrahorse-web/actions/runners \
  --jq '.runners[] | select(.name == "terrahorse-m4-app" or .name == "terrahorse-m4-runtime") | {name,status,busy,labels:[.labels[].name]}'
