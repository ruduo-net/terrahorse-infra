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

Set Docker Desktop to 16 CPUs and at least 32 GiB of memory. Authenticate `gh`
to administer runners in `ruduo-net/terrahorse-web`. From this repository's
root, run:

```sh
./scripts/start-pr-runner.sh
```

The script refuses a remote or non-ARM64 Docker daemon, a conflicting Docker
platform override, or an existing GitHub registration without matching local
state. It builds the image before requesting any one-hour registration tokens.
Registration runs in short-lived containers
that exit before either runner starts accepting jobs; only the named volumes
retain the runner identities, and the long-lived containers have no token in
their environment. Existing runner containers are not recreated while the
script runs. Replacing an existing runner image is a separate maintenance
operation after its PR jobs finish. Wait until both runners report `online`
if they are initially shown as `offline`.

Both runners should report `online` with their respective `terrahorse-pr-app`
and `terrahorse-pr-runtime` labels. Later starts do not need registration tokens:

```sh
./scripts/start-pr-runner.sh
```

To pause PR jobs, run
`docker compose --project-name terrahorse-pr-runner -f compose.ci-runner.yml stop`.
To remove the setup entirely, first remove both `terrahorse-m4-*` entries under
the web repository's Settings → Actions → Runners, then run
`docker compose --project-name terrahorse-pr-runner -f compose.ci-runner.yml down -v`.
The latter deletes only this Compose project's runner volumes and registration
state.
