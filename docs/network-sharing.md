# Ubuntu 24 File Sharing with Windows

This guide explains how to set up file sharing between Ubuntu 24.04 and Windows computers on a local network with automatic discovery.

Instead of manually executing commands or blocks of commands at a time I have provided a script that perform each step for you,
and stop if any commands fail to execute with some assistance on how to resolve the problem.

## 1. Setup Samba

Open a terminal and run the following commands:

```bash
# Make the script executable if not already
chmod +x bin/setup-samba.sh

# Run the setup script
sudo ./bin/setup-samba.sh
```

You will be prompted to set a Samba password for your user account. This is different from your system password and will be used when accessing shared folders from Windows.

### 2. Set a Samba Password

If you need to change or set your Samba password later, use:

```bash
sudo smbpasswd -a $(whoami)
```

### 3. Accessing from Windows

1. Open File Explorer
2. Click on "Network" in the left sidebar
3. Your Ubuntu computer should appear in the list of network devices
4. Double-click on your Ubuntu computer
5. When prompted, enter your Ubuntu username and the Samba password you set

### 4. Troubleshooting

#### If the Ubuntu computer doesn't appear in Network:
1. Ensure both computers are on the same network
2. Restart the Windows computer
3. On Windows, open File Explorer and type `\\[ubuntu-computer-name]` in the address bar

#### If you can't access the share:
1. Check if the firewall is allowing Samba traffic:
   ```bash
   sudo ufw status
   ```
2. Verify Samba services are running:
   ```bash
   sudo systemctl status smbd nmbd
   ```

## Advanced Configuration

The setup script creates a shared folder at `~/shared` with full read/write access. To add more shared folders:

1. Edit the Samba configuration:
   ```bash
   sudo nano /etc/samba/smb.conf
   ```

2. Add a new section for each share:
   ```ini
   [ShareName]
      comment = Description of the share
      path = /path/to/directory
      browseable = yes
      read only = no
      create mask = 0755
      directory mask = 0755
   ```

3. Restart Samba:
   ```bash
   sudo systemctl restart smbd nmbd
   ```

## Security Notes

- Only share directories that need to be accessed by other computers
- Use strong Samba passwords
- Regularly update your system to receive security updates
- Consider setting up user-specific shares if you need to restrict access
