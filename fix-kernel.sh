#!/usr/bin/env bash
# AegisOS — fix-kernel.sh
#
# Root cause: Ubuntu's live ISO keeps the kernel binary at /cdrom/casper/vmlinuz
# (NOT inside the squashfs filesystem). When manual-install.sh ran `unsquashfs`
# to extract our rootfs to disk, /boot ended up WITHOUT a kernel binary —
# just broken symlinks and a config file. So `update-grub` found no kernels
# and generated a grub.cfg with no Linux menuentries. GRUB then loads, finds
# nothing to boot, and exits back to firmware — which is exactly the symptom:
# blank screen, then back to VMware's boot manager.
#
# This script: boots from live ISO, mounts your installed disk, copies the
# kernel from /cdrom/casper/, generates a proper initrd inside the chroot,
# regenerates grub.cfg, verifies the menuentries point to files that exist.
#
# Usage:
#   1. Boot the live ISO ("Try AegisOS" from GRUB menu)
#   2. Drag this file into the VM
#   3. sudo bash /tmp/fix-kernel.sh

set -euo pipefail

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }
header() { printf '\n\033[1;36m══ %s ══\033[0m\n' "$*"; }
die()    { red "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"
[[ -d /cdrom/casper ]] || die "Must run from AegisOS LIVE session (booted from ISO)."

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

# ── 1. Find installed partition ────────────────────────────────────────────
header "Finding installed AegisOS partition"

ROOT_PART="$(blkid -L AegisOS 2>/dev/null || true)"
[[ -n "$ROOT_PART" ]] || die "No partition labeled 'AegisOS' found."
blue "Root partition: $ROOT_PART"

PARENT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_PART" | head -1)"
blue "Parent disk:    $PARENT_DISK"

EFI_PART=""
while read -r part fstype rest; do
    [[ "$part" == "$PARENT_DISK" ]] && continue
    if [[ "$fstype" == "vfat" ]]; then
        EFI_PART="$part"
        break
    fi
done < <(lsblk -lnpo NAME,FSTYPE "$PARENT_DISK")
[[ -n "$EFI_PART" ]] && blue "EFI partition:  $EFI_PART"

# ── 2. Mount + diagnose ────────────────────────────────────────────────────
header "Mounting + diagnosing"
mkdir -p "$MOUNT_DIR"
mount "$ROOT_PART" "$MOUNT_DIR"
[[ -n "$EFI_PART" ]] && { mkdir -p "$MOUNT_DIR/boot/efi"; mount "$EFI_PART" "$MOUNT_DIR/boot/efi"; }

# Detect kernel version from installed /lib/modules (the modules ARE in squashfs)
KVER=""
if [[ -d "$MOUNT_DIR/lib/modules" ]]; then
    KVER=$(ls "$MOUNT_DIR/lib/modules" 2>/dev/null | head -1)
fi
[[ -n "$KVER" ]] || die "No /lib/modules/* dir found — the install is missing kernel modules entirely."
blue "Kernel version (from /lib/modules): $KVER"

# Show what /boot looks like right now
echo
echo "Current /boot contents:"
ls -la "$MOUNT_DIR/boot/" 2>/dev/null | head -15 | sed 's|^|  |'
echo

if [[ -f "$MOUNT_DIR/boot/vmlinuz-$KVER" && -f "$MOUNT_DIR/boot/initrd.img-$KVER" ]]; then
    yellow "Kernel + initrd already exist in /boot."
    yellow "If the system still won't boot, the issue is elsewhere (grub config? UUID mismatch?)"
else
    [[ ! -f "$MOUNT_DIR/boot/vmlinuz-$KVER" ]] && \
        red "✗ /boot/vmlinuz-$KVER is MISSING — this is why GRUB returns to firmware"
    [[ ! -f "$MOUNT_DIR/boot/initrd.img-$KVER" ]] && \
        red "✗ /boot/initrd.img-$KVER is MISSING — same problem"
fi

# ── 3. Copy kernel from the live ISO ───────────────────────────────────────
header "Installing kernel binary into /boot"

# Verify the live kernel exists
[[ -f /cdrom/casper/vmlinuz ]] || die "/cdrom/casper/vmlinuz not found on the live ISO!"
LIVE_KERNEL_SIZE=$(stat -c%s /cdrom/casper/vmlinuz)
blue "Live kernel: /cdrom/casper/vmlinuz ($LIVE_KERNEL_SIZE bytes)"

# Remove broken symlinks first
rm -f "$MOUNT_DIR/boot/vmlinuz" "$MOUNT_DIR/boot/initrd.img" \
      "$MOUNT_DIR/boot/vmlinuz.old" "$MOUNT_DIR/boot/initrd.img.old" 2>/dev/null

# Install the kernel binary
cp /cdrom/casper/vmlinuz "$MOUNT_DIR/boot/vmlinuz-$KVER"
chmod 644 "$MOUNT_DIR/boot/vmlinuz-$KVER"
green "✓ Installed /boot/vmlinuz-$KVER"

# ── 4. Bind mounts + chroot setup ──────────────────────────────────────────
for d in dev proc sys run; do
    mount --bind "/$d" "$MOUNT_DIR/$d"
done
mount --bind /dev/pts "$MOUNT_DIR/dev/pts"
[[ -d /sys/firmware/efi/efivars ]] && \
    mount --bind /sys/firmware/efi/efivars "$MOUNT_DIR/sys/firmware/efi/efivars" 2>/dev/null || true
cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf" 2>/dev/null || true

# ── 5. Generate a fresh initrd inside the chroot ───────────────────────────
header "Generating initrd.img-$KVER (this takes 30-60 seconds)"

chroot "$MOUNT_DIR" /bin/bash -e -c "
    export DEBIAN_FRONTEND=noninteractive
    # Make sure initramfs-tools is present (it should be — it's in Ubuntu base)
    if ! command -v mkinitramfs >/dev/null 2>&1; then
        echo 'mkinitramfs missing — installing initramfs-tools'
        apt-get install -y initramfs-tools 2>&1 | tail -3 || true
    fi
    # Build the initrd. -c = create (overwrite if exists), -k = for kernel version
    update-initramfs -c -k $KVER 2>&1 | tail -10
    # Recreate the convenience symlinks
    cd /boot
    ln -sf vmlinuz-$KVER vmlinuz
    ln -sf initrd.img-$KVER initrd.img
"

# ── 6. Regenerate grub.cfg now that kernels exist ──────────────────────────
header "Regenerating grub.cfg"

chroot "$MOUNT_DIR" /bin/bash -e -c "
    export DEBIAN_FRONTEND=noninteractive
    update-grub 2>&1 | tail -8
"

# ── 7. Verify everything is in order ───────────────────────────────────────
header "Verifying the fix"

echo "/boot now contains:"
ls -la "$MOUNT_DIR/boot/" | grep -E 'vmlinuz|initrd|grub' | sed 's|^|  |'
echo

if [[ -f "$MOUNT_DIR/boot/grub/grub.cfg" ]]; then
    count=$(grep -c '^menuentry ' "$MOUNT_DIR/boot/grub/grub.cfg" || echo 0)
    blue "grub.cfg menuentries: $count"
    grep '^menuentry ' "$MOUNT_DIR/boot/grub/grub.cfg" | head -3 | sed 's|^|  |'

    if [[ $count -ge 1 ]]; then
        # Check the kernel path referenced in grub.cfg actually exists
        KERNEL_REF=$(grep -oE 'linux\s+[^ ]+' "$MOUNT_DIR/boot/grub/grub.cfg" | head -1 | awk '{print $2}')
        if [[ -n "$KERNEL_REF" ]]; then
            # KERNEL_REF starts with /boot/ — strip if checking against MOUNT_DIR
            check_path="$MOUNT_DIR$KERNEL_REF"
            if [[ -f "$check_path" ]]; then
                green "✓ grub.cfg → $KERNEL_REF (exists, $(stat -c%s "$check_path") bytes)"
            else
                red "✗ grub.cfg references $KERNEL_REF but file doesn't exist"
            fi
        fi
    else
        red "✗ No menuentries — update-grub didn't find the kernel. Re-check /boot."
    fi
else
    red "✗ grub.cfg doesn't exist!"
fi

green ""
green "════════════════════════════════════════════════════════════════"
green "  Kernel + initrd installed. grub.cfg regenerated."
green ""
green "  Now:"
green "    1. VMware Fusion: Virtual Machine → CD/DVD → DISCONNECT"
green "    2. Virtual Machine → SHUT DOWN (full power off)"
green "    3. Start the VM. It should boot AegisOS this time."
green "════════════════════════════════════════════════════════════════"
