#!/usr/bin/env bash
set -euo pipefail

role_arn=${1:?invoice role ARN is required}
region=${2:?AWS region is required}
directory=/run/terrahorse-invoice

umask 077
pending=$(mktemp "$directory/.credentials.XXXXXX")
trap 'rm -f -- "$pending"' EXIT

aws sts assume-role --role-arn "$role_arn" --role-session-name terrahorse-dev-invoice \
  --region "$region" --duration-seconds 3600 --no-cli-pager --query Credentials --output json |
  jq -e '
    select([.AccessKeyId, .SecretAccessKey, .SessionToken, .Expiration]
      | all(type == "string" and length > 0))
    | select((.Expiration | sub("\\+00:00$"; "Z") | sub("\\.[0-9]+Z$"; "Z")
      | fromdateiso8601) > (now + 900))
    | {Version: 1, AccessKeyId, SecretAccessKey, SessionToken, Expiration}
  ' > "$pending"
chmod 0640 "$pending"
destination="$directory/credentials.json"
test ! -d "$destination"
mv -f -- "$pending" "$destination"
