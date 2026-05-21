#!/usr/bin/env bash
# AegisOS — fix-initrd.sh
#
# What happened: after the kernel fix, GRUB now loads the kernel correctly,
# but the initrd we generated includes the `casper` (live-CD) hooks. So
# /init in the initrd tries to mount the live ISO from /dev/sr0 instead of
# the installed disk. Since the CD is disconnected, the init loops forever
# with "can't open /dev/sr0: No medium found".
#
# Fix: purge the casper package, regenerate initrd. The resulting initrd is
# a normal Ubuntu installed-system initrd that mounts root=UUID=... from disk.
# Standard live-to-installed conversion step.

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

# ── Mount the installed system ─────────────────────────────────────────────
header "Mounting installed system"
ROOT_PART="$(blkid -L AegisOS 2>/dev/null)" || die "AegisOS partition not found"
blue "Root: $ROOT_PART"

PARENT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_PART" | head -1)"
EFI_PART=""
while read -r part fstype rest; do
    [[ "$part" == "$PARENT_DISK" ]] && continue
    if [[ "$fstype" == "vfat" ]]; then EFI_PART="$part"; break; fi
done < <(lsblk -lnpo NAME,FSTYPE "$PARENT_DISK")

mkdir -p "$MOUNT_DIR"
mount "$ROOT_PART" "$MOUNT_DIR"
if [[ -n "$EFI_PART" ]]; then
    mkdir -p "$MOUNT_DIR/boot/efi"
    mount "$EFI_PART" "$MOUNT_DIR/boot/efi"
    blue "EFI:  $EFI_PART"
fi

# ── Confirm casper is in the rootfs ────────────────────────────────────────
header "Confirming diagnosis"
if [[ -f "$MOUNT_DIR/usr/share/initramfs-tools/hooks/casper" ]]; then
    red "✓ Confirmed: casper hooks present at /usr/share/initramfs-tools/hooks/casper"
    red "  This is why the new initrd tries to mount /dev/sr0"
else
    yellow "casper hook not found — issue may be elsewhere. Continuing anyway."
fi

# Show the current initrd contents to prove it has casper inside
NEW_INITRD=$(ls -t "$MOUNT_DIR"/boot/initrd.img-* 2>/dev/null | head -1)
if [[ -n "$NEW_INITRD" ]]; then
    echo
    echo "Casper-related files in the current initrd (this is the bug):"
    if [[ "$NEW_INITRD" == *.zst ]]; then
        zstd -dc "$NEW_INITRD" 2>/dev/null | cpio -t 2>/dev/null | grep casper | head -8 | sed 's|^|  |' || true
    elif [[ "$NEW_INITRD" == *.gz ]] || file "$NEW_INITRD" 2>/dev/null | grep -q gzip; then
        zcat "$NEW_INITRD" 2>/dev/null | cpio -t 2>/dev/null | grep casper | head -8 | sed 's|^|  |' || true
    else
        # Newer Ubuntu uses uncompressed cpio or zstd
        cpio -t < "$NEW_INITRD" 2>/dev/null | grep casper | head -8 | sed 's|^|  |' || true
    fi
fi

# ── Chroot setup ───────────────────────────────────────────────────────────
for d in dev proc sys run; do mount --bind "/$d" "$MOUNT_DIR/$d"; done
mount --bind /dev/pts "$MOUNT_DIR/dev/pts"
[[ -d /sys/firmware/efi/efivars ]] && \
    mount --bind /sys/firmware/efi/efivars "$MOUNT_DIR/sys/firmware/efi/efivars" 2>/dev/null || true
cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf" 2>/dev/null || true

