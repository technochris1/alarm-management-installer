#!/bin/sh
# Only the shell and Docker CLI run on Linux; setup dependencies live in an image.
set -eu
REPOSITORY=technochris1/Open-Source-Alarm-Management-System
BOOTSTRAP_IMAGE=python:3.12-alpine@sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a
INSTALL_DIR=${ALARM_INSTALL_DIR:-/opt/alarm-management-system}
REF=${ALARM_INSTALL_REF:-main}
PORTAINER_URL=${ALARM_PORTAINER_URL:-}
PORTAINER_CA=${ALARM_PORTAINER_CA:-}
NO_UPDATER=false
DEPLOYMENT_SOURCE=${ALARM_DEPLOYMENT_SOURCE:-registry}
IMAGE_REPOSITORY=${ALARM_IMAGE_REPOSITORY:-technochris1/opensourcealarmmanagementsystem}
IMAGE_TAG=${ALARM_IMAGE_TAG:-latest}
TOOLS_IMAGE=alarm-operations:local
usage() {
  cat <<'EOF'
Usage: sh install.sh [--directory /absolute/path] [--ref branch-or-tag]
                     [--portainer-url https://host:9443] [--portainer-ca /path/ca.pem]
                     [--no-updater] [--source]

Optional environment defaults: ALARM_INSTALL_DIR, ALARM_INSTALL_REF,
ALARM_PORTAINER_URL and ALARM_PORTAINER_CA. Command-line flags take precedence.
Private source downloads use GITHUB_TOKEN or an existing gh auth login.
Default: pull private prebuilt images after docker login on this host.
Image defaults: ALARM_IMAGE_REPOSITORY, ALARM_IMAGE_TAG (latest).
--source retains the developer build path; --ref selects its Git ref.

Native Linux Docker Engine: setup, updater and discovery runtimes run in containers.
Requires an existing local rootful Docker Engine, Compose v2 and Portainer.
No host Python, Git, OpenSSL, packages or systemd service are installed.
Alpine/OpenRC LXC delegation failures receive a small cgroup boot hook before Docker.
Windows/Docker Desktop requires setup.ps1 and host discovery instead.
Existing installation files, configuration, volumes and secrets are preserved.
EOF
}
fail() { printf '%s\n' "$*" >&2; exit 1; }
emit_cgroup_service() {
  cat <<'ALARM_CGROUP_SERVICE'
#!/sbin/openrc-run
# alarm-management-owned: cgroup-delegation-v1
description="Enable Docker resource delegation in Alpine LXC"
depend() { need cgroups; before docker; }

cgroup_move_process() { printf '%s\n' "$2" > "$1/host-processes/cgroup.procs"; }
cgroup_enable() { printf '+cpu +memory +pids\n' > "$1/cgroup.subtree_control"; }
repair_cgroups() {
  cg=$1
  proc=$2
  [ -r "$cg/cgroup.controllers" ] || return 1
  for controller in cpu memory pids; do
    grep -qw "$controller" "$cg/cgroup.controllers" || return 1
  done
  # Avoid moving any processes when delegation already works.
  missing=false
  for controller in cpu memory pids; do
    grep -qw "$controller" "$cg/cgroup.subtree_control" || missing=true
  done
  if [ "$missing" = true ]; then
    [ ! -L "$cg/host-processes" ] || return 1
    mkdir -p "$cg/host-processes" || return 1
    # Snapshots and bounded retries handle processes exiting/spawning during repair.
    attempt=0
    while [ "$attempt" -lt 3 ]; do
      pids=$(cat "$cg/cgroup.procs") || return 1
      [ -n "$pids" ] || break
      for pid in $pids; do
        case "$pid" in *[!0-9]*|'') return 1;; esac
        if [ -d "$proc/$pid" ]; then
          cgroup_move_process "$cg" "$pid" || {
            [ ! -d "$proc/$pid" ] || return 1
          }
        fi
      done
      attempt=$((attempt + 1))
    done
    cgroup_enable "$cg" || return 1
  fi
  # cgroupfs uses /docker; existing container processes stay in their own groups.
  if [ -d "$cg/docker" ]; then
    cgroup_enable "$cg/docker" || return 1
  fi
}
start() {
  ebegin "Enabling Docker CPU, memory and PID controllers"
  repair_cgroups /sys/fs/cgroup /proc
  result=$?
  eend "$result"
  return "$result"
}
stop() { return 0; } # Never withdraw controllers from running containers.
if [ "${1:-}" = --repair ]; then
  repair_cgroups /sys/fs/cgroup /proc
  exit $?
fi
ALARM_CGROUP_SERVICE
}
resource_probe() {
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true --memory 64m --cpus 0.1 --pids-limit 32 \
    --entrypoint /bin/sh "$TOOLS_IMAGE" -ec '
      if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        test "$(cat /sys/fs/cgroup/memory.max)" = 67108864
        test "$(cat /sys/fs/cgroup/pids.max)" = 32
        read quota period < /sys/fs/cgroup/cpu.max
      else
        test "$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)" = 67108864
        test "$(cat /sys/fs/cgroup/pids/pids.max)" = 32
        cpu=/sys/fs/cgroup/cpu
        [ -d "$cpu" ] || cpu=/sys/fs/cgroup/cpu,cpuacct
        quota=$(cat "$cpu/cpu.cfs_quota_us")
        period=$(cat "$cpu/cpu.cfs_period_us")
      fi
      test "$quota" -gt 0
      test "$((quota * 10))" = "$period"
    '
}
resource_preflight() {
  printf '\nChecking Docker CPU, memory and PID limits before setup.\n'
  probe_log=$(mktemp)
  if resource_probe >"$probe_log" 2>&1; then
    probe_ok=true
  else
    probe_ok=false
  fi
  # A namespaced v2 root has memory.max; the machine's real root does not.
  alpine_lxc=false
  if [ -f /etc/alpine-release ] && [ -x /sbin/openrc-run ] && \
      command -v rc-update >/dev/null 2>&1 && [ -f /sys/fs/cgroup/memory.max ] && \
      [ "$(docker info --format '{{.CgroupDriver}}')" = cgroupfs ] && \
      [ "$(docker info --format '{{.CgroupVersion}}')" = 2 ]; then
    alpine_lxc=true
  fi
  service=/etc/init.d/alarm-cgroup-delegation
  if [ "$alpine_lxc" = true ]; then
    # Repair only the known delegation failure, not unrelated runtime failures.
    needs_hook=false
    if [ -f "$service" ] || grep -q '0::/host-processes$' /proc/1/cgroup; then
      needs_hook=true
    elif [ "$probe_ok" = false ] && grep -Eq 'memory.max|cpu.max|cgroup config|cgroup.subtree_control' "$probe_log"; then
      for controller in cpu memory pids; do
        grep -qw "$controller" /sys/fs/cgroup/cgroup.subtree_control || needs_hook=true
      done
    fi
    if [ "$needs_hook" = true ]; then
      [ "$(id -u)" = 0 ] || { rm -f "$probe_log"; fail 'Alpine LXC cgroup repair requires running the installer as root.'; }
      if [ -L "$service" ] || { [ -e "$service" ] && ! grep -qx '# alarm-management-owned: cgroup-delegation-v1' "$service"; }; then
        rm -f "$probe_log"
        fail 'An unrelated alarm-cgroup-delegation service exists; it was not overwritten.'
      fi
      printf 'Repairing Alpine/OpenRC cgroup delegation and configuring it before Docker at boot.\n'
      service_tmp=$(mktemp /etc/init.d/.alarm-cgroup-delegation.XXXXXX)
      emit_cgroup_service > "$service_tmp"
      if ! sh "$service_tmp" --repair || ! resource_probe >"$probe_log" 2>&1; then
        cat "$probe_log" >&2
        rm -f "$service_tmp" "$probe_log"
        fail 'Cgroup repair could not verify resource limits. Setup stopped; check LXC controller delegation on the Proxmox host.'
      fi
      chmod 0755 "$service_tmp"
      mv -f "$service_tmp" "$service"
      rc-update add alarm-cgroup-delegation default || {
        rm -f "$probe_log"
        fail 'Resource limits work, but the boot hook could not be enabled. Fix OpenRC registration before setup.'
      }
      probe_ok=true
      CGROUP_HOOK=true
    fi
  fi
  if [ "$probe_ok" = false ]; then
    cat "$probe_log" >&2
    rm -f "$probe_log"
    fail 'Docker resource-limit preflight failed before setup. Check host/LXC cgroup delegation; no limits were disabled and no site configuration was changed.'
  fi
  rm -f "$probe_log"
  printf 'Docker resource-limit preflight passed.\n'
}
CGROUP_HOOK=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --directory|--ref|--portainer-url|--portainer-ca)
      [ "$#" -ge 2 ] || fail "Missing value for $1"
      case "$1" in
        --directory) INSTALL_DIR=$2;; --ref) REF=$2;;
        --portainer-url) PORTAINER_URL=$2;; --portainer-ca) PORTAINER_CA=$2;;
      esac
      shift 2;;
    --no-updater|--no-service) NO_UPDATER=true; shift;;
    --source) DEPLOYMENT_SOURCE=source; shift;;
    --install-service) fail 'Linux uses an updater container now; omit --install-service.';;
    --help|-h) usage; exit 0;;
    *) usage >&2; fail "Unknown argument: $1";;
  esac
