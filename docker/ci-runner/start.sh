#!/bin/sh
set -eu

runner_name=${RUNNER_NAME:?A runner name is required}
runner_labels=${RUNNER_LABELS:?Runner labels are required}

if [ -f /runner/.runner ]; then
  node -e '
    const fs = require("node:fs");
    const saved = JSON.parse(fs.readFileSync("/runner/.runner", "utf8").replace(/^\uFEFF/, ""));
    const expected = {
      agentName: process.env.RUNNER_NAME,
      gitHubUrl: "https://github.com/ruduo-net/terrahorse-web",
      workFolder: "_work",
    };
    for (const [field, value] of Object.entries(expected)) {
      if (saved[field] !== value) {
        console.error(`Unexpected persisted runner ${field}; refusing to connect`);
        process.exit(1);
      }
    }
    if (process.env.RUNNER_EXPECTED_ID && String(saved.agentId) !== process.env.RUNNER_EXPECTED_ID) {
      console.error("Persisted runner ID does not match GitHub; refusing to connect");
      process.exit(1);
    }
  '
elif [ "${RUNNER_PREFLIGHT_ONLY:-}" = 1 ]; then
  echo 'Runner registration is required'
  exit 10
fi

if [ "${RUNNER_PREFLIGHT_ONLY:-}" = 1 ]; then
  exit 0
fi

if [ ! -f /runner/.runner ]; then
  cp -a /opt/actions-runner/. /runner/
  registration_token=${RUNNER_REGISTRATION_TOKEN:?A one-time runner registration token is required}
  unset RUNNER_REGISTRATION_TOKEN
  /runner/config.sh \
    --unattended \
    --url https://github.com/ruduo-net/terrahorse-web \
    --token "$registration_token" \
    --name "$runner_name" \
    --labels "$runner_labels" \
    --no-default-labels \
    --work _work
  unset registration_token
fi

unset RUNNER_REGISTRATION_TOKEN

if [ "${RUNNER_SETUP_ONLY:-}" = 1 ]; then
  exit 0
fi

if [ -n "${DOCKER_HOST:-}" ]; then
  attempts=0
  until timeout 5 docker info >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 30 ]; then
      echo 'Runtime Docker daemon is unavailable; refusing to accept jobs' >&2
      exit 1
    fi
    sleep 2
  done
fi

exec /runner/run.sh
