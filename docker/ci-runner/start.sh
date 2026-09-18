#!/bin/sh
set -eu

if [ ! -f /runner/.runner ]; then
  cp -a /opt/actions-runner/. /runner/
  registration_token=${RUNNER_REGISTRATION_TOKEN:?A one-time runner registration token is required}
  runner_name=${RUNNER_NAME:?A runner name is required}
  runner_labels=${RUNNER_LABELS:?Runner labels are required}
  unset RUNNER_REGISTRATION_TOKEN
  /runner/config.sh \
    --unattended \
    --url https://github.com/ruduo-net/terrahorse-web \
    --token "$registration_token" \
    --name "$runner_name" \
    --labels "$runner_labels" \
    --work _work \
    --replace
  unset registration_token runner_name runner_labels
fi

unset RUNNER_REGISTRATION_TOKEN
exec /runner/run.sh
