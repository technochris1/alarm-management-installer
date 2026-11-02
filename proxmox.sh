#!/usr/bin/env bash
# alarm-proxmox-managed: Community Scripts-style launcher, maintained by this project.
# No Community Scripts framework is downloaded or executed.
set -Eeuo pipefail

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }
usage() {
  cat <<'EOF'
Alarm Management System — Proxmox setup and update
Run on the Proxmox node as root, with an interactive terminal:
  bash proxmox.sh                         # guided menu
  bash proxmox.sh --create                # create a Debian 13 LXC
  bash proxmox.sh --update --ctid 120      # update an existing site
  bash proxmox.sh --status --ctid 120      # maintenance status
Optional: --directory /opt/alarms (default /opt/alarm-management-system)
Inside a provisioned LXC: update, or alarm-setup to resume initial setup.
Creation asks about CT ID, resources, storage, bridge, VLAN and IPv4/DNS.
Existing sites use their own install.sh and its typed update approval.
EOF
}

ask() {
  local prompt=$1 default=${2:-} value
  if command -v whiptail >/dev/null 2>&1; then
    value=$(whiptail --title 'Alarm Management System' --inputbox "$prompt" 10 76 "$default" 3>&1 1>&2 2>&3) || return 130
  else
    read -r -p "$prompt [$default]: " value || return 130
    value=${value:-$default}
  fi
  printf '%s' "$value"
}

menu() {
  if command -v whiptail >/dev/null 2>&1; then
    whiptail --title 'Alarm Management System' --menu 'Choose an operation' 16 76 4 \
      create 'Create a new Debian LXC and install' update 'Update an existing alarm site' \
      status 'Read existing maintenance status' quit 'Exit' 3>&1 1>&2 2>&3 || exit 0
  else
    ask 'Operation: create, update, status, quit' quit
  fi
}

validate_directory() {
  [[ $DIRECTORY =~ ^/[a-zA-Z0-9_-]+(/[a-zA-Z0-9_.-]+)*$ && $DIRECTORY != */../* && $DIRECTORY != */.. && $DIRECTORY != */./* && $DIRECTORY != */. ]] || fail 'Use an absolute site directory without spaces or parent traversal.'
}

