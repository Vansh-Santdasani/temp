#!/usr/bin/env bash
# AegisOS — fix unbootable install (UEFI fallback path repair).
#
# The manual installer used grub-install --bootloader-id=AegisOS which puts
# the bootloader at /EFI/AegisOS/grubx64.efi. VMware Fusion's UEFI firmware
# doesn't reliably honor NVRAM entries and falls back to looking for
# /EFI/BOOT/BOOTX64.EFI ("removable media" path). When that path is empty,
# you get exactly what you described: black screen with blinking logo, then
# back to the boot manager.
#
# This script: boots back into the live session, mounts your installed disk,
# chroots in, and re-runs grub-install with --removable AND keeps the
# AegisOS entry too. Belt and suspenders.
#
# How to use:
#   1. In VMware Fusion: Virtual Machine → CD/DVD → connect the AegisOS ISO
#   2. Restart, boot the live "Try AegisOS" entry
#   3. From the live desktop, drag this file into the VM (same as before)
#   4. Open LXTerminal and run:  sudo bash /tmp/fix-boot.sh

set -euo pipefail

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }
header() { printf '\n\033[1;36m══ %s ══\033[0m\n' "$*"; }
die()    { red "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"

# Verify we're in the LIVE session, not the broken installed system
if [[ ! -d /cdrom/casper ]]; then
    die "This script must run from the AegisOS LIVE session (booted from ISO).
You're currently in something else. Connect the ISO in VMware Fusion's
CD/DVD menu, restart, and pick 'Try AegisOS' at the GRUB menu."
fi

header "Finding installed AegisOS partition"

# The installed AegisOS root has filesystem label "AegisOS" (we set it with
# mkfs.ext4 -L AegisOS in manual-install.sh)
ROOT_PART=$(blkid -L AegisOS 2>/dev/null || true)

if [[ -z "$ROOT_PART" ]]; then
    yellow "No partition labeled AegisOS found. Looking for any ext4 partition..."
    # Fallback: largest ext4 partition that's not the live medium
    while read -r part fstype; do
        [[ "$fstype" == "ext4" ]] || continue
        # Skip live medium
        mountpoint -q "/dev/$part" 2>/dev/null && continue
        ROOT_PART="/dev/$part"
        blue "Candidate root: $ROOT_PART"
    done < <(lsblk -n -o NAME,FSTYPE | grep -E '^[a-z]+[0-9]+|^nvme[0-9]+n[0-9]+p[0-9]+')

    [[ -n "$ROOT_PART" ]] || die "No ext4 partition found. Did the install actually run?"
fi
blue "Root partition: $ROOT_PART"

# Find the disk this partition is on, and its ESP
PARENT_DISK=$(lsblk -no PKNAME "$ROOT_PART")
[[ -n "$PARENT_DISK" ]] || die "Can't find parent disk of $ROOT_PART"
PARENT_DISK="/dev/$PARENT_DISK"
blue "Parent disk: $PARENT_DISK"

EFI_PART=""
while read -r part fstype; do
    if [[ "$fstype" == "vfat" ]]; then
        EFI_PART="/dev/$part"
        break
    fi
done < <(lsblk -n -o NAME,FSTYPE "$PARENT_DISK" | tail -n +2)

if [[ -n "$EFI_PART" ]]; then
    blue "EFI partition: $EFI_PART"
    BOOT_MODE=UEFI
else
    blue "No EFI partition — assuming BIOS install"
    BOOT_MODE=BIOS
fi

header "Mounting installed system"
mkdir -p /mnt/aegisos
mount "$ROOT_PART" /mnt/aegisos
green "Mounted $ROOT_PART at /mnt/aegisos"

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    mkdir -p /mnt/aegisos/boot/efi
    mount "$EFI_PART" /mnt/aegisos/boot/efi
    green "Mounted $EFI_PART at /mnt/aegisos/boot/efi"
fi

# Bind mounts for chroot
for d in dev proc sys run; do
    mount --bind /$d /mnt/aegisos/$d
done
mount --bind /dev/pts /mnt/aegisos/dev/pts
[[ -d /sys/firmware/efi/efivars ]] && \
    mount --bind /sys/firmware/efi/efivars /mnt/aegisos/sys/firmware/efi/efivars 2>/dev/null || true

cp /etc/resolv.conf /mnt/aegisos/etc/resolv.conf 2>/dev/null || true

header "Reinstalling GRUB ($BOOT_MODE mode, with removable-media fallback)"

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    chroot /mnt/aegisos /bin/bash -c "
        set -e
        # Make sure grub packages are present
        DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall \
            grub-efi-amd64 grub-efi-amd64-bin grub-efi-amd64-signed \
            shim-signed efibootmgr 2>&1 | tail -5

        # Install GRUB to /EFI/AegisOS/ AND to the fallback /EFI/BOOT/ path
        # The --removable flag forces install to /EFI/BOOT/BOOTX64.EFI, which
        # is what VMware Fusion's UEFI looks for when NVRAM entries fail.
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck \
            --bootloader-id=AegisOS
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck \
            --removable

        update-grub
    "
    green "GRUB installed at BOTH /EFI/AegisOS/ AND /EFI/BOOT/ (fallback)"

    # Verify the fallback path actually has the file
    if [[ -f /mnt/aegisos/boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
        green "✓ /boot/efi/EFI/BOOT/BOOTX64.EFI exists"
        ls -la /mnt/aegisos/boot/efi/EFI/BOOT/
    else
        yellow "⚠ Fallback BOOTX64.EFI missing — copying manually as last resort"
        mkdir -p /mnt/aegisos/boot/efi/EFI/BOOT
        cp /mnt/aegisos/boot/efi/EFI/AegisOS/grubx64.efi \
           /mnt/aegisos/boot/efi/EFI/BOOT/BOOTX64.EFI
        # Also need shim if it exists
        [[ -f /mnt/aegisos/boot/efi/EFI/AegisOS/shimx64.efi ]] && \
            cp /mnt/aegisos/boot/efi/EFI/AegisOS/shimx64.efi \
               /mnt/aegisos/boot/efi/EFI/BOOT/BOOTX64.EFI
    fi
else
    chroot /mnt/aegisos /bin/bash -c "
        set -e
        DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall grub-pc 2>&1 | tail -3
        grub-install --target=i386-pc --recheck '$PARENT_DISK'
        update-grub
    "
    green "GRUB reinstalled to MBR of $PARENT_DISK"
fi

# Verify grub.cfg actually got generated with valid menu entries
header "Verifying grub config"
if [[ -f /mnt/aegisos/boot/grub/grub.cfg ]]; then
    MENU_COUNT=$(grep -c '^menuentry ' /mnt/aegisos/boot/grub/grub.cfg || echo 0)
    blue "Menu entries in grub.cfg: $MENU_COUNT"
    if [[ $MENU_COUNT -lt 1 ]]; then
        yellow "WARNING: no menu entries — grub will boot to a prompt."
        yellow "Inside the chroot, manually run:  update-grub"
    else
        green "grub.cfg looks healthy"
        grep '^menuentry ' /mnt/aegisos/boot/grub/grub.cfg | head -3 | sed 's/^/  /'
    fi
else
    yellow "WARNING: /boot/grub/grub.cfg does not exist!"
fi

header "Cleanup"
umount /mnt/aegisos/sys/firmware/efi/efivars 2>/dev/null || true
umount /mnt/aegisos/dev/pts
for d in dev proc sys run; do
    umount /mnt/aegisos/$d 2>/dev/null || umount -lf /mnt/aegisos/$d
done
[[ "$BOOT_MODE" == "UEFI" ]] && umount /mnt/aegisos/boot/efi
umount /mnt/aegisos
sync

green ""
green "═══════════════════════════════════════════════════════════════"
green "  GRUB repaired."
green ""
green "  Next:"
green "    1. In VMware Fusion: Virtual Machine → CD/DVD → DISCONNECT the ISO"
green "    2. Power off the VM (do NOT just reboot — full power cycle)"
green "    3. Power on. AegisOS should boot from disk now."
green "═══════════════════════════════════════════════════════════════"
