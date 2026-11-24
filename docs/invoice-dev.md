# Dev invoice storage

Terraform provisions a private, encrypted, versioned bucket for TerraHorse
test invoices. The dev runtime configuration provides `INVOICE_S3_BUCKET`,
`INVOICE_S3_REGION`, `INVOICE_S3_PREFIX`, and `INVOICE_SERIES`. Each
environment profile sets the storage prefix and printed series.

Only the dev EC2 instance role can assume the invoice role. The invoice role
can read objects under the configured prefix and create them using
`If-None-Match: *`. It can update only `invoice-series/head.json` under
that prefix, using the current ETag in `If-Match`. Invoice PDFs and order
lookups remain create-only. The role has no bucket listing or deletion access.
A read for a missing object can return 403. The storefront re-reads the head
after a conflict or an ambiguous update.

The dev-only Systems Manager association installs a systemd timer on the
existing host. It renews a one-hour role session every 15 minutes and writes
the session to `/run/terrahorse-invoice/credentials.json`. The directory has
mode 0750 and the credential file has mode 0640, both with group 1000 for
the storefront container. A failed refresh retains the previous session.
The host's instance metadata setting stays at hop limit 1.

The storefront integration should mount the **directory** read-only in dev.
The SDK must reopen the file for refresh and reject expired sessions. The
timer replaces the file atomically and a file-only bind mount would keep
the previous version. Keep the directory and credentials out of other
containers and keep credential contents out of deployment output.

The infrastructure GitHub workflow validates Terraform. After applying the
configuration through the approved infrastructure workflow, verify that the
dev SSM association completed successfully before enabling the storefront
integration. Apply the head permission before deploying the sequential invoice
code. Check the timer status and credential file age without
printing its contents. The existing storefront deployment remains the
application delivery path.

## Production rollout

| Environment | Bucket name pattern | Object prefix | Series |
| --- | --- | --- | --- |
| Dev | `terrahorse-invoice-dev-<account>-<region>` | `test-invoices/v1/` | `THDEV` |
| Production | `terrahorse-invoice-prod-<account>-<region>` | `invoices/v1/` | `TH` (planned) |

Terraform renders each environment's policy from its profile. The production
policy is prepared for a dedicated bucket and role, with a conditional update
grant on `invoices/v1/invoice-series/head.json` only. Before activation,
confirm the production series and starting number, provision the production
bucket and role, and wire credentials and runtime config to the production
host. Verify that the production role can access only its own bucket and series
head and that both test and production PDFs remain create-only.
