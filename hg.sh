#!/bin/bash
# Honeygain installer for Bazzite (Fedora Atomic / immutable, rootless Podman + Quadlet)
# Adapted from https://github.com/spiritLHLS/honeygain-one-click-command-installation
#
# Design notes for Bazzite:
#  - Bazzite is image-based (rpm-ostree). We never layer packages on the host.
#  - Podman ships by default, so we use it instead of Docker.
#  - Persistence across reboot/logout is handled via rootless Podman + a
#    systemd user "Quadlet" unit, plus `loginctl enable-linger`.
#  - Auto-updates use Podman's built-in `podman-auto-update.timer`
#    instead of a Watchtower sidecar container.

set -euo pipefail

NAME='honeygain'
QUADLET_DIR="$HOME/.config/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/${NAME}.container"

red(){ echo -e "\033[31m\033[01m$1$2\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1$2\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1$2\033[0m"; }
reading(){ read -rp "$(green "$1")" "$2"; }

# --- sanity checks -----------------------------------------------------

check_not_root(){
  if [[ $(id -u) -eq 0 ]]; then
    red " Don't run this as root. Rootless Podman + Quadlet expects a normal user account.\n"
    exit 1
  fi
}

check_bazzite(){
  if ! grep -qi "bazzite" /etc/os-release 2>/dev/null; then
    yellow " Warning: this doesn't look like Bazzite. Continuing anyway, but you may need adjustments.\n"
  fi
}

check_podman(){
  if ! command -v podman >/dev/null 2>&1; then
    red " podman was not found. On Bazzite it should be preinstalled.\n"
    red " If it's missing, run: rpm-ostree install podman   (then reboot)\n"
    exit 1
  fi
}

check_ipv4(){
  API_NET=("ip.sb" "ipget.net" "ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "api.ipify.org")
  for p in "${API_NET[@]}"; do
    response=$(curl -s4m8 "$p" || true)
    sleep 1
    if [ -n "$response" ] && ! echo "$response" | grep -q "error"; then
      IP_API="$p"
      break
    fi
  done
  if [ -z "${IP_API:-}" ] || ! curl -s4m8 "$IP_API" | grep -q '\.'; then
    red " ERROR: The host must have working IPv4 connectivity to pull images.\n"
    exit 1
  fi
}

input_token(){
  [ -z "${EMAIL:-}" ] && reading " Enter your Email, if you do not have one, open https://r.honeygain.me/24610E80CD: " EMAIL
  [ -z "${PASSWORD:-}" ] && reading " Enter your Password: " PASSWORD
}

# --- build ---------------------------------------------------------------

container_build(){
  green "\n Enabling linger so your containers keep running after logout/reboot.\n"
  loginctl enable-linger "$(whoami)"

  # Remove any old container/quadlet from a previous run
  if podman ps -a --format '{{.Names}}' | grep -qw "$NAME"; then
    yellow " Removing old honeygain container.\n"
    systemctl --user stop "${NAME}.service" 2>/dev/null || true
    podman rm -f "$NAME" >/dev/null 2>&1 || true
  fi

  green "\n Pulling honeygain image.\n"
  podman pull docker.io/honeygain/honeygain

  mkdir -p "$QUADLET_DIR"

  yellow " Writing Quadlet unit: $QUADLET_FILE\n"
  cat > "$QUADLET_FILE" <<EOF
[Unit]
Description=Honeygain

[Container]
Image=docker.io/honeygain/honeygain
ContainerName=${NAME}
Exec=-tou-accept -email ${EMAIL} -pass ${PASSWORD} -device honeygainnode
# Have Podman's auto-update timer pull newer images automatically
AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

  # Quadlet files are picked up by systemd via podman-generator; reload to
  # pick up the new unit, then start it.
  systemctl --user daemon-reload
  systemctl --user start "${NAME}.service"

  # Enable Podman's built-in auto-update timer (replaces Watchtower)
  systemctl --user enable --now podman-auto-update.timer
}

# --- result / uninstall ---------------------------------------------------

result(){
  sleep 2
  if systemctl --user is-active --quiet "${NAME}.service"; then
    green " Install success. Check status with: systemctl --user status ${NAME}.service\n"
  else
    red " Install may have failed. Check logs with: journalctl --user -u ${NAME}.service\n"
  fi
}

uninstall(){
  systemctl --user stop "${NAME}.service" 2>/dev/null || true
  systemctl --user disable "${NAME}.service" 2>/dev/null || true
  rm -f "$QUADLET_FILE"
  systemctl --user daemon-reload
  podman rm -f "$NAME" 2>/dev/null || true
  IMG_ID=$(podman images --format '{{.Id}} {{.Repository}}' | awk '/honeygain\/honeygain/{print $1}')
  [ -n "$IMG_ID" ] && podman rmi -f "$IMG_ID" 2>/dev/null || true
  green "\n Uninstalled honeygain container, image, and quadlet unit.\n"
  exit 0
}

# --- args ------------------------------------------------------------------

while getopts "UuM:m:P:p:" OPTNAME; do
  case "$OPTNAME" in
    'U'|'u' ) uninstall;;
    'M'|'m' ) EMAIL=$OPTARG;;
    'P'|'p' ) PASSWORD=$OPTARG;;
  esac
done

# --- main --------------------------------------------------------------

check_not_root
check_bazzite
check_podman
check_ipv4
input_token
container_build
result
