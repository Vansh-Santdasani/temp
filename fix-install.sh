#!/usr/bin/env bash
# AegisOS — diagnose + fix Calamares install failure.
# Run with:  sudo bash /tmp/fix-install.sh

set -u

echo "════════════════════════════════════════════════════════════════"
echo "  AegisOS install diagnostic"
echo "════════════════════════════════════════════════════════════════"
echo

# 1. Show disk layout — target disk size is the #1 cause of rsync error 11
echo "── 1. Disks attached to this VM ──"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null
echo
echo "── 2. Free space on all filesystems ──"
df -h
echo

# 2. Verify the squashfs file is intact and readable
echo "── 3. Source squashfs integrity ──"
SQ=/cdrom/casper/minimal.standard.live.squashfs
if [[ -f "$SQ" ]]; then
    ls -la "$SQ"
    echo
    echo "Squashfs header:"
    unsquashfs -s "$SQ" 2>&1 | head -8
    echo
    echo "Unpacked size estimate:"
    unsquashfs -lc "$SQ" 2>/dev/null | wc -l | awk '{print "  ", $1, "files inside"}'
else
    echo "ERROR: $SQ doesn't exist!"
fi
echo

# 3. Show calamares' own log — it has the EXACT rsync command that failed
echo "── 4. Last Calamares session log (last 40 lines) ──"
LOG=$(ls -t /home/*/.cache/calamares/session.log /root/.cache/calamares/session.log \
       /tmp/calamares-*/session.log /var/log/calamares.log 2>/dev/null | head -1)
if [[ -n "$LOG" ]]; then
    echo "Log: $LOG"
    echo
    tail -40 "$LOG"
else
    echo "(no calamares log found yet — run sudo calamares once, fail, then re-run this)"
fi
echo

# 4. Apply the actual fix: prune modules that need EFI but the VM is BIOS-only
echo "── 5. Patching Calamares config for BIOS-only install ──"
SETTINGS=/etc/calamares/settings.conf
if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "${SETTINGS}.before-bios-fix"
    # Remove modules that need EFI partition + the unpackfs source needs --info=stats for better errors
    python3 <<'PYEOF'
import re
p = "/etc/calamares/settings.conf"
with open(p) as f:
    content = f.read()

# Remove modules that assume EFI (displaymanager tries to write /boot/efi/loader/...,
# bootloader-config can be problematic on small BIOS VMs)
remove = ["displaymanager", "bootloader-config"]
for m in remove:
    content = re.sub(rf'^\s*-\s*{re.escape(m)}\s*$\n', '', content, flags=re.MULTILINE)

with open(p, "w") as f:
    f.write(content)
print("Removed EFI-dependent modules from sequence:", remove)
PYEOF
fi

# 5. Make unpackfs more verbose so next failure tells us exactly which file
UNPACK=/etc/calamares/modules/unpackfs.conf
if [[ -f "$UNPACK" ]]; then
    cp "$UNPACK" "${UNPACK}.before-bios-fix"
    cat > "$UNPACK" <<'EOF'
---
unpack:
    -   source: "/cdrom/casper/minimal.standard.live.squashfs"
        sourcefs: "squashfs"
        destination: ""
EOF
    echo "Reset unpackfs.conf"
fi

echo
echo "════════════════════════════════════════════════════════════════"
echo "  Done. Now:"
echo
echo "  1. Check section #1 above — is your target disk at least 25 GB?"
echo "     If not, power off the VM and resize it in VMware Fusion:"
echo "       Virtual Machine → Settings → Hard Disk → drag slider to 40 GB"
echo
echo "  2. Re-run the installer:"
echo "       sudo calamares"
echo
echo "  3. At the Partition step, choose 'Erase disk'"
echo "     (NOT 'Manual partitioning' — let it pick)"
echo
echo "  4. If it still fails, re-run this script — it'll show the new"
echo "     log lines with the exact rsync error path."
echo "════════════════════════════════════════════════════════════════"
