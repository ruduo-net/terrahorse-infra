# TerraHorse E2E Infrastructure

This repository owns the disposable `terrahorse-web-e2e` runtime behind
`e2e.terrahorse.lt`. One Compose project contains PostgreSQL, Valkey, the Saleor
`3.23` patch line, a Celery worker, exactly one Celery Beat scheduler, the exact-SHA
storefront, and the existing Cloudflared connector. Saleor has no published
port or hostname; only the storefront is reachable through the existing
tunnel.

The setup step migrates an empty database, creates the minimal
`terrahorse-e2e` channel/catalogue/warehouse/LT-shipping fixture, and creates
one active runtime app with exactly `HANDLE_PAYMENTS`, `HANDLE_CHECKOUTS`,
`MANAGE_CHECKOUTS`, and `MANAGE_ORDERS`. Its generated token and resolved
Saleor IDs exist only in ignored owner-only `.e2e-run/` state. No Dashboard
token or external Saleor instance is used.

## Protected external inputs

Keep both env files and the dedicated tunnel files outside Git as owner-only
`0600` regular files. They contain only external configuration:

- runtime environment: optional Montonio endpoint overrides;
- secret environment: `MONTONIO_ACCESS_KEY`, `MONTONIO_SECRET_KEY`, and
  `COMMERCE_EVENT_HMAC_KEY`;
- the existing `terrahorse-e2e` tunnel config and credential JSON.

Export their paths with the storefront source and friendly ref:

```sh
export E2E_STOREFRONT_SOURCE_REPO=/absolute/path/to/terrahorse-web
export E2E_STOREFRONT_REF=origin/main
export E2E_RUNTIME_ENV_FILE=/protected/path/runtime.env
export E2E_SECRET_ENV_FILE=/protected/path/secrets.env
export E2E_TUNNEL_CONFIG_FILE=/protected/path/terrahorse-e2e.yml
export E2E_TUNNEL_CREDENTIALS_FILE=/protected/path/terrahorse-e2e.json
```

The tunnel config is unchanged and contains no Saleor route:

```yaml
tunnel: <dedicated-tunnel-uuid>
credentials-file: /etc/cloudflared/credentials.json
loglevel: info
ingress:
  - hostname: e2e.terrahorse.lt
    service: http://host.docker.internal:4100
  - service: http_status:404
```

## Start, verify, and stop

Start resolves the storefront ref once, prepares the existing detached ignored
worktree, creates fresh internal Saleor secrets, and runs these bounded stages:

1. PostgreSQL and Valkey health;
2. Saleor migrations and deterministic seed;
3. private API, app, webhook, delivery, and disposable-checkout verification;
4. worker and the single Beat scheduler;
5. exact-SHA storefront and the existing Cloudflared connector;
6. public SHA, noindex, callback-path, seeded-product, and storefront-checkout
   verification.

```sh
scripts/run-e2e-storefront.sh
```

The run creates no Montonio Order and performs no browser payment. A failed
start removes only Compose project `terrahorse-web-e2e`, its volumes, and its
generated `.e2e-run/` state after confirming teardown. If teardown is
incomplete, owner state is retained for the project-scoped stop command.

Standalone public verification while the project is running uses the resolved
SHA from the owner record:

```sh
export E2E_STOREFRONT_SHA=$(sed -n '1p' .e2e-run/owner)
scripts/verify-e2e-boundary.sh
```

Normal stop removes every project container, the disposable Saleor database
volume, and generated run state:

```sh
E2E_STOP_CONFIRM=terrahorse-e2e scripts/stop-e2e-storefront.sh
```

The detached storefront worktree is intentionally reusable. Remove only that
exact worktree when it is no longer useful:

```sh
E2E_STOREFRONT_SHA=<full-sha> \
E2E_WORKTREE_CLEANUP_CONFIRM=terrahorse-e2e \
scripts/cleanup-e2e-storefront-worktree.sh
```

## Retained external resources

Stop never changes the existing `e2e.terrahorse.lt` Cloudflare DNS record,
named tunnel, connector credentials, or noindex rule. It also never changes any
external Saleor or production resource. Removal of legacy external Saleor and
Cloudflare resources remains a separately authorized, exact-identity owner
action.
