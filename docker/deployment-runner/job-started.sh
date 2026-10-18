#!/bin/sh
set -eu

expected_repository='ruduo-net/terrahorse-web'
expected_ref='refs/heads/main'
expected_workflow_ref='ruduo-net/terrahorse-web/.github/workflows/ci-cd-aws.yaml@refs/heads/main'

if [ "${GITHUB_REPOSITORY:-}" != "$expected_repository" ] \
  || [ "${GITHUB_REF:-}" != "$expected_ref" ] \
  || [ "${GITHUB_WORKFLOW_REF:-}" != "$expected_workflow_ref" ]; then
  echo 'The trusted deployment runner accepts only the protected main workflow' >&2
  exit 1
fi

case "${GITHUB_EVENT_NAME:-}" in
  push|workflow_dispatch) ;;
  *)
    echo 'The trusted deployment runner rejects this event type' >&2
    exit 1
    ;;
esac
