# MergerFS — Union Filesystem Setup on Ubuntu

MergerFS is a FUSE-based union filesystem that combines multiple drives or directories into a single mount point. Files on each underlying drive remain independent — MergerFS just presents them together transparently. It is commonly paired with SnapRAID for a flexible, expandable storage pool.

## How It Works

- Each drive is mounted separately (e.g. `/mnt/drive00`, `/mnt/drive01`)
- MergerFS merges them into a single directory (e.g. `/array`)
- Reads come from whichever drive holds the file
- Writes go to whichever drive is selected by the configured creation policy

## Installation

```bash
sudo apt install mergerfs
```

Verify the install:

```bash
mergerfs --version
```

## Configuration in /etc/fstab

MergerFS is configured via `/etc/fstab`. The general format is:

```
<drive1>:<drive2>:<driveN>  <mountpoint>  mergerfs  <options>  0  0
```

### Current Setup

The drives are first mounted individually, then merged:

```fstab
# Individual drives
/dev/disk/by-uuid/65cc0491-bff8-4961-bfb7-de7fa1251c91  /mnt/drive00  auto  nosuid,nodev,nofail,x-gvfs-show  0  0
/dev/disk/by-uuid/3548fcd1-d616-48e4-9eaa-66cbfeb5a59b  /mnt/drive01  auto  nosuid,nodev,nofail,x-gvfs-show  0  0

# MergerFS pool
/mnt/drive00:/mnt/drive01  /array  mergerfs  cache.files=off,category.create=pfrd,func.getattr=newest,dropcacheonclose=false,allow_other  0  0
```

### Key Options Explained

| Option | Description |
|--------|-------------|
| `cache.files=off` | Disables file caching — safest option, especially when files are also accessed directly on member drives |
| `category.create=pfrd` | Write new files to the drive with the most free space (Per-Filesystem Remaining space, Disk) |
| `func.getattr=newest` | When a path exists on multiple drives, return the metadata from the newest version |
| `dropcacheonclose=false` | Do not drop the page cache when a file is closed |
| `allow_other` | Allow users other than root to access the mount |
| `nofail` | (on individual drives) Boot succeeds even if the drive is missing |

## Adding a Drive to the Pool

### 1. Physically connect the drive and verify detection

Check that every drive has a unique UUID — if two drives share a UUID or a drive is completely missing, you likely have a SATA data cable issue (two drives sharing a controller channel, or a loose cable):

```bash
sudo blkid | grep sd
```

Each existing drive should show its label, UUID and filesystem type. The new blank drive will not appear here at all — that's expected.

Then confirm mount points and spot the new drive (it will have no FSTYPE or UUID):

```bash
lsblk -e 7 -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT
```

The new unformatted drive will appear as a `sdX` entry with blank FSTYPE and UUID. If two drives show identical UUIDs, **shut down and reseat the SATA data cables** before continuing.

### 2. Format as XFS

MergerFS does not require a partition table — you can format the whole disk directly:

```bash
sudo mkfs.xfs /dev/sdX
```

If your other drives were partitioned first (e.g. by GNOME Disks, which always creates a partition table), you may want to match that for consistency. This is cosmetic only and has no practical effect:

```bash
sudo parted /dev/sdX --script mklabel gpt mkpart primary 0% 100%
sudo mkfs.xfs /dev/sdX1
```

In the partitioned case, substitute `/dev/sdX1` wherever `/dev/sdX` appears in the steps below.

### 3. Get its UUID

```bash
sudo blkid /dev/sdX
```

### 4. Create a mount point

```bash
sudo mkdir /mnt/drive02
```

### 5. Add the drive to `/etc/fstab`

```fstab
/dev/disk/by-uuid/<new-uuid>  /mnt/drive02  auto  nosuid,nodev,nofail,x-gvfs-show  0  0
```

### 6. Update the MergerFS line in `/etc/fstab`

```fstab
/mnt/drive00:/mnt/drive01:/mnt/drive02  /array  mergerfs  cache.files=off,category.create=pfrd,func.getattr=newest,dropcacheonclose=false,allow_other  0  0
```

### 7. Mount the new drive and add it to the live pool

```bash
sudo systemctl daemon-reload
sudo mount /mnt/drive02
sudo attr -s mergerfs.srcmounts -V '+/mnt/drive02' /array
```

The `attr` command adds the drive to the running MergerFS pool instantly without unmounting `/array` (which will fail if anything has the mount open).

### 8. Verify

   ```bash
   df -h /array /mnt/drive00 /mnt/drive01 /mnt/drive02
   ```

> No files need to be moved. MergerFS will immediately see the new drive and new writes will be distributed to it according to the creation policy.

## Removing a Drive from the Pool

> **Important:** MergerFS does not mirror data. Each file lives on exactly one underlying drive. You must move files off a drive before removing it from the pool or they will become inaccessible.

1. **Move all files off the drive** to the rest of the pool:

   ```bash
   sudo rsync -av /mnt/drive01/ /array/ --ignore-existing
   ```

   Then verify nothing remains:

   ```bash
   ls /mnt/drive01
   ```

2. **Remove the drive from the MergerFS line** in `/etc/fstab`:

   ```fstab
   /mnt/drive00  /array  mergerfs  cache.files=off,category.create=pfrd,func.getattr=newest,dropcacheonclose=false,allow_other  0  0
   ```

3. **Also remove or comment out** the individual drive's fstab entry.

4. **Reload the mount**:

   ```bash
   sudo umount /array
   sudo umount /mnt/drive01
   sudo mount /array
   ```

5. **Verify**:

   ```bash
   mount | grep mergerfs
   df -h /array
   ```

## Useful Commands

### Check what drives are in the pool

```bash
mount | grep mergerfs
```

### See free space on each member drive

```bash
df -h /mnt/drive00 /mnt/drive01
```

### Check which drive a specific file is on

```bash
attr -g mergerfs.fullpath /array/somefile
```

### Remount the pool after fstab changes (without reboot)

```bash
sudo umount /array && sudo mount /array
```

### Live-add a drive to the pool without rebooting

MergerFS supports adding paths on the fly via xattr:

```bash
sudo attr -s mergerfs.srcmounts -V '+/mnt/drive02' /array
```

This is temporary — update `/etc/fstab` to make it permanent.

## Troubleshooting

**Pool won't mount at boot:**
- Check each member drive mounts successfully: `sudo mount /mnt/drive00`
- `nofail` on member drives prevents boot failure if a drive is missing, but MergerFS itself will fail if its listed paths don't exist

**Files missing from `/array`:**
- The file may be on a drive that failed to mount. Check `df -h` and `mount | grep drive`

**Writes going to the wrong drive:**
- The `category.create=pfrd` policy selects the drive with the most free space. Use `df -h` to check available space on each member drive