# ── Remove casper + regenerate initrd ──────────────────────────────────────
header "Removing casper + regenerating initrd"
chroot "$MOUNT_DIR" /bin/bash -e -c '
    export DEBIAN_FRONTEND=noninteractive

    # 1. Try the clean apt purge. If no network or broken sources list, fine —
    #    fall back to dpkg --purge in the next step.
    apt-get purge -y --autoremove casper lupin-casper 2>&1 | tail -5 || true

    # 2. Force-remove via dpkg in case apt-get failed silently
    dpkg --purge casper       2>/dev/null || true
    dpkg --purge lupin-casper 2>/dev/null || true

    # 3. Force-remove leftover casper files from initramfs-tools paths.
    #    Even if the package was already gone, leftover hooks would re-bake
    #    casper code into the new initrd. Belt and suspenders.
    rm -f  /usr/share/initramfs-tools/hooks/casper
    rm -rf /usr/share/initramfs-tools/scripts/casper
    rm -rf /usr/share/initramfs-tools/scripts/casper-bottom
    rm -rf /usr/share/initramfs-tools/scripts/casper-premount
    rm -f  /usr/share/initramfs-tools/scripts/casper-helpers
    rm -f  /etc/initramfs-tools/conf.d/casper*
    rm -f  /usr/share/initramfs-tools/conf.d/casper*

    # 4. Make sure the kernel cmdline in /etc/default/grub doesnt have any
    #    casper-isms (boot=casper, ip=, etc.). The Ubuntu default is just
    #    "quiet splash" — verify and reset if needed.
    if grep -qE "(boot=casper|file=/cdrom|toram)" /etc/default/grub 2>/dev/null; then
        echo "Cleaning casper from /etc/default/grub"
        sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"|" /etc/default/grub
        sed -i "s|GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"\"|" /etc/default/grub
    fi

    # 5. Regenerate every initrd in /boot
    update-initramfs -u -k all 2>&1 | tail -10

    # 6. Regenerate grub.cfg (new initrd hash, no casper cmdline)
    update-grub 2>&1 | tail -10
'
green "✓ Casper removed, initrd regenerated, grub.cfg refreshed"

# ── Verify the new initrd is casper-free ───────────────────────────────────
header "Verifying the fix"
NEW_INITRD=$(ls -t "$MOUNT_DIR"/boot/initrd.img-* 2>/dev/null | head -1)
if [[ -n "$NEW_INITRD" ]]; then
    blue "Latest initrd: $NEW_INITRD ($(du -h "$NEW_INITRD" | cut -f1))"
    # Use lsinitramfs (Ubuntu's standard tool — handles whatever compression)
    if command -v lsinitramfs >/dev/null 2>&1; then
        casper_count=$(lsinitramfs "$NEW_INITRD" 2>/dev/null | grep -c casper || true)
    else
        casper_count=$(chroot "$MOUNT_DIR" lsinitramfs "/boot/$(basename "$NEW_INITRD")" 2>/dev/null | grep -c casper || true)
    fi
    if [[ "$casper_count" -eq 0 ]]; then
        green "✓ New initrd has ZERO casper references — should boot from disk now"
    else
        yellow "⚠ New initrd still has $casper_count casper-related entries"
        yellow "  (may still boot, casper might just be dormant code)"
    fi
fi

# Show new grub menu entries
echo
blue "Current grub.cfg menu entries:"
grep '^menuentry ' "$MOUNT_DIR/boot/grub/grub.cfg" | head -3 | sed 's|^|  |'
echo
blue "Kernel cmdline that grub will pass:"
grep -A1 'menuentry' "$MOUNT_DIR/boot/grub/grub.cfg" | grep '^[[:space:]]*linux' | head -1 | sed 's|^|  |'

green ""
green "════════════════════════════════════════════════════════════════"
green "  Done. The initrd is now a normal installed-system initrd."
green ""
green "  Now:"
green "    1. VMware Fusion: Virtual Machine → CD/DVD → DISCONNECT"
green "    2. Virtual Machine → SHUT DOWN (full power off)"
green "    3. Power on. AegisOS should boot to LightDM this time."
green "════════════════════════════════════════════════════════════════"
