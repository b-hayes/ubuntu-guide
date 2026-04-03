#!/bin/bash

# Exit on error
set -e

# Get timestamp for backups
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

echo "Updating package list and installing required packages..."
sudo apt update
sudo apt install -y samba wsdd || {
    echo "ERROR: Failed to install required packages"
    exit 1
}

# Create a backup of the original smb.conf with timestamp
if [ -f "/etc/samba/smb.conf" ]; then
    BACKUP_FILE="/etc/samba/smb.conf.bak_$TIMESTAMP"
    echo "Creating backup of smb.conf as $BACKUP_FILE..."
    if ! sudo cp "/etc/samba/smb.conf" "$BACKUP_FILE"; then
        echo "ERROR: Failed to create backup of smb.conf"
        exit 1
    fi
    echo "Backup created at $BACKUP_FILE"
fi

# Create a shared directory
SHARE_DIR="$HOME/shared"
if [ ! -d "$SHARE_DIR" ]; then
    echo "Creating shared directory at $SHARE_DIR..."
    if ! mkdir -p "$SHARE_DIR"; then
        echo "ERROR: Failed to create shared directory"
        exit 1
    fi
    chmod -R 777 "$SHARE_DIR"
    echo "Shared directory created at $SHARE_DIR"
else
    echo "Shared directory already exists at $SHARE_DIR"
fi

# Get the current username
CURRENT_USER=$(whoami)

# Configure Samba
echo "Configuring Samba..."
TEMP_CONF=$(mktemp)
cat > "$TEMP_CONF" << EOL
[global]
   workgroup = WORKGROUP
   server string = %h server (Samba, Ubuntu)
   log file = /var/log/samba/log.%m
   max log size = 1000
   security = user
   map to guest = bad user
   usershare allow guests = yes
   vfs objects = acl_xattr
   map acl inherit = yes

[Shared]
   path = $SHARE_DIR
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0755
   directory mask = 0755
   force user = $CURRENT_USER
EOL

# Verify the generated config
if ! testparm -s "$TEMP_CONF" >/dev/null 2>&1; then
    echo "ERROR: Generated Samba configuration is invalid"
    rm -f "$TEMP_CONF"
    exit 1
fi

# Install the new config
if ! sudo cp "$TEMP_CONF" /etc/samba/smb.conf; then
    echo "ERROR: Failed to install Samba configuration"
    rm -f "$TEMP_CONF"
    exit 1
fi
rm -f "$TEMP_CONF"

# Restart Samba services
echo "Restarting Samba services..."
if ! sudo systemctl restart smbd nmbd; then
    echo "ERROR: Failed to restart Samba services"
    exit 1
fi
if ! sudo systemctl enable smbd nmbd >/dev/null 2>&1; then
    echo "WARNING: Failed to enable Samba services on boot"
fi

# Start and enable WSDD for Windows Network Discovery
echo "Setting up WSDD for Windows Network Discovery..."
if ! sudo systemctl is-active --quiet wsdd 2>/dev/null; then
    if ! sudo systemctl enable --now wsdd >/dev/null 2>&1; then
        echo "WARNING: Failed to enable WSDD service"
    fi
fi

# Add firewall rules
echo "Configuring firewall..."
if ! sudo ufw status | grep -q 'Samba'; then
    if ! sudo ufw allow samba >/dev/null 2>&1; then
        echo "WARNING: Failed to add Samba firewall rule"
    fi
    sudo ufw allow 5357/udp >/dev/null 2>&1  # For WSDD
fi

# Check if Samba user exists
echo "Checking Samba user..."
if ! sudo pdbedit -L | grep -q "^$CURRENT_USER:"; then
    echo "Creating Samba user $CURRENT_USER..."
    if ! sudo smbpasswd -a "$CURRENT_USER" -n; then
        echo "WARNING: Failed to create Samba user. You may need to run: sudo smbpasswd -a $CURRENT_USER"
    fi
else
    echo "Samba user $CURRENT_USER already exists"
fi

echo "\nSetup complete!"
echo ""
echo "Next steps:"
echo "1. Set a Samba password for your user by running: sudo smbpasswd -a $CURRENT_USER"
echo "2. On Windows, you should now see this computer in Network (File Explorer > Network)"
echo "3. The shared folder is located at: $SHARE_DIR"
echo ""
echo "Troubleshooting:"
echo "- If you don't see the computer in Windows Network, try restarting the Windows computer"
echo "- Check service status with: sudo systemctl status smbd nmbd wsdd"
echo "- View Samba logs with: sudo tail -f /var/log/samba/log.*"
