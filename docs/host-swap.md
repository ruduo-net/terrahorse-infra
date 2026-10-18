# Host swap

The operator explicitly extended the initial dev-only scope to production on
2026-10-18. The shared swap setting is intentional; this does not authorize
production activation or a Terraform apply.

Both dev and production cloud-init create a 1 GiB swap file at `/swapfile` before application
bootstrap. Cloud-init manages its root-only permissions, activation and fstab entry.
The file uses the root EBS disk, leaving the data volume for application state.
The native configuration is documented in
[cloud-init's mounts module](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#mounts).

The existing dev instance was updated through SSM on 2026-10-18 without a reboot,
service restart, instance replacement or instance-size change. The same size/path
is recorded here for future dev and production hosts. The launch-template change
still follows normal Terraform review/application and does not replace the current
dev host. Adding this setting does not activate production or change its capacity.
An existing production host would require a separate guarded rollout or replacement
to acquire the setting; cloud-init changes do not modify running hosts automatically.

Verify on the intended host:

```sh
swapon --show --bytes
free -m
stat -c '%U %a %s' /swapfile
grep '^/swapfile ' /etc/fstab
```

Expect a root-owned file with mode `600` and length `1073741824` bytes. The usable
swap size is slightly smaller because of the swap header. The fstab entry makes
it persistent; a reboot is not needed to activate it.

## Explicit rollback

Confirm the intended host and ensure enough available RAM to absorb any used swap:

```sh
sudo swapoff /swapfile
sudo sed -i '\|^/swapfile[[:space:]]|d' /etc/fstab
sudo systemctl daemon-reload
sudo rm /swapfile
```

Stop if `swapoff` fails; do not remove an active swap file. Remove the shared
cloud-init `swap` entry in the same reviewed rollback if replacement hosts should
also stop receiving swap.
