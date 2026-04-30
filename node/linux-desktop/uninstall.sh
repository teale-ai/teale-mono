#!/usr/bin/env bash
set -euo pipefail

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

INSTALL_ROOT="${XDG_DATA_HOME}/teale"
CONFIG_ROOT="${XDG_CONFIG_HOME}/teale"
STATE_ROOT="${XDG_STATE_HOME}/teale"
SERVICE_FILE="${XDG_CONFIG_HOME}/systemd/user/teale-node.service"
DESKTOP_FILE="${XDG_DATA_HOME}/applications/teale.desktop"
WRAPPER_PATH="${HOME}/.local/bin/teale"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now teale-node.service >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

rm -f "${SERVICE_FILE}" "${DESKTOP_FILE}" "${WRAPPER_PATH}"
rm -rf "${INSTALL_ROOT}" "${CONFIG_ROOT}" "${STATE_ROOT}"

echo "Teale removed from this user profile."
