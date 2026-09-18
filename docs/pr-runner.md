# Local pull-request runner

The `terrahorse-m4-app` and `terrahorse-m4-runtime` GitHub Actions runners execute
the web repository's `Application` and `Runtime image` checks for pull requests
opened from branches in that repository. Both runners are non-root Linux ARM64
containers on the developer Mac and can use its 16 Docker Desktop CPUs. Fork
pull requests, manual validations, and deployment jobs stay on GitHub-hosted
runners. Normal same-repository PR validation consumes no hosted runner minutes.

Neither runner has a host directory, Docker socket, or AWS credential mount.
The Runtime image check uses a separate rootless Docker-in-Docker daemon on a
private Compose network. Docker requires that daemon's container to be
privileged, but its API is unavailable to the Application runner and neither
the daemon nor its build containers mount the Mac's Docker socket or home
directory. Each runner's registration and job workspace live in a separate
named Docker volume. Same-repository PR code runs inside these containers, so
limit branch write access to trusted collaborators and keep deploy secrets and
privileged jobs off both custom labels. The runners are available only while
Docker Desktop and the Mac are running; GitHub queues matching checks while
they are offline. The Application volume retains the Node toolchain, npm
downloads, and matching Playwright browsers between PRs.

## First start

Set Docker Desktop to 16 CPUs and at least 32 GiB of memory. From this
repository's root, with Docker Desktop running and `gh` authenticated to
administer runners in `ruduo-net/terrahorse-web`:

Check the repository's Settings → Actions → Runners first. If either
`terrahorse-m4-*` name is already registered on another machine, stop and
resolve that collision explicitly. Registration does not replace an existing
runner.

```sh
app_registration_token="$(gh api -X POST repos/ruduo-net/terrahorse-web/actions/runners/registration-token --jq .token)"
runtime_registration_token="$(gh api -X POST repos/ruduo-net/terrahorse-web/actions/runners/registration-token --jq .token)"
RUNNER_REGISTRATION_TOKEN="$app_registration_token" RUNNER_RUNTIME_REGISTRATION_TOKEN="$runtime_registration_token" docker compose -f compose.ci-runner.yml up -d --build
unset app_registration_token runtime_registration_token
docker compose -f compose.ci-runner.yml logs --tail=25 application-runner runtime-runner
```

Wait until both logs say `Listening for Jobs`, then remove the one-time tokens
from the container configurations. Registration remains in the named volumes:

```sh
docker compose -f compose.ci-runner.yml up -d --force-recreate --no-build
gh api repos/ruduo-net/terrahorse-web/actions/runners --jq '.runners[] | select(.name == "terrahorse-m4-app" or .name == "terrahorse-m4-runtime") | {name,status,busy,labels:[.labels[].name]}'
```

Both runners should report `online` with their respective `terrahorse-pr-app`
and `terrahorse-pr-runtime` labels. Later starts do not need registration tokens:

```sh
docker compose -f compose.ci-runner.yml up -d --no-build
```

To pause PR jobs, run `docker compose -f compose.ci-runner.yml stop`. To remove
the setup entirely, first remove both `terrahorse-m4-*` entries under the web
repository's Settings → Actions → Runners, then run
`docker compose -f compose.ci-runner.yml down -v`. The latter deletes only this
Compose project's runner volume and registration state.
