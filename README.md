# rclone-script

Run `setup-nzbget-storage.sh` as **root on the Proxmox host**, after creating
and starting your Linux LXC container. Despite the original filename, it is not
specific to NZBGet and does not require systemd inside the container:

```bash
bash setup-nzbget-storage.sh
```

The script prompts for the container ID, the container user whose read/write
access should be checked (default `root`), optional rclone installation, and
confirmation before making changes. Choose your application's actual user
(for example `nzbget`, `sonarr`, or `radarr`) to check its permissions rather
than root's. Run it once per container; the host mounts are shared and reused.
It installs `nfs-common` on the host, then shuts down and restarts the selected
container to apply read/write bind mounts:

| NFS export | Host and container path |
| --- | --- |
| `192.168.1.4:/volume1/media` | `/mnt/media` |
| `192.168.1.4:/volume1/downloads` | `/mnt/downloads` |

Optional rclone installation supports `apt-get` (Debian/Ubuntu), `apk`
(Alpine), `dnf`/`yum`, `zypper`, and `pacman`, using the distribution's enabled
repositories. Arch containers receive a full system upgrade (`pacman -Syu`)
to avoid unsupported partial upgrades. If the package is unavailable, installation
fails explicitly; enable the appropriate repository or rerun and decline rclone.
Other Linux distributions can still receive the mounts if they provide a POSIX
shell and standard utilities (`find`, `id`, `test`, `mktemp`, `rmdir`, `cat`);
`runuser` or `su` is also required to check access as the chosen user. Install
rclone manually on those distributions. VMs and Docker containers are not supported.

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
inside the container. NAS file permissions must allow the selected container user's
**host-mapped UID/GID**; with default unprivileged mappings, container UID 1000
maps to host UID 101000. The script checks actual read/write access and reports
the mappings if access fails. Configure NAS permissions rather than recursively
changing ownership of existing media.

Application settings are left unchanged. For NZBGet, set its `MainDir` to
`/mnt/downloads` if desired and use `/mnt/media` for your media library.
rclone needs no remote
configuration for these ordinary filesystem paths; run `rclone config` inside
the container if you also want cloud remotes. This script does not enable
`rclone mount`/FUSE or expose a new NFS server.

The original script filename, backup names, lock file, and systemd drop-in name
are retained so existing installations can rerun it without duplicate startup
guards. Updating the script does not resolve NAS export access denials: the NAS
must still authorize the Proxmox host's IP.