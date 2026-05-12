#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RESET='\033[0m'

CERT_DIR="$HOME/.local/share/gnome-remote-desktop/certificates"
CERT="$CERT_DIR/rdp-tls.crt"
KEY="$CERT_DIR/rdp-tls.key"

echo -e "${BLUE}== Fix GNOME Remote Desktop ==${RESET}"

echo -e "${CYAN}Installing nvidia-driver-570...${RESET}"
sudo apt install -y nvidia-driver-570

echo -e "${CYAN}Enabling GDM auto-login for $USER...${RESET}"
sudo sed -i \
    -e 's|#\s*AutomaticLoginEnable\s*=.*|AutomaticLoginEnable=true|' \
    -e "s|#\s*AutomaticLogin\s*=.*|AutomaticLogin=$USER|" \
    /etc/gdm3/custom.conf

# Auto-login is required for GNOME Remote Desktop to register its RDP listener
# on boot, but we don't want to leave the session unlocked. This autostart entry
# locks the screen a few seconds after login so the desktop is never exposed.
echo -e "${CYAN}Creating lock-on-login autostart entry...${RESET}"
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/lock-on-login.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Lock on Login
Exec=bash -c "sleep 5 && loginctl lock-session"
X-GNOME-Autostart-enabled=true
EOF

echo -e "${CYAN}Regenerating TLS certificates...${RESET}"
mkdir -p "$CERT_DIR"
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/CN=gnome-remote-desktop" \
    -keyout "$KEY" \
    -out "$CERT" 2>&1

grdctl rdp set-tls-cert "$CERT"
grdctl rdp set-tls-key "$KEY"

echo -e "${YELLOW}Rebooting in 5 seconds...${RESET}"
echo -e "${YELLOW}After reboot, auto-login will fire then the screen will lock after 5 seconds. Connect via RDP as normal.${RESET}"
sleep 5
sudo reboot
