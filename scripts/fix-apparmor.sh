#!/usr/bin/env bash
# scripts/fix-apparmor.sh
#
# Stop Ubuntu's AppArmor from blocking unprivileged user namespaces.
# Nest sandboxes every tool call with bwrap, which requires
# `clone(CLONE_NEWUSER)` + a writable uid_map. Ubuntu's default
# `apparmor_restrict_unprivileged_userns = 1` makes bwrap fail with
# `bwrap: setting up uid map: Permission denied` for every regular user.
#
# This script:
#   1. Disables the restriction on the running kernel.
#   2. Persists the setting across reboots via /etc/sysctl.d/.
#
# Run with sudo:
#   sudo bash scripts/fix-apparmor.sh
#
# It is safe to re-run; the sysctl drop-in is idempotent.

set -euo pipefail

SYSCTL_DROP_IN="/etc/sysctl.d/99-nest-apparmor-userns.conf"
SYSCTL_KEY="kernel.apparmor_restrict_unprivileged_userns"

if [ "$(id -u)" -ne 0 ]; then
  echo "error: must run as root (use: sudo bash scripts/fix-apparmor.sh)" >&2
  exit 1
fi

current="$(cat "/proc/sys/${SYSCTL_KEY}" 2>/dev/null || echo missing)"
echo "current ${SYSCTL_KEY} = ${current}"

if [ "${current}" = "0" ]; then
  echo "already disabled on running kernel; nothing to do."
else
  echo "disabling on running kernel..."
  sysctl -w "${SYSCTL_KEY}=0"
fi

echo "writing persistent drop-in to ${SYSCTL_DROP_IN}..."
cat > "${SYSCTL_DROP_IN}" <<'EOF'
# Allow unprivileged user namespaces (bwrap needs this).
# Nest sandboxes every tool call with bwrap; Ubuntu's default policy
# breaks bwrap with `setting up uid map: Permission denied`.
kernel.apparmor_restrict_unprivileged_userns = 0
EOF

# Reload so the drop-in takes effect immediately if the kernel value
# somehow disagreed (e.g. early-boot sysctl override).
sysctl --system >/dev/null

echo "verifying:"
sysctl "${SYSCTL_KEY}"
echo "done."
