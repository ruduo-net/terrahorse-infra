# Local GitHub Actions runners

The `terrahorse-m4-app` and `terrahorse-m4-runtime` GitHub Actions runners execute
the web repository's `Application` and `Runtime image` checks for pull requests
opened from branches in that repository. Both runners are non-root Linux ARM64
containers on the developer Mac and can use its 16 Docker Desktop CPUs. The
separate `terrahorse-m4-deploy` runner executes deployment jobs from protected
`main` pushes and guarded manual production promotions. Fork pull requests and
manual validation jobs stay on GitHub-hosted runners. Normal same-repository PR
validation and deployment orchestration consume no hosted runner minutes.

None of the runners has a host directory, Docker socket, or AWS credential mount.
The Runtime image check uses a separate rootless Docker-in-Docker daemon on a
private Compose network. Docker requires that daemon's container to be
privileged, but its API is unavailable to the Application runner and neither
the daemon nor its build containers mount the Mac's Docker socket or home
directory. The daemon has its own process limit. Each runner's registration and
job workspace live in a separate named Docker volume. Same-repository PR code
runs inside these containers, so limit branch write access to trusted
collaborators. Keep deploy secrets and privileged jobs off both PR labels.
The deployment runner has no Docker socket or host mount. It has AWS CLI and
`jq`, receives short-lived AWS credentials through GitHub OIDC, and is selected
only by the `terrahorse-deploy` label. Never route pull-request jobs to this
label: deployment jobs can read protected GitHub Environment secrets and assume
the narrowly scoped deployment roles.
The runners are available only while
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
ID and labels. It builds the image before requesting any one-hour registration
tokens. Registration runs in short-lived containers
that exit before any runner starts accepting jobs; only the named volumes
retain the runner identities, and the long-lived containers have no token in
their environment. Existing runner containers are not recreated while the
script runs. Replacing an existing runner image is a separate maintenance
operation after its jobs finish. Wait until all three runners report `online`
if they are initially shown as `offline`.

All three runners should report `online` with their respective
`terrahorse-pr-app`, `terrahorse-pr-runtime`, and `terrahorse-deploy` labels.
Later starts do not need registration tokens:

```sh
./scripts/start-pr-runner.sh
```

To pause PR jobs, run
`docker compose --project-name terrahorse-pr-runner -f compose.ci-runner.yml stop`.
To remove the setup entirely, first remove all three `terrahorse-m4-*` entries under
the web repository's Settings → Actions → Runners, then run
`docker compose --project-name terrahorse-pr-runner -f compose.ci-runner.yml down -v`.
The latter deletes only this Compose project's runner volumes and registration
state.
