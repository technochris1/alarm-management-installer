# Alarm management installer

This public repository contains the Linux installer and public release metadata.
Application code stays private; images are intended for private distribution.
The owner must publish the complete prebuilt image set before installation.

On a native Linux Docker Engine host with Compose v2 and Portainer running,
log in once with an account that can pull the private images:

```sh
docker login
bash -c "$(curl -fsSL https://raw.githubusercontent.com/technochris1/alarm-management-installer/main/install.sh)"
```

Run as the same user with Docker and `/opt` access (normally root). Optional
variables: `ALARM_INSTALL_DIR=/opt/alarms`, `ALARM_IMAGE_TAG=latest`, and
`ALARM_PORTAINER_URL=https://portainer.example:9443`.

Setup runs in a disposable container. The app, updater and native Linux LAN
discovery run in separate containers; Android pairing comes afterward.
The installer/updater require administrative Docker access. Discovery receives
no Docker socket or site credentials. Registry pull credentials are retained in
the private deployment secret directory for the updater.

If Docker uses a host credential helper, use a dedicated login directory:
`export DOCKER_CONFIG="$HOME/.config/alarm-docker"; docker login`, then rerun.
Windows/Docker Desktop needs the Windows host discovery helper and is detected
before Linux installation. No application volumes are removed during upgrades.
