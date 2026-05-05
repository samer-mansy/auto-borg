# BorgBackup-Automation
The system is designed to be **set-and-forget**. Once configured, backups run automatically daily at 2AM, prune old archives, verify integrity, and log everything.


# BorgBackup Centralized System — Complete Guide

## Quick Start

### 1. Server Setup (Run Once on Dell T320)
```bash
sudo bash borg-server-setup.sh
```
Creates `/backup/{clientname}` structure, borg user, SSH hardening, monitoring.

### 2. Client Setup (Run on Each Machine to Backup)
```bash
sudo bash borg-client-setup.sh
```
Generates SSH key, initializes encrypted repo, installs backup/restore scripts, sets up daily timer.

### 3. Server-Side Listing (Check All Backups)
```bash
# Option 1: If all clients use same passphrase
BORG_PASSPHRASE='your-shared-pass' bash borg-list-all.sh

# Option 2: Create /etc/borg-passphrases.conf with:
reee_PASSPHRASE="pass1"
Sam_C_PASSPHRASE="pass2"
# Then run:
bash borg-list-all.sh
```

---

## Full System Backup (`/` Backup)

### Method 1: Edit Existing Scripts (Recommended)

**On the client**, edit `/etc/borg-client.conf`:
```bash
# Change from:
BACKUP_PATHS="/etc /home /root /var/www /opt"

# To:
BACKUP_PATHS="/"
```

The borg-backup.sh script already has proper excludes:
- `/dev`, `/proc`, `/sys`, `/run`, `/tmp` (virtual filesystems)
- `/mnt`, `/media`, `/lost+found` (mount points)
- `*/node_modules`, `*/.venv` (bloat)
- `/swapfile` (unnecessary)

### Method 2: One-Off Full System Backup

Run this directly on any client:
```bash
#!/bin/bash
source /etc/borg-client.conf
export BORG_PASSPHRASE=$(cat /root/.borg-passphrase)
export BORG_RSH="ssh -i $BORG_KEY_PATH -p $BORG_SERVER_PORT -o BatchMode=yes -o IdentitiesOnly=yes"

borg create \
  --stats \
  --compression zstd,6 \
  --one-file-system \
  --exclude-caches \
  --exclude '/dev' \
  --exclude '/proc' \
  --exclude '/sys' \
  --exclude '/run' \
  --exclude '/tmp' \
  --exclude '/mnt' \
  --exclude '/media' \
  --exclude '/lost+found' \
  --exclude '/var/tmp' \
  --exclude '*/node_modules' \
  --exclude '*/.venv' \
  --exclude '/swapfile' \
  "${BORG_REMOTE_REPO}::$(hostname)-full-$(date +%Y%m%d-%H%M)" \
  /

unset BORG_PASSPHRASE
```

### Critical Flags Explained

| Flag | Purpose |
|---|---|
| `--one-file-system` | **CRITICAL** — Don't cross filesystem boundaries. Prevents backing up `/proc`, `/sys`, mounted NFS, etc. |
| `--exclude-caches` | Skip directories with `CACHEDIR.TAG` |
| `--compression zstd,6` | Fast compression (level 6 = good balance) |
| `--exclude '/dev'` | Skip device files (regenerated at boot) |

**Without `--one-file-system`**, borg would try to backup virtual filesystems like `/proc` which:
- Are infinite (cause backup to hang)
- Contain runtime kernel data (useless to restore)
- Can't be backed up anyway

======================================================
### Our Scripts

**Pros:**
- ✅ Configurable via `/etc/borg-client.conf`
- ✅ Auto-detects borg version (handles 1.x vs 2.x)
- ✅ Database dumps (MySQL/PostgreSQL)
- ✅ Skips missing paths gracefully
- ✅ `StrictHostKeyChecking=accept-new` (works on first run)
- ✅ Embedded in client-setup (single file distribution)
- ✅ Restore script included
- ✅ Better error handling

**Cons:**
- ❌ More complex
- ❌ Longer code
======================================================

## System Architecture Overview

