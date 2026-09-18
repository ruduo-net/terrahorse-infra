# Local pull-request runner

The `terrahorse-m4-app` GitHub Actions runner executes the web repository's
`Application` check for pull requests opened from branches in that repository.
It runs as a non-root Linux ARM64 container on the developer Mac and can use its
16 Docker Desktop CPUs. The `Runtime image` check, fork pull requests, manual
validations, and deployment jobs stay on GitHub-hosted runners. Only the
Application check's hosted minutes are saved.

The runner has no host directory, Docker socket, or AWS credential mount. Its
registration and job workspace live in the `terrahorse-pr-runner_runner-state`
Docker volume. Code submitted in a same-repository pull request runs inside this
container, so limit branch write access to trusted collaborators. Keep deploy
secrets and privileged jobs off the `terrahorse-pr-app` label. The runner is
available only while Docker Desktop and the Mac are running; GitHub queues
matching PR checks while it is offline.

## First start

From this repository's root, with Docker Desktop running and `gh` authenticated
to administer runners in `ruduo-net/terrahorse-web`:

```sh
runner_registration_token="$(gh api -X POST repos/ruduo-net/terrahorse-web/actions/runners/registration-token --jq .token)"
RUNNER_REGISTRATION_TOKEN="$runner_registration_token" docker compose -f compose.ci-runner.yml up -d --build
unset runner_registration_token
docker compose -f compose.ci-runner.yml logs --tail=25 application-runner
```

Wait until the log says `Listening for Jobs`, then remove the one-time token
from the container configuration. Registration remains in the named volume:

```sh
docker compose -f compose.ci-runner.yml up -d --force-recreate --no-build
gh api repos/ruduo-net/terrahorse-web/actions/runners --jq '.runners[] | select(.name == "terrahorse-m4-app") | {status,busy,labels:[.labels[].name]}'
```

The runner should report `online` with the `terrahorse-pr-app` label. Later
starts do not need another registration token:

```sh
docker compose -f compose.ci-runner.yml up -d --no-build
```

To pause PR jobs, run `docker compose -f compose.ci-runner.yml stop`. To remove
the setup entirely, first remove `terrahorse-m4-app` under the web repository's
Settings → Actions → Runners, then run
`docker compose -f compose.ci-runner.yml down -v`. The latter deletes only this
Compose project's runner volume and registration state.
