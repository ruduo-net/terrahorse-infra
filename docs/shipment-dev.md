# Dev Saleor shipment preparation

Operators use `https://dashboard-dev.terrahorse.lt`; the embedded widget uses the
already-existing `https://dev.terrahorse.lt` origin with narrow path routing. No
additional shipment domain is required, and the widget cannot access Dashboard
origin storage or its staff session. Its protected Saleor order widget uses the shipment-operator role of the active immutable web image.
It supports saved locker/courier destination display and read-only parcel checks.
Booking, labels, recovery mutations and fulfillment remain disabled. Shipment
state belongs to Saleor; the existing private Valkey stores app registration only.

## Deployment ownership

The web release must advertise `lt.terrahorse.release.shipment-operator-contract=1`
and contain both shipment Compose contracts. Infrastructure owns the dev tunnel
path route, runtime inputs and the independent shipment systemd service/timer. Production
cloud-init contains neither service nor timer and has no shipment path route.

The reconciler admits only account `462432303731`, the instance recorded in the
successful dev release status, owned ECR digests and the exact dev public/private
Saleor endpoints. It shares the parent deployment lock and requires the existing
private network's API/Valkey members. The parent network guard permits only the
additional shipment Compose service. No new database, credential scope on the
storefront app or host-instance refresh is required to enable the current dev host.

Nuxt's runtime `NUXT_APP_CDN_URL` points this service's public assets to
`https://dev.terrahorse.lt/shipment-operator/assets`. A small static-only proxy
strips that prefix and reaches the shipment runtime's own `/_nuxt/` files;
customer storefront assets retain their existing route. The proxy reuses the
immutable local image of the owning main media service, joins only its project's
ingress bridge and internal assets network (never Saleor/Valkey's network), and
strips cookies/authorization. The ingress bridge permits loopback publishing;
an exclusively internal Docker network does not publish a host port. It accepts only static
GET/HEAD requests and uses Docker DNS to follow runtime replacements. Both current
and rolled-back operators serve matching assets regardless of the storefront
version, without a new hostname or CORS permission. Infrastructure supplies the
third `compose.shipment-assets.yml` overlay and proxy configuration, including for
legacy rollback candidates. A module referenced by the real rendered page is
probed through the proxy before promotion.

Dev ASG uses `$Latest` for future instances without automatic instance refresh;
bootstrap changes do not replace the active host during a full Terraform apply.
An intentional dev host refresh must be requested separately. Production retains
its existing rolling-refresh policy.

The shipment container receives only the owning commerce token, sandbox Montonio
credentials, configured delivery IDs and Model type reference. Its CA overlay mounts
the existing Saleor certificate read-only; TLS and hostname checks stay enabled.
Environment files are owner-only and are never printed. Failed startup restores the
previous shipment runtime; first-start failure removes only the shipment project.
Termination, including the service start timeout, runs the same rollback and
first-start teardown; the stop budget allows up to 60 seconds for rollback health.
Cleanup ignores subsequent TERM/INT, so a timeout during an existing rollback
cannot abandon the EXIT trap. Failed restoration stops the exact shipment project
and retains private diagnostic inputs. A non-symlink or broken active path is refused
before Compose can replace anything.
All startup and rollback operations remove orphans only within the shipment project.
Unchanged successful inputs restore the existing service without accumulating
candidate directories. Failed rollback retains private candidate inputs for diagnosis.

## Initial dev setup

1. Apply only the dev shipment page/API/asset routes and non-secret runtime input changes after
   inspecting the saved plan. Do not apply an ASG instance refresh for this setup.
2. Administratively provision the Saleor Model type with slug
   `terrahorse-shipment-work-v1` and name `TerraHorse shipment work`. Refuse a
   conflicting existing definition; create no order or shipment records.
3. Write its observed `PageType` GraphQL ID to the non-secret Parameter Store key
   `/terrahorse/dev/ec2/SALEOR_SHIPMENT_PAGE_TYPE_ID`. The reconciler reads this
   reference; it never creates or changes Saleor types or records.
4. Install the committed dev service, timer and reconciler on the existing dev host
   using SSM. Update its parent's network guard to the committed dev template;
   restart only the parent reconciler control-plane service, not the storefront.
   Future dev cloud-init carries these files and enables the timer automatically.
5. Start `terrahorse-shipment-operator.service` and enable its timer. Verify both
   loopback `/health` reports the expected image version and
   `service: shipment-operator`. Verify the public manifest and its app URL use the
   existing dev storefront origin, distinct from Dashboard; `/health` on that public origin belongs to storefront.
6. From hosted dev Dashboard, install
   `https://dev.terrahorse.lt/api/shipment-operator/manifest`.
   The app requests `MANAGE_ORDERS` and `MANAGE_PAGES`; the widget requires only
   staff `MANAGE_ORDERS`. The registered app token owns the private Model reads.
7. Open an existing dev order and verify **Shipment preparation**, its explicit
   saved destination, packed parcel inputs and visibly disabled booking button.
   Ambiguous/missing destination or payment evidence must remain blocked. Do not
   create a provider shipment to verify this read-only phase.

The current host setup must be verified through SSM and the Dashboard; a successful
Terraform apply or merge alone does not prove the app is installed or visible.

## Recovery

Stop/disable only `terrahorse-shipment-operator.timer`, then stop the exact
`terrahorse-shipment-operator` Compose project using the active environment and both
three Compose files under `/opt/terrahorse/shipment/active`. Preserve Saleor records and
Valkey registration. Restore a previous private shipment candidate and restart the
service to recover. Restore the parent network guard only after detaching the
shipment service. Any route rollback must remove only the dev shipment path entry;
leave the existing storefront, API, Dashboard and editor routes intact.

## Credential-free verification

`python3 scripts/reconcile-shipment-dev.test.py` executes the real Bash script with
isolated AWS/Docker/HTTP fixtures. It covers wrong account/host, unowned releases,
network admission, missing Model references, incompatible bundles/origins, successful
and unchanged deployments, first-start teardown, termination rollback and asset
isolation on legacy rollback. CI runs
these checks alongside Terraform formatting and validation.

`python3 scripts/shipment-assets-contract.py` runs the real non-root Nginx proxy
against temporary synthetic upstreams. It proves GET/HEAD handling, cookie/token
stripping, blocked business routes and POST, and DNS changes during replacement
and rollback. It removes only its uniquely named containers/network and needs no
Saleor or Montonio credentials.
