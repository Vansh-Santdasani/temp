#!/usr/bin/env bash
# AegisOS — manual installer. Bypasses Calamares + rsync entirely.
# Uses unsquashfs (the same tool the live session uses to boot from squashfs)
# to extract our rootfs directly onto a fresh partition.
#
# Run with:  sudo bash /tmp/manual-install.sh
#
# What it does (same as Calamares, minus the rsync bug):
#   1. Auto-detect target disk (or asks if multiple)
#   2. Wipe + partition (GPT layout, auto-handles UEFI vs BIOS)
#   3. Format root as ext4, EFI as fat32 (if UEFI)
#   4. unsquashfs /cdrom/casper/minimal.standard.live.squashfs → target
#   5. Bind-mount /dev /proc /sys, chroot in
#   6. Install grub (grub-efi-amd64 for UEFI, grub-pc for BIOS)
#   7. Generate /etc/fstab with real UUIDs
#   8. Remove the live "ubuntu" user, prompt to create a real user
#   9. Set hostname
#  10. Unmount cleanly

set -euo pipefail

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }
header() { printf '\n\033[1;36m══ %s ══\033[0m\n' "$*"; }
die()    { red "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"

header "AegisOS manual installer"
echo "This is a Calamares replacement. Does the same job, just without rsync."
echo

# ── 1. Detect boot mode ────────────────────────────────────────────────────
if [[ -d /sys/firmware/efi/efivars ]]; then
    BOOT_MODE=UEFI
else
    BOOT_MODE=BIOS
fi
blue "Boot mode detected: $BOOT_MODE"

# ── 2. Locate squashfs ─────────────────────────────────────────────────────
SQ=""
for cand in \
    /cdrom/casper/minimal.standard.live.squashfs \
    /cdrom/casper/filesystem.squashfs \
    /run/live/medium/casper/minimal.standard.live.squashfs \
    /run/live/medium/casper/filesystem.squashfs ; do
    if [[ -f "$cand" ]]; then SQ="$cand"; break; fi
done
[[ -n "$SQ" ]] || die "Could not find live squashfs"
blue "Source squashfs: $SQ ($(du -h "$SQ" | cut -f1))"

# ── 3. Pick target disk ────────────────────────────────────────────────────
header "Target disk selection"
echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E 'disk$' | sed 's/^/  /'
echo

# Auto-detect: any disk that is NOT the live USB/CD and NOT mounted
candidates=()
while read -r dev size type; do
    [[ "$type" == "disk" ]] || continue
    # Skip the live medium
    if mount | grep -qE "^/dev/${dev}[0-9p]* "; then
        if mount | grep "/dev/${dev}" | grep -qE '/cdrom|/run/live'; then
            continue  # this is the live medium
        fi
    fi
    candidates+=("/dev/$dev")
done < <(lsblk -d -n -o NAME,SIZE,TYPE)

if [[ ${#candidates[@]} -eq 0 ]]; then
    die "No installable disks found."
elif [[ ${#candidates[@]} -eq 1 ]]; then
    TARGET="${candidates[0]}"
    yellow "Auto-detected target: $TARGET"
else
    echo "Multiple candidate disks. Pick one:"
    for i in "${!candidates[@]}"; do
        info=$(lsblk -d -n -o SIZE,MODEL "${candidates[$i]}" 2>/dev/null)
        echo "  [$((i+1))] ${candidates[$i]}  $info"
    done
    read -rp "Choice [1-${#candidates[@]}]: " choice
    TARGET="${candidates[$((choice-1))]}"
fi

target_size=$(lsblk -b -d -n -o SIZE "$TARGET")
target_gb=$((target_size / 1024 / 1024 / 1024))
blue "Target: $TARGET ($target_gb GB)"

if (( target_gb < 12 )); then
    die "Disk too small ($target_gb GB). Need at least 12 GB."
fi

echo
red "═══════════════════════════════════════════════════════════════"
red "  WARNING: $TARGET will be COMPLETELY ERASED."
red "  All data on it will be lost."
red "═══════════════════════════════════════════════════════════════"
read -rp "Type EXACTLY 'wipe $TARGET' to proceed: " confirm
[[ "$confirm" == "wipe $TARGET" ]] || die "Aborted."

# ── 4. Partition ───────────────────────────────────────────────────────────
header "Partitioning $TARGET"

# Wipe any existing filesystem signatures
wipefs -af "$TARGET"
sgdisk --zap-all "$TARGET" 2>/dev/null || true
sync

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    # GPT: ESP (512 MB) + root (rest)
    parted -s "$TARGET" mklabel gpt
    parted -s "$TARGET" mkpart ESP fat32 1MiB 513MiB
    parted -s "$TARGET" set 1 esp on
    parted -s "$TARGET" mkpart root ext4 513MiB 100%
    sync; partprobe "$TARGET"; sleep 2
    # Handle nvme-style partition names (nvme0n1p1) vs sda1
    if [[ "$TARGET" =~ nvme ]]; then
        EFI_PART="${TARGET}p1"; ROOT_PART="${TARGET}p2"
    else
        EFI_PART="${TARGET}1";  ROOT_PART="${TARGET}2"
    fi
    blue "ESP:  $EFI_PART"
    blue "root: $ROOT_PART"
    mkfs.vfat -F32 "$EFI_PART"
else
    # GPT with BIOS boot partition (1 MB) + root (rest)
    parted -s "$TARGET" mklabel gpt
    parted -s "$TARGET" mkpart bios 1MiB 2MiB
    parted -s "$TARGET" set 1 bios_grub on
    parted -s "$TARGET" mkpart root ext4 2MiB 100%
    sync; partprobe "$TARGET"; sleep 2
    if [[ "$TARGET" =~ nvme ]]; then
        ROOT_PART="${TARGET}p2"
    else
        ROOT_PART="${TARGET}2"
    fi
    blue "BIOS boot part: ${TARGET}1"
    blue "root: $ROOT_PART"
fi

mkfs.ext4 -F -L AegisOS "$ROOT_PART"

# ── 5. Mount + extract ─────────────────────────────────────────────────────
header "Extracting rootfs (5-10 minutes)"
mkdir -p /mnt/aegisos
mount "$ROOT_PART" /mnt/aegisos

# Use unsquashfs — directly extracts to target. No rsync involved.
unsquashfs -f -d /mnt/aegisos "$SQ"
green "Rootfs extracted to $TARGET"

# Mount ESP if UEFI
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    mkdir -p /mnt/aegisos/boot/efi
    mount "$EFI_PART" /mnt/aegisos/boot/efi
fi

# ── 6. Generate /etc/fstab ─────────────────────────────────────────────────
header "Generating /etc/fstab"
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
{
    echo "# Generated by AegisOS manual installer"
    echo "UUID=$ROOT_UUID  /            ext4  errors=remount-ro  0 1"
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
        echo "UUID=$EFI_UUID  /boot/efi    vfat  umask=0077         0 1"
    fi
    echo "tmpfs           /tmp         tmpfs  defaults,nosuid    0 0"
} > /mnt/aegisos/etc/fstab
cat /mnt/aegisos/etc/fstab

# ── 7. Bind-mount + chroot ─────────────────────────────────────────────────
header "Setting up chroot for grub install"
for d in dev proc sys run; do
    mount --bind /$d /mnt/aegisos/$d
done
mount --bind /dev/pts /mnt/aegisos/dev/pts
mount --bind /sys/firmware/efi/efivars /mnt/aegisos/sys/firmware/efi/efivars 2>/dev/null || true

# Copy DNS so apt works inside chroot
cp /etc/resolv.conf /mnt/aegisos/etc/resolv.conf 2>/dev/null || true

# ── 8. User account + hostname ─────────────────────────────────────────────
header "User account setup"
read -rp "Username for the new system: " NEWUSER
[[ -n "$NEWUSER" ]] || die "Username required"
read -rp "Full name (optional): " NEWFULL
read -rp "Hostname [aegisos]: " NEWHOST
NEWHOST="${NEWHOST:-aegisos}"

echo
echo "Set password for '$NEWUSER':"
chroot /mnt/aegisos /bin/bash -c "
    # Remove the live ubuntu user (we keep aegis user from chroot install)
    deluser --remove-home ubuntu 2>/dev/null || true

    # Create the real user if not 'aegis' (which already exists from build)
    if ! id '$NEWUSER' >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev '$NEWUSER'
        [[ -n '$NEWFULL' ]] && chfn -f '$NEWFULL' '$NEWUSER'
    else
        usermod -aG sudo,audio,video,plugdev,netdev '$NEWUSER'
    fi
"
chroot /mnt/aegisos passwd "$NEWUSER"

# Hostname
echo "$NEWHOST" > /mnt/aegisos/etc/hostname
{
    echo "127.0.0.1   localhost"
    echo "127.0.1.1   $NEWHOST"
    echo "::1         localhost ip6-localhost ip6-loopback"
} > /mnt/aegisos/etc/hosts

# Auto-login override: lightdm should auto-log THE NEW USER, not 'aegis'
mkdir -p /mnt/aegisos/etc/lightdm/lightdm.conf.d
cat > /mnt/aegisos/etc/lightdm/lightdm.conf.d/20-installed.conf <<EOF
[Seat:*]
autologin-user=$NEWUSER
autologin-user-timeout=0
user-session=aegis-fallback
EOF

# ── 9. Install grub ────────────────────────────────────────────────────────
header "Installing GRUB ($BOOT_MODE mode)"
chroot /mnt/aegisos /bin/bash -c "
    set -e
    if [[ '$BOOT_MODE' == 'UEFI' ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y grub-efi-amd64 grub-efi-amd64-signed shim-signed 2>&1 | tail -3
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=AegisOS --recheck
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y grub-pc 2>&1 | tail -3
        grub-install --target=i386-pc --recheck '$TARGET'
    fi
    update-grub
"

# ── 10. Update initramfs (gets our plymouth theme + new fstab) ─────────────
chroot /mnt/aegisos /bin/bash -c "
    update-initramfs -u -k all 2>&1 | tail -3 || true
"

# ── 11. Unmount ────────────────────────────────────────────────────────────
header "Cleaning up"
umount /mnt/aegisos/sys/firmware/efi/efivars 2>/dev/null || true
umount /mnt/aegisos/dev/pts
for d in dev proc sys run; do
    umount /mnt/aegisos/$d || umount -lf /mnt/aegisos/$d
done
[[ "$BOOT_MODE" == "UEFI" ]] && umount /mnt/aegisos/boot/efi
umount /mnt/aegisos
sync

green ""
green "═══════════════════════════════════════════════════════════════"
green "  AegisOS installed successfully to $TARGET"
green "  User: $NEWUSER"
green "  Hostname: $NEWHOST"
green "═══════════════════════════════════════════════════════════════"
echo
yellow "To reboot:"
yellow "  1. Eject the live ISO (VMware Fusion: Virtual Machine → CD/DVD → Disconnect)"
yellow "  2. Run:  sudo reboot"
echo
