# Local GitHub Actions runners

When `ACTIONS_RUNNER_MODE=self-hosted`, the `terrahorse-m4-app` and
`terrahorse-m4-runtime` GitHub Actions runners execute
the web repository's `Application` and `Runtime image` checks for pull requests
opened from branches in that repository. Both runners are non-root Linux ARM64
containers on the developer Mac and can use its 16 Docker Desktop CPUs. The
separate `terrahorse-m4-deploy` runner executes deployment jobs from protected
`main` pushes and guarded manual production promotions. Fork pull requests and
manual validation jobs stay on GitHub-hosted runners. Normal same-repository PR
validation and deployment orchestration consume no hosted runner minutes in that
mode. GitHub-hosted runners are the default.

## Switch between GitHub-hosted and MacBook runners

One Actions configuration variable, `ACTIONS_RUNNER_MODE`, controls the web
workflow's existing self-hosted jobs:

| Value                 | Runner selection                                                                                                                                                                                             |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `github-hosted`       | GitHub-hosted Linux runners for classification, PR validation, and deployments. Use while credits remain.                                                                                                    |
| `self-hosted`         | Same-repository PR classification and `Application` use `terrahorse-pr-app`; `Runtime image` uses `terrahorse-pr-runtime`. Protected `main` push classification and deployment jobs use `terrahorse-deploy`. |
| Unset or unrecognized | Same as `github-hosted`; never queues jobs on the MacBook by accident.                                                                                                                                       |

In `ruduo-net/terrahorse-web`, open Settings → Secrets and variables → Actions →
Variables, then create or edit the **repository** variable. CLI equivalents:

```sh
gh variable set ACTIONS_RUNNER_MODE --repo ruduo-net/terrahorse-web --body github-hosted
gh variable set ACTIONS_RUNNER_MODE --repo ruduo-net/terrahorse-web --body self-hosted
```

Run only the command for the desired mode. Before selecting `self-hosted`, start
the runners below and confirm all three are online. The MacBook runners are
Linux ARM64 containers, not native macOS runners; hosted validation and deployment
use `ubuntu-latest` (Linux x64), retaining the existing hosted validation path and
architecture-separated npm cache keys. Release builds remain on
`ubuntu-26.04-arm` and publish `linux/arm64` images.

Fork PRs and manual validation always stay hosted. Cache seeding and release
builds also stay hosted in both modes: the PR Docker daemon is not a trusted
release builder, and the deployment runner has no Docker daemon. Deployment
jobs retain their `main`, GitHub Environment, OIDC, and production-promotion
guards. The infrastructure repository stays hosted because these runners are
registered only to the web repository.

For future repositories with compatible registered runners and the same workflow
selection, create this variable in organization Settings → Secrets and variables
→ Actions → Variables and grant it access to the selected repositories. Remove
same-named repository variables if the organization value should control them;
repository variables take precedence. Organization variables require a plan
supporting them for private repositories and organization administration access.
Do not use an Environment variable: runner selection happens before it is available.

The switch is manual; it does not inspect remaining credits or retry a hosted
job on the MacBook when billing blocks it. Change the value before starting a
new workflow run. Running jobs stay on their assigned runners; an already queued
run may need cancellation and a fresh run after switching. Unset/delete the
variable or choose `github-hosted` to roll back to hosted routing.

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
only by the `terrahorse-deploy` label. A root-owned job-start hook admits only
`push` and `workflow_dispatch` jobs from the protected `main` revision of the
web deployment workflow. It rejects pull-request events before their first
step, so changing a PR workflow to request the label cannot modify persistent
runner state or reach deployment credentials. Deployment jobs can read protected
GitHub Environment secrets and assume the narrowly scoped deployment roles.
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
operation after its jobs finish. A runner already executing a job is checked
in place and left running, so it does not prevent stopped runners from starting.
Wait until all three runners report `online`
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