done
case "$(uname -s)" in
  Linux) ;;
  MINGW*|MSYS*|CYGWIN*) fail 'Windows detected: run setup.ps1. The host updater/discovery helper is required outside Docker Desktop.';;
  *) fail 'This helper supports native Linux Docker Engine. Docker Desktop requires host discovery.';;
esac
if [ -n "${WSL_DISTRO_NAME:-}" ]; then
  fail 'Windows/WSL detected: use setup.ps1 on Windows so discovery runs on the physical host.'
fi
case "$(uname -r)" in *icrosoft*|*WSL*) fail 'Windows/WSL detected: use the Windows host installer.';; esac
case "$INSTALL_DIR" in /*) ;; *) fail 'The installation directory must be absolute.';; esac
case "$INSTALL_DIR" in *[!a-zA-Z0-9_./-]*|/) fail 'Choose a directory without spaces or special characters.';; esac
command -v docker >/dev/null 2>&1 || fail 'Docker is required. No host packages were installed.'
docker info >/dev/null 2>&1 || fail 'Docker is not running or this user cannot access it.'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 is required.'
server_os=$(docker info --format '{{.OSType}}')
engine_os=$(docker info --format '{{.OperatingSystem}}')
security=$(docker info --format '{{json .SecurityOptions}}')
[ "$server_os" = linux ] || fail 'Linux containers are required.'
case "$engine_os" in *'Docker Desktop'*) fail 'Docker Desktop detected: host LAN discovery is required; use the host installer.';; esac
case "$security" in *rootless*) fail 'Rootless Docker does not provide the native host-network discovery path. Use a rootful native Linux Engine or the documented host helper.';; esac
endpoint=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}
case "$endpoint" in unix:///*) DOCKER_SOCKET=${endpoint#unix://};; *) fail 'Run this script on the Docker host using its local Unix socket; remote engines are not supported.';; esac
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet alarm-update-agent.service; then
  fail 'An existing host updater is active. Stop alarm-update-agent.service before switching to the updater container; no application configuration was changed.'
fi
if [ -z "$PORTAINER_URL" ]; then
  images=$(docker ps --format '{{.Image}}')
  printf '%s\n' "$images" | grep -Eq '(^|/)portainer/portainer-(ce|ee)(:|@|$)' || fail 'No running Portainer CE/EE server found. Start Portainer or supply --portainer-url.'
fi

case "$DEPLOYMENT_SOURCE" in registry|source) ;; *) fail 'ALARM_DEPLOYMENT_SOURCE must be registry or source.';; esac
case "$IMAGE_REPOSITORY" in *[!a-z0-9_./-]*|'') fail 'Use a Docker Hub namespace/repository without credentials.';; esac
printf '%s' "$IMAGE_REPOSITORY" | grep -Eq '^[a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9._-]*$' || fail 'Use a Docker Hub namespace/repository.'
printf '%s' "$IMAGE_TAG" | grep -Eq '^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$' || fail 'Invalid image tag.'
if [ "$DEPLOYMENT_SOURCE" = registry ]; then
  printf '\nPulling the private setup runtime from Docker Hub.\n'
  TOOLS_IMAGE="$IMAGE_REPOSITORY:tools-$IMAGE_TAG"
  docker pull "$TOOLS_IMAGE" || fail 'Image pull failed. Run docker login on this host and check that the tools tag has been published and your account has access.'
  TOOLS_IMAGE=$(docker image inspect --format '{{index .RepoDigests 0}}' "$TOOLS_IMAGE")
  case "$TOOLS_IMAGE" in *@sha256:*) ;; *) fail 'The tools image did not resolve to an immutable digest.';; esac
else
script_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
context=''
if [ -f "$INSTALL_DIR/Dockerfile.operations" ]; then
  context=$INSTALL_DIR
elif [ -f "$script_root/Dockerfile.operations" ]; then
  context=$script_root
fi
printf '\nBuilding the isolated setup/maintenance runtime. No host packages will be installed.\n'
if [ -n "$context" ]; then
  docker build --file Dockerfile.operations --target tools --tag "$TOOLS_IMAGE" "$context"
else
  if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN=$(gh auth token --hostname github.com 2>/dev/null) || GITHUB_TOKEN=''
  fi
  # Read credentials on stdin, never in a URL, image layer or Docker environment.
  # GitHub archives have one enclosing directory; remove it for Docker's context.
  SOURCE_FETCHER='
import sys, tarfile
from pathlib import PurePosixPath
from urllib.request import Request, HTTPRedirectHandler, build_opener
from urllib.error import HTTPError
from urllib.parse import quote

class PublicRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None:
            redirected.remove_header("Authorization")
        return redirected

def fetch(ref, repository, token, output):
    url = "https://api.github.com/repos/" + repository + "/tarball/" + quote(ref, safe="")
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "alarm-installer"}
    if token:
        headers["Authorization"] = "Bearer " + token
    with build_opener(PublicRedirect()).open(Request(url, headers=headers), timeout=60) as response:
        with tarfile.open(fileobj=response, mode="r|gz") as source:
            with tarfile.open(fileobj=output, mode="w|") as target:
                root = None
                for member in source:
                    path = PurePosixPath(member.name)
                    if path.is_absolute() or ".." in path.parts or not path.parts:
                        raise ValueError("Unsafe source archive path")
                    if root is None:
                        root = path.parts[0]
                    if path.parts[0] != root:
                        raise ValueError("Unexpected source archive root")
                    if len(path.parts) == 1:
                        if not member.isdir():
                            raise ValueError("Expected an enclosing source directory")
                        continue
                    if not (member.isdir() or member.isfile()):
                        raise ValueError("Source archive contains an unsupported link or device")
                    stream = source.extractfile(member) if member.isfile() else None
                    member.name = str(PurePosixPath(*path.parts[1:]))
                    member.pax_headers = {}
                    target.addfile(member, stream)

if __name__ == "__main__":
    try:
        fetch(sys.argv[1], sys.argv[2], sys.stdin.read().strip(), sys.stdout.buffer)
    except HTTPError as exc:
        print("Source download failed (HTTP %s). Check the ref; for private source run gh auth login or set GITHUB_TOKEN with repository Contents: read access." % exc.code, file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("Source download failed. Check connectivity, certificates and the source archive.", file=sys.stderr)
        sys.exit(1)
'
  source_archive=$(mktemp)
  trap 'rm -f -- "$source_archive"' EXIT
  trap 'exit 1' HUP INT TERM
  printf '%s' "${GITHUB_TOKEN:-}" | docker run --rm -i --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges:true --entrypoint python \
    "$BOOTSTRAP_IMAGE" -c "$SOURCE_FETCHER" "$REF" "$REPOSITORY" > "$source_archive" || \
    fail 'Could not fetch source; no installation was started. A browser raw-link token does not authenticate the repository archive. Set GITHUB_TOKEN for private repositories.'
  docker build --file Dockerfile.operations --target tools --tag "$TOOLS_IMAGE" - < "$source_archive"
  rm -f -- "$source_archive"
  trap - EXIT HUP INT TERM
fi
fi

resource_preflight

if [ -n "$PORTAINER_URL" ]; then
  set -- docker run --rm --network host --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true
  if [ -n "$PORTAINER_CA" ]; then
    [ -r "$PORTAINER_CA" ] || fail 'The Portainer CA file is not readable.'
    set -- "$@" --mount "type=bind,source=$PORTAINER_CA,target=/portainer-ca.pem,readonly"
  fi
  set -- "$@" "$TOOLS_IMAGE" python /opt/tools/container-install.py --check-only --portainer-url "$PORTAINER_URL"
  if [ -n "$PORTAINER_CA" ]; then set -- "$@" --portainer-ca /portainer-ca.pem; fi
  "$@"
fi
mkdir -p "$INSTALL_DIR"
INSTALL_DIR=$(CDPATH= cd -- "$INSTALL_DIR" && pwd -P)
case "$INSTALL_DIR" in /|*[!a-zA-Z0-9_./-]*) fail 'The resolved installation directory is not supported.';; esac
printf '\nInstalling in %s. The wizard runs in a disposable container.\n' "$INSTALL_DIR"
set -- docker run --rm -i
if [ -t 0 ] && [ -t 1 ]; then set -- "$@" -t; fi
set -- "$@" --network host --mount "type=bind,source=$DOCKER_SOCKET,target=/var/run/docker.sock" \
  --mount "type=bind,source=$INSTALL_DIR,target=$INSTALL_DIR" \
  --workdir "$INSTALL_DIR" --env "ALARM_DOCKER_SOCKET=$DOCKER_SOCKET"
if [ "$DEPLOYMENT_SOURCE" = registry ]; then
  docker_config=${DOCKER_CONFIG:-${HOME:?HOME or DOCKER_CONFIG is required}/.docker}/config.json
  if [ -r "$docker_config" ]; then
    set -- "$@" --mount "type=bind,source=$docker_config,target=/run/host-docker-config.json,readonly"
  fi
  set -- "$@" --env ALARM_DEPLOYMENT_SOURCE=registry --env "ALARM_OPERATIONS_IMAGE=$TOOLS_IMAGE"
fi
set -- "$@" "$TOOLS_IMAGE" python /opt/tools/container-install.py
if [ "$NO_UPDATER" = true ]; then set -- "$@" --no-updater; fi
"$@"
if [ "$CGROUP_HOOK" = true ]; then
  printf '\nContainers are visible in Portainer. Alpine cgroup boot repair is enabled; application services run in containers.\n'
else
  printf '\nContainers are visible in Portainer. No host service was installed.\n'
fi
