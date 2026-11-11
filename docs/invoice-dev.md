# Dev invoice storage

Terraform provisions a private, encrypted, versioned bucket for TerraHorse
test invoices. The dev runtime configuration provides `INVOICE_S3_BUCKET`,
`INVOICE_S3_REGION` and `INVOICE_S3_PREFIX` from the infrastructure stack.

Only the dev EC2 instance role can assume the invoice role. The invoice role
can read objects under the configured prefix and create them using
`If-None-Match: *`. It has no bucket listing, deletion or overwrite access.
A read for a missing object can return 403 with these permissions. The
storefront must preserve the conditional write on first issuance and check
the existing object on a 412 response.

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
integration. Check the timer status and credential file age without
printing its contents. The existing storefront deployment remains the
application delivery path.