integer() { [[ $2 =~ ^[0-9]+$ ]] && (( 10#$2 >= $3 && 10#$2 <= $4 )) || fail "Invalid $1: $2"; }
bridge_exists() { [[ -d /sys/class/net/$1/bridge ]]; }

fetch() {
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 180 "$1" --output "$2"
}

guest_maintenance() {
  # The installed launcher owns selection, schema checks, backups and approval.
  [[ -f $DIRECTORY/.env && -f $DIRECTORY/docker-compose.yml && -f $DIRECTORY/install.sh ]] || \
    fail "No installed alarm site at $DIRECTORY; select its existing directory."
  exec sh "$DIRECTORY/install.sh" --directory "$DIRECTORY" "--$ACTION"
}

portainer_password_hash() {
  local password confirmation hash
  read -r -s -p 'Portainer admin password (at least 12 characters): ' password || return 130
  printf '\n' >&2
  read -r -s -p 'Confirm Portainer admin password: ' confirmation || return 130
  printf '\n' >&2
  [[ ${#password} -ge 12 && $password == "$confirmation" ]] || fail 'Passwords must match and contain at least 12 characters.'
  # Plaintext travels through stdin, never argv, environment, logs or a disk file.
  hash=$(printf '%s\n' "$password" | htpasswd -BinC 12 admin) || fail 'Could not hash the Portainer administrator password.'
  unset password confirmation
  printf '%s' "${hash#*:}"
}

offer_portainer() {
  local images choice port portainer hash
  images=$(docker ps --format '{{.Image}}') || fail 'Could not inspect existing Docker containers.'
  if grep -Eq '(^|/)portainer/portainer-(ce|ee)(:|@|$)' <<< "$images"; then
    note 'An existing Portainer server is running; leaving its configuration and administrator unchanged.'
    return
  fi
  choice=$(ask 'Install and set up optional Portainer? (yes/no)' no)
  case ${choice,,} in no|n|'') note 'Skipping Portainer; the alarm system uses Docker Compose directly.'; return;; yes|y) ;; *) fail 'Choose yes or no for optional Portainer.';; esac
  ! docker container inspect alarm-portainer >/dev/null 2>&1 || fail 'alarm-portainer already exists; review it or skip optional Portainer.'
  ! docker volume inspect alarm_portainer_data >/dev/null 2>&1 || fail 'Existing Portainer data found; review it or skip optional Portainer to preserve its administrator.'
  port=$(ask 'Portainer HTTPS port' 9443); integer 'Portainer HTTPS port' "$port" 1 65535
  apt-get install -y apache2-utils
  hash=$(portainer_password_hash) || fail 'Portainer password setup did not complete.'
  docker pull portainer/portainer-ce:lts
  portainer=$(docker image inspect portainer/portainer-ce:lts --format '{{index .RepoDigests 0}}')
  [[ $portainer =~ ^portainer/portainer-ce@sha256:[a-f0-9]{64}$ ]] || fail 'Could not pin the Portainer image.'
  docker volume create alarm_portainer_data >/dev/null
  docker run -d --name alarm-portainer --restart unless-stopped -p "$port:9443" \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
    --mount type=volume,source=alarm_portainer_data,target=/data "$portainer" \
    --admin-password "$hash" --host unix:///var/run/docker.sock
  unset hash
  note "Portainer is configured for local Docker. Open HTTPS on this LXC at port $port and sign in as admin."
}

install_guest_commands() {
  local target path
  if [[ -e /etc/alarm-proxmox-site || -L /etc/alarm-proxmox-site ]]; then
    [[ ! -L /etc/alarm-proxmox-site && $(cat /etc/alarm-proxmox-site) == "$DIRECTORY" ]] || fail 'A different managed site is already registered; select its directory.'
  fi
  for target in /usr/local/sbin/alarm-proxmox /usr/local/bin/alarm-setup /usr/local/bin/update; do
    if [[ -e $target || -L $target ]]; then
      [[ ! -L $target ]] && grep -q '^# alarm-proxmox-managed:' "$target" || fail "Refusing to replace unrelated command $target."
      path="/var/backups/alarm-proxmox/$(date +%Y%m%d-%H%M%S)-$$"
      mkdir -p "$path"
      cp -p -- "$target" "$path/$(basename "$target")"
    fi
  done
  if [[ ! ${BASH_SOURCE[0]} -ef /usr/local/sbin/alarm-proxmox ]]; then
    install -m 0755 "${BASH_SOURCE[0]}" /usr/local/sbin/alarm-proxmox
  fi
  printf '%s\n' "$DIRECTORY" > /etc/alarm-proxmox-site
  chmod 0600 /etc/alarm-proxmox-site
  cat > /usr/local/bin/update <<'EOF'
#!/usr/bin/env bash
# alarm-proxmox-managed: preserve host-approved maintenance through install.sh.
exec /usr/local/sbin/alarm-proxmox --guest --update "$@"
EOF
  cat > /usr/local/bin/alarm-setup <<'EOF'
#!/usr/bin/env bash
# alarm-proxmox-managed: resume the initial registry installation.
exec /usr/local/sbin/alarm-proxmox --guest --install "$@"
EOF
  chmod 0755 /usr/local/bin/update /usr/local/bin/alarm-setup
}

guest_install() {
  # Bootstrap is deliberately separate from existing-site maintenance.
  [[ ! -e $DIRECTORY/.env && ! -e $DIRECTORY/docker-compose.yml ]] || fail 'An existing site is present. Use update; setup never reconfigures it.'
  [[ -f /etc/os-release ]] || fail 'Debian 13 is required for new containers.'
  local ID VERSION_ID VERSION_CODENAME
  . /etc/os-release
  [[ $ID == debian && $VERSION_ID == 13 ]] || fail 'New setup supports Debian 13 only.'
  if [[ ! -f /etc/alarm-proxmox-site ]]; then
    note 'Choose the LXC root password for console access (separate from the application administrator)'
    passwd
  fi
  note 'Installing Docker Engine and Compose inside the LXC (no Proxmox host packages)'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl
  if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    fetch https://download.docker.com/linux/debian/gpg /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker
  docker info >/dev/null
  docker compose version
  install_guest_commands
  note 'Private registry access: sign in with an account allowed to pull the alarm images'
  docker login
  offer_portainer
  local installer
  installer=$(mktemp /tmp/alarm-installer.XXXXXX)
  trap 'rm -f -- "${installer:-}"' EXIT
  fetch https://raw.githubusercontent.com/technochris1/alarm-management-installer/main/install.sh "$installer"
  sh -n "$installer"
  # The existing installer preserves HTTP/HTTPS, exact ports and private image digests.
  sh "$installer" --directory "$DIRECTORY" --install
  rm -f -- "$installer"
  trap - EXIT
  note 'Setup completed. Use update in this LXC for reviewed release updates.'
}

push_guest() {
  # pct exec uses lxc-attach; stdin remains available for login/wizard/APPLY.
  local remote=/run/alarm-proxmox-launcher.sh
  pct push "$CTID" "${BASH_SOURCE[0]}" "$remote" --perms 0700
  pct exec "$CTID" --keep-env 0 -- bash "$remote" --guest "--$ACTION" --directory "$DIRECTORY"
}

create_container() {
  local hostname cores memory disk storage templates bridge vlan address gateway dns template net
  CTID=$(ask 'New container ID' "$(pvesh get /cluster/nextid)")
  integer 'container ID' "$CTID" 100 999999999
  # Cluster-wide VM/CT IDs share a namespace. Never reuse an existing ID.
  [[ $(pvesh get /cluster/nextid --vmid "$CTID") == "$CTID" ]] || fail 'Container/VM ID is already allocated.'
  hostname=$(ask 'Hostname' alarm-management)
  [[ $hostname =~ ^[a-z][a-z0-9-]{0,62}$ ]] || fail 'Invalid hostname.'
  local available_cores
  available_cores=$(nproc)
  cores=$(ask 'CPU cores' "$(( available_cores < 2 ? 1 : 2 ))"); integer cores "$cores" 1 "$available_cores"
  memory=$(ask 'Memory (MiB; minimum 2048)' 4096); integer memory "$memory" 2048 1048576
  disk=$(ask 'Disk size (GiB; minimum 16)' 24); integer disk "$disk" 16 1048576
  note 'Available container storage'
  pvesm status --content rootdir --enabled 1
  storage=$(ask 'Container disk storage' local-lvm)
  pvesm status --content rootdir --enabled 1 | awk 'NR>1 && $3=="active" {print $1}' | grep -Fxq -- "$storage" || fail 'Choose an active rootdir storage.'
  note 'Available template storage'
  pvesm status --content vztmpl --enabled 1
  templates=$(ask 'Template storage' local)
  pvesm status --content vztmpl --enabled 1 | awk 'NR>1 && $3=="active" {print $1}' | grep -Fxq -- "$templates" || fail 'Choose an active template storage.'
  bridge=$(ask 'Existing network bridge' vmbr0)
  [[ $bridge =~ ^[a-zA-Z0-9_.-]+$ ]] && bridge_exists "$bridge" || fail 'Choose an existing Linux bridge.'
  vlan=$(ask 'VLAN tag (0 for none)' 0); integer VLAN "$vlan" 0 4094
  address=$(ask 'IPv4: dhcp or address/prefix' dhcp)
  [[ $address == dhcp || $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || fail 'Invalid IPv4/CIDR; Proxmox also validates the network.'
  gateway=''
  if [[ $address != dhcp ]]; then
    gateway=$(ask 'IPv4 gateway' '')
    [[ $gateway =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail 'A static address needs an IPv4 gateway.'
  fi
  dns=$(ask 'DNS server (inherit host DNS when blank)' '')
  [[ -z $dns || $dns =~ ^[a-fA-F0-9:.]+$ ]] || fail 'Use a DNS server IP address.'
  note "Create CT $CTID: $hostname, $cores cores, $memory MiB, $disk GiB on $storage; $bridge, VLAN $vlan, $address"
  printf 'This creates an unprivileged Debian 13 LXC with nesting/keyctl and Docker; Portainer setup is optional.\n'
  pveam update
  template=$(pveam available --section system | awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | sort -V | tail -n 1)
  [[ -n $template ]] || fail 'No Debian 13 amd64 template is available.'
  pveam download "$templates" "$template"
  net="name=eth0,bridge=$bridge,ip=$address,ip6=manual,firewall=1"
  [[ $vlan == 0 ]] || net+=",tag=$vlan"
  [[ -z $gateway ]] || net+=",gw=$gateway"
  local -a args=("$CTID" "$templates:vztmpl/$template" --hostname "$hostname" --cores "$cores"
    --memory "$memory" --swap 512 --rootfs "$storage:$disk" --unprivileged 1
    --features 'nesting=1,keyctl=1' --onboot 1 --net0 "$net" --ostype debian
    --description 'Alarm Management System; app maintenance uses install.sh with typed host approval.')
  [[ -z $dns ]] || args+=(--nameserver "$dns")
  pct create "${args[@]}"
  note "CT $CTID created. If a later step fails it is retained; do not recreate it or delete its volumes."
  pct start "$CTID"
  local attempt
  local ready=false
  for (( attempt=0; attempt<30; attempt++ )); do
    if pct exec "$CTID" --keep-env 0 -- getent hosts download.docker.com >/dev/null 2>&1; then ready=true; break; fi
    sleep 2
  done
  $ready || fail "Network readiness timed out. Fix CT $CTID networking, then copy this helper into it and run --guest --install --directory $DIRECTORY; see docs/PROXMOX.md."
  ACTION=install
  push_guest
  note "CT $CTID ready. In its console use update for application releases; configure backups in Proxmox separately."
}

main() {
  ACTION=''; CTID=''; GUEST=false; DIRECTORY=/opt/alarm-management-system
  local explicit_directory=false
  while (( $# )); do
    case $1 in
      --create|--update|--status|--install)
        [[ -z $ACTION ]] || fail 'Select one action.'; ACTION=${1#--}; shift;;
      --ctid|--directory)
        (( $# >= 2 )) || fail "Missing value for $1"
        if [[ $1 == --ctid ]]; then CTID=$2; else DIRECTORY=$2; explicit_directory=true; fi; shift 2;;
      --guest) GUEST=true; shift;;
      --help|-h) usage; return;;
      *) fail "Unknown argument: $1";;
    esac
  done
  [[ $(id -u) == 0 ]] || fail 'Run as root.'
  if $GUEST; then
    if ! $explicit_directory && [[ -f /etc/alarm-proxmox-site ]]; then IFS= read -r DIRECTORY < /etc/alarm-proxmox-site; fi
    validate_directory
    case $ACTION in install) guest_install;; update|status) guest_maintenance;; *) fail 'Choose install, update or status inside the LXC.';; esac
    return
  fi
  for command in pct pvesh pvesm pveam; do command -v "$command" >/dev/null || fail 'Run on a Proxmox VE node.'; done
  [[ $(uname -m) == x86_64 ]] || fail 'LXC creation currently supports Proxmox amd64 nodes.'
  [[ -t 0 && -t 1 ]] || fail 'Use an interactive Proxmox shell; download the script before running it (do not pipe into Bash).'
  validate_directory
  [[ -n $ACTION ]] || ACTION=$(menu)
  case $ACTION in
    create) create_container;;
    update|status)
      pct list
      [[ -n $CTID ]] || CTID=$(ask 'Existing alarm container ID' '')
      integer 'container ID' "$CTID" 100 999999999
      if ! $explicit_directory; then DIRECTORY=$(ask 'Existing site directory' "$DIRECTORY"); validate_directory; fi
      pct status "$CTID" | grep -q 'status: running' || fail 'Start the selected container first; its settings were not changed.'
      push_guest;;
    quit|'') note 'Cancelled';;
    *) fail 'Choose create, update, status or quit.';;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
