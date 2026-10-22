# rclone-script

Run `setup-nzbget-storage.sh` as **root on the Proxmox host**, after creating
and starting the Debian/Ubuntu NZBGet LXC container:

```bash
bash setup-nzbget-storage.sh
```

The script prompts for the container ID and confirmation before making changes.
It installs `nfs-common` on the host and the distribution's `rclone` package
inside the container, then shuts down and restarts the container to apply
read/write bind mounts:

| NFS export | Host and container path |
| --- | --- |
| `192.168.1.4:/volume1/media` | `/mnt/media` |
| `192.168.1.4:/volume1/downloads` | `/mnt/downloads` |

Allow the **Proxmox host's IP** read/write access to both NFS exports on the NAS
first. The script uses the system's negotiated NFS version. It refuses conflicting
mounts or nonempty local mount directories, preserves existing container mount
points, and can be rerun. It backs up `/etc/fstab` alongside that file and the
container configuration under `/root` before changing them. Failures stop the
script without undoing completed steps; if a failure leaves the container stopped,
correct the reported problem, start it, and rerun.

Persistent mounts use `/etc/fstab`. A container-specific systemd drop-in at
`/etc/systemd/system/pve-container@<ID>.service.d/nzbget-storage.conf` requires
the host mounts before container startup, preventing downloads from silently
landing on the host's local disk when NFS is unavailable. These are hard NFS
mounts: NAS outages can block I/O until the NAS returns. The container must run
on this host; bind-mounted data is not included in Proxmox container backups.

Unprivileged containers can use these bind mounts without enabling NFS or FUSE
inside the container. NAS file permissions must allow the NZBGet service user's
**host-mapped UID/GID**; with default unprivileged mappings, container UID 1000
maps to host UID 101000. The script checks actual read/write access and reports
the mappings if access fails. Configure NAS permissions rather than recursively
changing ownership of existing media.

NZBGet settings are left unchanged. Set its `MainDir` to `/mnt/downloads` if
desired and use `/mnt/media` for your media library. rclone needs no remote
configuration for these ordinary filesystem paths; run `rclone config` inside
the container if you also want cloud remotes. This script does not enable
`rclone mount`/FUSE or expose a new NFS server.