┌─────────────────────────────────────────────────────────────┐
│ Dell T320 Backup Server (borg-server)                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  /backup/                                                    │
│    ├── client1/  (encrypted repo, append-only)              │
│    ├── client2/  (encrypted repo, append-only)              │
│    └── client3/  (encrypted repo, append-only)              │
│                                                              │
│  SSH: borg user (key-only, forced command per client)       │
│  Cron: Daily monitor (7AM), Weekly compact (Sun 3AM)        │
│  Optional: borg-ui web interface on port 8080               │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ SSH + borg protocol
                              │ (encrypted, deduplicated)
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
    ┌────▼─────┐        ┌────▼─────┐        ┌────▼─────┐
    │ client1  │        │ client2  │        │ client3  │
    ├──────────┤        ├──────────┤        ├──────────┤
    │ Systemd  │        │ Systemd  │        │ Systemd  │
    │ Timer    │        │ Timer    │        │ Timer    │
    │ 2AM      │        │ 2AM      │        │ 2AM      │
    │ daily    │        │ daily    │        │ daily    │
    └──────────┘        └──────────┘        └──────────┘


    


## Key Files & Locations

### Server (Dell T320)
| File | Purpose |
|---|---|
| `/etc/borg-server.conf` | Server config (backup root, borg user) |
| `/backup/{client}/` | Per-client encrypted repos |
| `/home/borg/.ssh/authorized_keys` | Client SSH keys (one per client, command-restricted) |
| `/usr/local/bin/register-client.sh` | Register new clients |
| `/usr/local/bin/borg-monitor.sh` | Daily health check (cron 7AM) |
| `/usr/local/bin/borg-compact-all.sh` | Weekly compact (cron Sun 3AM) |
| `/etc/borg-passphrases.conf` | **(Optional)** Passphrases for server-side access |

### Client (Each Machine)
| File | Purpose |
|---|---|
| `/etc/borg-client.conf` | Backup config (paths, schedule, server IP) |
| `/root/.borg-passphrase` | Repo encryption passphrase |
| `/root/.ssh/borg_client` | SSH private key for borg server |
| `/root/borg-repokey-{hostname}.key` | **CRITICAL** Exported repo key (back this up offline!) |
| `/usr/local/bin/borg-backup.sh` | Main backup script (runs via systemd timer) |
| `/usr/local/bin/borg-restore.sh` | Interactive restore tool |
| `/etc/systemd/system/borg-backup.timer` | Systemd timer (default: daily 2AM) |
| `/var/log/borg/backup-YYYYMMDD.log` | Daily backup logs |



======================================================

## Common Scenarios & Edits

### Scenario 1: Change Backup Schedule
```bash
# On client, edit the timer:
systemctl edit borg-backup.timer

# Add under [Timer]:
[Timer]
OnCalendar=*-*-* 03:00:00  # 3 AM daily
RandomizedDelaySec=30min

# Reload and restart
systemctl daemon-reload
systemctl restart borg-backup.timer
```

### Scenario 2: Add Database Dumps
```bash
# On client, edit /etc/borg-client.conf:
DB_TYPE=mysql  # or postgresql
DB_PASS="your-mysql-root-password"
```

Restart the backup service once to pick up the new config.

### Scenario 3: Backup Different Paths Per Client
```bash
# On web server:
BACKUP_PATHS="/etc /home /var/www /var/log/nginx"

# On database server:
BACKUP_PATHS="/etc /home /var/lib/mysql"

# On full system:
BACKUP_PATHS="/"
```

### Scenario 4: Change Retention Policy
Edit `/usr/local/bin/borg-backup.sh` on the client, find the prune section:
```bash
borg prune \
  --keep-daily   30   # Keep 30 days instead of 7
  --keep-weekly  8    # Keep 8 weeks instead of 4
  --keep-monthly 12   # Keep 12 months instead of 6
  --keep-yearly  5    # Keep 5 years instead of 2
```

### Scenario 5: Exclude Additional Paths
Edit `/usr/local/bin/borg-backup.sh`, add to the exclude list:
```bash
--exclude '*/cache' \
--exclude '/var/cache' \
--exclude '*.log.gz' \
```

### Scenario 6: Enable Email Alerts
Edit `/etc/borg-client.conf`:
```bash
ALERT_EMAIL="admin@example.com"
```

