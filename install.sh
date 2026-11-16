#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_DIR=""
UNINSTALL=0
QUIET=0
FORCE_CLI=0

usage() {
  cat <<'EOF'
OpenCode Custom Provider Plugin Installer (macOS / Linux)

Usage:
  bash install.sh [options]

Options:
  --uninstall, -u         Remove the installed custom-provider plugin
  --config-dir <path>     Override OpenCode config directory
  --cli                   Force terminal mode (no GUI prompt)
  --quiet, -q             Minimal output (implies --cli)
  --help, -h              Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --uninstall|-u)
      UNINSTALL=1
      shift
      ;;
    --config-dir)
      if [ "$#" -lt 2 ]; then
        echo "[ERROR] --config-dir requires a path argument" >&2
        exit 1
      fi
      CONFIG_DIR="$2"
      shift 2
      ;;
    --config-dir=*)
      CONFIG_DIR="${1#*=}"
      shift
      ;;
    --cli)
      FORCE_CLI=1
      shift
      ;;
    --quiet|-q)
      QUIET=1
      FORCE_CLI=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

log_info() {
  if [ "$QUIET" -eq 0 ]; then
    printf '%s\n' "$*"
  fi
}

if [ -n "$CONFIG_DIR" ]; then
  OPENCODE_DIR="$CONFIG_DIR"
elif [ -n "${OPENCODE_CONFIG_DIR:-}" ]; then
  OPENCODE_DIR="$OPENCODE_CONFIG_DIR"
elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
  OPENCODE_DIR="${XDG_CONFIG_HOME%/}/opencode"
else
  OPENCODE_DIR="$HOME/.config/opencode"
fi

TARGET_DIR="$OPENCODE_DIR/plugins/custom-provider"

show_gui_prompt_if_available() {
  [ "$FORCE_CLI" -eq 0 ] || return 1
  [ "$UNINSTALL" -eq 0 ] || return 1

  OS_NAME="$(uname -s 2>/dev/null || echo "")"
  if [ "$OS_NAME" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    CHOICE="$(osascript -e 'button returned of (display dialog "OpenCode Custom Provider Plugin Installer\n\nTarget: '"$TARGET_DIR"'\n\nNote: Settings UI plugin requires OpenCode v2.2+." with title "OpenCode Custom Provider" buttons {"Cancel", "Uninstall", "Install / Update"} default button "Install / Update")' 2>/dev/null || echo "Cancel")"
    case "$CHOICE" in
      "Uninstall") UNINSTALL=1 ;;
      "Install / Update") UNINSTALL=0 ;;
      *) exit 0 ;;
    esac
    return 0
  fi

  if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    if command -v zenity >/dev/null 2>&1; then
      CHOICE="$(zenity --list --title="OpenCode Custom Provider Installer" --text="Target: $TARGET_DIR (Requires OpenCode Desktop v2.2+)" --column="Action" --column="Description" "Install" "Install or Update plugin" "Uninstall" "Remove plugin" --height=240 --width=480 2>/dev/null || echo "")"
      case "$CHOICE" in
        Install) UNINSTALL=0 ;;
        Uninstall) UNINSTALL=1 ;;
        *) exit 0 ;;
      esac
      return 0
    elif command -v kdialog >/dev/null 2>&1; then
      CHOICE="$(kdialog --menu "OpenCode Custom Provider Installer\nTarget: $TARGET_DIR" install "Install / Update Plugin" uninstall "Uninstall Plugin" 2>/dev/null || echo "")"
      case "$CHOICE" in
        install) UNINSTALL=0 ;;
        uninstall) UNINSTALL=1 ;;
        *) exit 0 ;;
      esac
      return 0
    fi
  fi
  return 1
}

USED_GUI=0
if show_gui_prompt_if_available; then
  USED_GUI=1
fi

log_info ""
log_info "===================================================="
log_info "  OpenCode Custom Provider Plugin Installer"
log_info "===================================================="
log_info "Config dir : $OPENCODE_DIR"
log_info "Target dir : $TARGET_DIR"
log_info ""

if [ "$UNINSTALL" -eq 1 ]; then
  if [ -d "$TARGET_DIR" ]; then
    rm -rf "$TARGET_DIR"
    MSG="Uninstalled custom-provider plugin from: $TARGET_DIR"
  else
    MSG="Plugin is not installed at: $TARGET_DIR"
  fi
  log_info "[OK] $MSG"
  if [ "$USED_GUI" -eq 1 ]; then
    OS_NAME="$(uname -s 2>/dev/null || echo "")"
    if [ "$OS_NAME" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
      osascript -e 'display dialog "'"$MSG"'" with title "OpenCode Custom Provider" buttons {"OK"} default button "OK"' >/dev/null 2>&1 || true
    elif command -v zenity >/dev/null 2>&1; then
      zenity --info --title="OpenCode Custom Provider" --text="$MSG" >/dev/null 2>&1 || true
    fi
  fi
  exit 0
fi

PLUGIN_SRC=""
if [ -f "$SCRIPT_DIR/plugin/gui-experimental.cjs" ]; then
  PLUGIN_SRC="$SCRIPT_DIR/plugin"
elif [ -f "$SCRIPT_DIR/gui-experimental.cjs" ]; then
  PLUGIN_SRC="$SCRIPT_DIR"
else
  echo "[ERROR] Could not find plugin files (package.json, index.js, gui-experimental.cjs) next to install.sh." >&2
  exit 1
fi

for f in package.json index.js gui-experimental.cjs; do
  if [ ! -s "$PLUGIN_SRC/$f" ]; then
    echo "[ERROR] Missing or empty required file: $PLUGIN_SRC/$f" >&2
    exit 1
  fi
done

ACTION="Installed"
if [ -d "$TARGET_DIR" ]; then
  ACTION="Updated"
fi

mkdir -p "$TARGET_DIR"
for f in package.json index.js gui-experimental.cjs; do
  cp -f "$PLUGIN_SRC/$f" "$TARGET_DIR/$f"
  chmod 644 "$TARGET_DIR/$f"
done

for f in package.json index.js gui-experimental.cjs; do
  if [ ! -s "$TARGET_DIR/$f" ]; then
    echo "[ERROR] Verification failed for: $TARGET_DIR/$f" >&2
    exit 1
  fi
done

MSG="$ACTION Custom Provider plugin at: $TARGET_DIR\n\nQuit and reopen OpenCode Desktop (v2.2+) -> Settings -> Custom Providers."
log_info "[OK] $ACTION Custom Provider plugin at:"
log_info "     $TARGET_DIR"
log_info ""
if [ "$USED_GUI" -eq 1 ]; then
  OS_NAME="$(uname -s 2>/dev/null || echo "")"
  if [ "$OS_NAME" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e 'display dialog "'"$MSG"'" with title "OpenCode Custom Provider" buttons {"OK"} default button "OK"' >/dev/null 2>&1 || true
  elif command -v zenity >/dev/null 2>&1; then
    zenity --info --title="OpenCode Custom Provider" --text="$MSG" >/dev/null 2>&1 || true
  fi
fi
log_info "Next step: Open OpenCode Desktop -> Settings -> Custom Providers"
log_info ""
