#!/usr/bin/env bash
# AegisOS — fix-boot.sh v2
# Fixes v1 bugs: uses `lsblk -lnpo` so partition names don't have tree-drawing
# chars like "├─sda1"; cleans up leftover mounts from previous failed run;
# trap unmounts on any exit; verifies each mount before continuing.

set -euo pipefail

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }
header() { printf '\n\033[1;36m══ %s ══\033[0m\n' "$*"; }
die()    { red "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"
[[ -d /cdrom/casper ]] || die "Must run from AegisOS live session (boot from ISO first)."

MOUNT_DIR=/mnt/aegisos

cleanup() {
    set +e
    mountpoint -q "$MOUNT_DIR/sys/firmware/efi/efivars" && umount "$MOUNT_DIR/sys/firmware/efi/efivars" 2>/dev/null
    mountpoint -q "$MOUNT_DIR/dev/pts" && umount "$MOUNT_DIR/dev/pts" 2>/dev/null
    for d in dev proc sys run; do
        mountpoint -q "$MOUNT_DIR/$d" && { umount "$MOUNT_DIR/$d" 2>/dev/null || umount -lf "$MOUNT_DIR/$d" 2>/dev/null; }
    done
    mountpoint -q "$MOUNT_DIR/boot/efi" && umount "$MOUNT_DIR/boot/efi" 2>/dev/null
    mountpoint -q "$MOUNT_DIR" && umount "$MOUNT_DIR" 2>/dev/null
}
trap cleanup EXIT

cleanup
sleep 1

header "Finding installed AegisOS partition"

ROOT_PART="$(blkid -L AegisOS 2>/dev/null || true)"
[[ -n "$ROOT_PART" ]] || die "No partition labeled 'AegisOS' found. Did manual-install.sh finish?"
blue "Root partition: $ROOT_PART"

PARENT_DISK="$(lsblk -no PKNAME "$ROOT_PART" | head -1)"
[[ -n "$PARENT_DISK" ]] || die "Could not find parent disk of $ROOT_PART"
PARENT_DISK="/dev/$PARENT_DISK"
blue "Parent disk:    $PARENT_DISK"

# Find EFI partition using lsblk -l (list mode = NO tree-drawing chars)
EFI_PART=""
while read -r part fstype rest; do
    [[ "$part" == "$PARENT_DISK" ]] && continue
    if [[ "$fstype" == "vfat" ]]; then
        EFI_PART="$part"
        break
    fi
done < <(lsblk -lnpo NAME,FSTYPE "$PARENT_DISK")

if [[ -n "$EFI_PART" ]]; then
    blue "EFI partition:  $EFI_PART"
    BOOT_MODE=UEFI
else
    blue "No vfat partition on $PARENT_DISK → BIOS install"
    BOOT_MODE=BIOS
fi

if [[ "$BOOT_MODE" == "UEFI" ]] && [[ ! -b "$EFI_PART" ]]; then
    die "EFI device $EFI_PART doesn't exist. Run: lsblk -lnpo NAME,FSTYPE $PARENT_DISK"
fi

header "Mounting installed system"
mkdir -p "$MOUNT_DIR"
mount "$ROOT_PART" "$MOUNT_DIR"
mountpoint -q "$MOUNT_DIR" || die "Root mount failed"
green "✓ $ROOT_PART → $MOUNT_DIR"

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    mkdir -p "$MOUNT_DIR/boot/efi"
    mount "$EFI_PART" "$MOUNT_DIR/boot/efi"
    mountpoint -q "$MOUNT_DIR/boot/efi" || die "ESP mount failed"
    green "✓ $EFI_PART → $MOUNT_DIR/boot/efi"
    echo
    echo "Contents of ESP before fix:"
    find "$MOUNT_DIR/boot/efi/EFI" -maxdepth 2 2>/dev/null | sed 's|^|  |' || true
fi

for d in dev proc sys run; do
    mount --bind "/$d" "$MOUNT_DIR/$d"
done
mount --bind /dev/pts "$MOUNT_DIR/dev/pts"
[[ -d /sys/firmware/efi/efivars ]] && \
    mount --bind /sys/firmware/efi/efivars "$MOUNT_DIR/sys/firmware/efi/efivars" 2>/dev/null || true
cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf" 2>/dev/null || true

header "Reinstalling GRUB ($BOOT_MODE)"

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    chroot "$MOUNT_DIR" /bin/bash -e -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --reinstall grub-efi-amd64 grub-efi-amd64-bin efibootmgr 2>&1 | tail -3 || true
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=AegisOS --recheck
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck
        update-grub
    '
    green "✓ GRUB written to BOTH /EFI/AegisOS/ AND /EFI/BOOT/"
    echo
    echo "Contents of ESP after fix:"
    find "$MOUNT_DIR/boot/efi/EFI" -maxdepth 2 \( -type d -o -name '*.EFI' -o -name '*.efi' \) 2>/dev/null | sed 's|^|  |'

    if [[ -f "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI" ]]; then
        size=$(stat -c%s "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI")
        green "✓ /EFI/BOOT/BOOTX64.EFI exists ($size bytes)"
    else
        yellow "Fallback path missing — copying manually"
        mkdir -p "$MOUNT_DIR/boot/efi/EFI/BOOT"
        cp "$MOUNT_DIR/boot/efi/EFI/AegisOS/grubx64.efi" "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI"
        green "✓ Copied AegisOS/grubx64.efi → BOOT/BOOTX64.EFI"
    fi
else
    chroot "$MOUNT_DIR" /bin/bash -e -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --reinstall grub-pc 2>&1 | tail -3 || true
        grub-install --target=i386-pc --recheck '$PARENT_DISK'
        update-grub
    "
    green "✓ GRUB written to MBR of $PARENT_DISK"
fi

header "Verifying grub.cfg"
if [[ -f "$MOUNT_DIR/boot/grub/grub.cfg" ]]; then
    count=$(grep -c '^menuentry ' "$MOUNT_DIR/boot/grub/grub.cfg" || echo 0)
    blue "Menu entries: $count"
    grep '^menuentry ' "$MOUNT_DIR/boot/grub/grub.cfg" | head -3 | sed 's|^|  |'
else
    red "✗ /boot/grub/grub.cfg missing!"
fi

green ""
green "════════════════════════════════════════════════════════════════"
green "  GRUB repair complete."
green "  Now:"
green "    1. VMware Fusion: Virtual Machine → CD/DVD → DISCONNECT"
green "    2. VMware Fusion: Virtual Machine → SHUT DOWN (not restart)"
green "    3. Start the VM again. AegisOS should boot from disk."
green "════════════════════════════════════════════════════════════════"