Install mailutils: `apt-get install mailutils`

### Scenario 7: Server-Side Access to Repos
Create `/etc/borg-passphrases.conf` on the server:
```bash
# Replace hyphens with underscores in client names
web_server_01_PASSPHRASE="passphrase1"
db_server_PASSPHRASE="passphrase2"
app_server_PASSPHRASE="passphrase3"
```

Then `bash borg-list-all.sh` works without entering passphrases.

======================================================

## Security Features Built-In

1. **Encryption**: `repokey-blake2` — data encrypted before leaving client
2. **SSH Key-Only**: Password auth disabled for borg user
3. **Command Restriction**: Each client key can only access its own repo
4. **Append-Only**: Clients can't delete archives (ransomware protection)
5. **Server-Side Compact**: Run weekly from server to reclaim space
6. **Locked Root**: Root password locked on server
7. **Firewall**: UFW restricts SSH access
8. **Audit Logging**: auditd tracks all SSH/sudo/file changes

======================================================

## Disaster Recovery — Full Restore

### Bare Metal Recovery (Restore Entire System)

**On a live USB/rescue system:**
```bash
# 1. Partition and format new disk
fdisk /dev/sda
mkfs.ext4 /dev/sda1
mount /dev/sda1 /mnt

# 2. Install borg on rescue system
apt-get install borgbackup

# 3. Copy SSH key and passphrase from backup location
# (you backed up /root/borg-repokey-*.key and /root/.borg-passphrase, right?)

# 4. Restore
export BORG_PASSPHRASE="your-passphrase"
export BORG_RSH="ssh -i /path/to/borg_client"

cd /mnt
borg extract ssh://borg@server-ip/backup/client-name::latest-archive

# 5. Reinstall bootloader
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
chroot /mnt
grub-install /dev/sda
update-grub

# 6. Update /etc/fstab with new UUIDs
blkid
nano /etc/fstab

# 7. Reboot
exit
reboot
```

======================================================

## Performance Tuning

### Speed Up Backups
1. **Use faster compression**: Change `zstd,6` → `lz4` in borg-backup.sh
2. **Exclude more**: Add `--exclude '*.mp4'` for media files
3. **Increase checkpoint interval**: Add `--checkpoint-interval 600` (10 min)

### Reduce Disk Usage
1. **Aggressive prune**: Reduce retention in `borg prune` section
2. **Higher compression**: Change `zstd,6` → `zstd,9` (slower but smaller)
3. **Run compact more often**: Change server cron from weekly to daily

### Network-Constrained Environments
Add to BORG_RSH:
```bash
-o "Compression=yes" -o "CompressionLevel=9"

======================================================


## Troubleshooting

### "Repository does not exist"
```bash
# On client:
borg init --encryption=repokey-blake2 ssh://borg@server/backup/$(hostname)
```

### "Connection refused"
```bash
# Test SSH manually:
ssh -i /root/.ssh/borg_client -p 22 borg@server-ip

# If fails, check firewall on server:
ufw status
```

### "Permission denied (publickey)"
```bash
# On server, re-register the client:
sudo register-client.sh client-name 'ssh-ed25519 AAA...'

# Verify authorized_keys:
cat /home/borg/.ssh/authorized_keys
```

### Backup Hangs / Takes Forever
```bash
# Check what it's doing:
ps aux | grep borg
strace -p <borg-pid>

# Common cause: backing up /proc or /sys
# Fix: Add --one-file-system flag


### "Borg exited with rc=2"
Check `/var/log/borg/backup-YYYYMMDD.log` for details. Common causes:
- Prune flag incompatibility (borg 1.x vs 2.x)
- Compact on append-only repo
- Passphrase mismatch


======================================================

## Summary

✅ **Use our scripts** for production — they handle all edge cases  
✅ **Use `/` for full backups** — just edit `/etc/borg-client.conf`  
✅ **Always use `--one-file-system`** when backing up `/`  
✅ **Back up these files offline:**  
   - `/root/borg-repokey-*.key`  
   - `/root/.borg-passphrase`  
✅ **Server-side listing needs passphrases** — create `/etc/borg-passphrases.conf`  
