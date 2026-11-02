# Alarm management installer

This public repository contains the Linux installer, Proxmox helper and public release metadata.
Application code stays private; images are intended for private distribution.
The owner must publish the complete prebuilt image set before installation.

For a Community Scripts-style Proxmox LXC wizard, run on the Proxmox node:

```sh
curl -fsSL https://raw.githubusercontent.com/technochris1/alarm-management-installer/main/proxmox.sh -o /tmp/alarm-proxmox.sh
bash /tmp/alarm-proxmox.sh
```

This project maintains the helper independently. It creates an unprivileged
Debian 13 LXC, installs Docker/Compose inside it, then runs the normal
registry installer. No Docker packages are installed on the Proxmox node.
Choose resources, storage, bridge, VLAN, DHCP/static IPv4 and DNS in the wizard.
Registry login and site settings remain interactive. Portainer is optional:
choose whether to install it, its HTTPS port and its initial admin password.
Later run `update` inside the
LXC or choose Update in the helper with the existing CT ID and site directory.
Updates use the installed `install.sh`, with preparation and typed `APPLY`.
Failures retain the CT/disks; never recreate over existing data. Existing unrelated
`update` commands are refused rather than replaced.

On a native Linux Docker Engine host with Compose v2 (Portainer is optional),
log in once with an account that can pull the private images:

```sh
docker login
bash -c "$(curl -fsSL https://raw.githubusercontent.com/technochris1/alarm-management-installer/main/install.sh)"
```

Run as the same user with Docker and `/opt` access (normally root). Optional
variables: `ALARM_INSTALL_DIR=/opt/alarms`, `ALARM_IMAGE_TAG=latest`, and
`ALARM_PORTAINER_URL=https://portainer.example:9443`.

Setup runs in a disposable container. The app and internal operations worker run in separate containers; Android pairing comes afterward.
Rerunning the installer detects existing alarm sites and offers a host-approved
Site Maintenance update, configuration repair, or cancellation. Multiple sites
require `--directory /existing/site`. Use `--update --manifest HTTPS-URL` to prepare
an update directly; applying still requires typed `APPLY` approval on the host.
The web application shows read-only maintenance status and cannot initiate updates.
The installer/maintenance require administrative Docker access. Registry pull credentials are retained in
the private deployment secret directory for maintenance.

If Docker uses a host credential helper, use a dedicated login directory:
`export DOCKER_CONFIG="$HOME/.config/alarm-docker"; docker login`, then rerun.
Windows needs its Windows host discovery helper. On Linux, Docker Desktop is
detected and rejected with native Engine instructions; PowerShell is not used.
No application volumes are removed during upgrades.
Before the wizard, effective Docker memory, CPU and PID limits are checked.
Known Alpine/OpenRC LXC cgroup delegation failures are repaired automatically,
with a small host OpenRC boot hook before Docker; no host packages are installed.
Unsupported resource-limit failures stop setup without disabling limits.
Docker storage is checked before downloads (at least 2 GiB and 4096 free inodes).
Insufficient storage stops setup with expansion instructions; data is not pruned.
