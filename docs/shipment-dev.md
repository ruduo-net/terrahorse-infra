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

Shared Nuxt assets remain served by the storefront from the same immutable image;
shipment path routing does not intercept customer storefront asset requests.

The shipment container receives only the owning commerce token, sandbox Montonio
credentials, configured delivery IDs and Model type reference. Its CA overlay mounts
the existing Saleor certificate read-only; TLS and hostname checks stay enabled.
Environment files are owner-only and are never printed. Failed startup restores the
previous shipment runtime; first-start failure removes only the shipment project.
Unchanged successful inputs restore the existing service without accumulating
candidate directories. Failed rollback retains private candidate inputs for diagnosis.

## Initial dev setup

1. Apply only the dev shipment path route and non-secret runtime input changes after
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
Compose files under `/opt/terrahorse/shipment/active`. Preserve Saleor records and
Valkey registration. Restore a previous private shipment candidate and restart the
service to recover. Restore the parent network guard only after detaching the
shipment service. Any route rollback must remove only the dev shipment path entry;
leave the existing storefront, API, Dashboard and editor routes intact.

## Credential-free verification

`python3 scripts/reconcile-shipment-dev.test.py` executes the real Bash script with
isolated AWS/Docker/HTTP fixtures. It covers wrong account/host, unowned releases,
network admission, missing Model references, incompatible bundles/origins, successful
and unchanged deployments, first-start teardown and failed-upgrade rollback. CI runs
these checks alongside Terraform formatting and validation.
