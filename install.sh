#!/usr/bin/env bash
# install.sh — install LYNX SHARE for the current user on Linux (no root).
#
# What it does:
#   1. Downloads the official release AppImage from GitHub (the one network step that is needed).
#   2. Verifies it against the release's own SHA256SUMS.txt before installing.
#   3. Installs it to ~/.local/opt/LYNX and symlinks ~/.local/bin/LYNX.
#   4. Registers the menu entry, icon and the .lynx file type (via the AppImage's own --menu-entry).
#   5. Pre-configures LYNX so it stays offline by default:
#        - the update check is switched off (no GitHub API calls at start),
#        - crash reports are set to "never" (nothing is sent, not even asked).
#   6. Does NOT download the ONNX stem model. LYNX only fetches that model (from Hugging Face,
#      one time) if you yourself choose "Extract stems" on an audio clip. Nothing here triggers it.
#
# Usage:
#   ./install.sh                      # install the latest official release (pinned below)
#   ./install.sh --version 0.1.30-alpha   # pin a specific official release tag
#   ./install.sh --uninstall          # remove LYNX (settings in ~/.config/LYNX are kept)
#
# Requirements: x86_64 Linux with glibc 2.35+ (Ubuntu 22.04+, Debian 12, Fedora 36+),
# curl or wget, and sha256sum. A PipeWire/JACK/ALSA audio stack is needed at run time
# (present by default on current Ubuntu).
set -euo pipefail

# ------------------------------------------------------------------ configuration ---
REPO="Ka1-S/LYNX-SHARE"                 # official project
RELEASE_TAG="${LYNX_VERSION:-0.1.30-alpha}"   # default: latest official release (change with --version)
ARCH="${ARCH:-x86_64}"
APPIMAGE_NAME="LYNX-${RELEASE_TAG}-${ARCH}.AppImage"
APPIMAGE_URL="https://github.com/${REPO}/releases/download/v${RELEASE_TAG}/${APPIMAGE_NAME}"
SUMS_URL="https://github.com/${REPO}/releases/download/v${RELEASE_TAG}/SHA256SUMS.txt"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/opt/LYNX}"
BIN_LINK="${BIN_LINK:-$HOME/.local/bin/LYNX}"
SETTINGS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/LYNX"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------------ helpers ---
say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # fetch <url> <dest>
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$2" "$1"
    elif command -v wget > /dev/null 2>&1; then
        wget -q --tries=3 -O "$2" "$1"
    else
        die "neither curl nor wget is installed"
    fi
}

# ------------------------------------------------------------------ parse arguments ---
UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) UNINSTALL=1 ;;
        --version)   RELEASE_TAG="${2:?--version needs a tag, e.g. 0.1.30-alpha}"; shift ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done
APPIMAGE_NAME="LYNX-${RELEASE_TAG}-${ARCH}.AppImage"
APPIMAGE_URL="https://github.com/${REPO}/releases/download/v${RELEASE_TAG}/${APPIMAGE_NAME}"
SUMS_URL="https://github.com/${REPO}/releases/download/v${RELEASE_TAG}/SHA256SUMS.txt"

if [ "$ARCH" != "x86_64" ]; then
    die "this installer installs the official x86_64 AppImage; your architecture ($ARCH) is not covered by it"
fi

# ------------------------------------------------------------------ uninstall ---
if [ "$UNINSTALL" = "1" ]; then
    say "Removing LYNX SHARE"
    [ -e "$BIN_LINK" ] && rm -f "$BIN_LINK"
    rm -rf "$INSTALL_DIR"
    # remove the desktop entry the AppImage registered
    data="${XDG_DATA_HOME:-$HOME/.local/share}"
    rm -f "$data/applications/com.lynx_share.LYNX.desktop"
    say "LYNX SHARE removed. Your settings in $SETTINGS_DIR were kept."
    exit 0
fi

# ------------------------------------------------------------------ pre-flight ---
say "LYNX SHARE installer — release v${RELEASE_TAG}"
command -v sha256sum > /dev/null 2>&1 || die "sha256sum is required (install coreutils)"

# glibc check: the official Linux build needs glibc 2.35+ (Ubuntu 22.04+, Debian 12, Fedora 36+)
if command -v ldd > /dev/null 2>&1; then
    glibc="$(ldd --version 2>/dev/null | head -1 | sed -E 's/.* ([0-9]+\.[0-9]+)$/\1/')"
    if [ -n "$glibc" ] && awk -v g="$glibc" 'BEGIN{exit !(g+0 < 2.35)}'; then
        warn "glibc $glibc is older than 2.35 — the official build may not run on this system"
    fi
fi

mkdir -p "$INSTALL_DIR" "$(dirname "$BIN_LINK")"

# ------------------------------------------------------------------ download + verify ---
say "Downloading the official AppImage (the one network step)"
fetch "$APPIMAGE_URL" "$WORK/$APPIMAGE_NAME" || die "could not download $APPIMAGE_URL (check the tag with --version)"

say "Checking it against the release's own SHA256SUMS.txt"
fetch "$SUMS_URL" "$WORK/SHA256SUMS.txt" || die "could not download $SUMS_URL — refusing to install an unverified AppImage"
line="$(grep -F "  $APPIMAGE_NAME" "$WORK/SHA256SUMS.txt" | head -1)" \
    || line="$(grep -F "$APPIMAGE_NAME" "$WORK/SHA256SUMS.txt" | head -1)"
[ -n "$line" ] || die "the checksums file has no entry for $APPIMAGE_NAME — refusing to install"
expected="$(printf '%s' "$line" | awk '{print $1}')"
actual="$(sha256sum "$WORK/$APPIMAGE_NAME" | awk '{print $1}')"
[ "$expected" = "$actual" ] || die "checksum mismatch: expected $expected, got $actual — the file was not installed"
say "Checksum OK ($APPIMAGE_NAME)"

# ------------------------------------------------------------------ install ---
say "Installing to $INSTALL_DIR"
mv "$WORK/$APPIMAGE_NAME" "$INSTALL_DIR/$APPIMAGE_NAME"
chmod 755 "$INSTALL_DIR/$APPIMAGE_NAME"
ln -sf "$INSTALL_DIR/$APPIMAGE_NAME" "$BIN_LINK"

say "Registering the menu entry, icon and the .lynx file type"
# The AppImage's own flag writes ~/.local/share/applications/com.lynx_share.LYNX.desktop,
# the icon and the MIME type (docs/LINUX.md). Non-interactive: no wizard.
"$INSTALL_DIR/$APPIMAGE_NAME" --menu-entry on > /dev/null 2>&1 || \
    warn "could not write the menu entry automatically — start LYNX once and accept the setup wizard"

# ------------------------------------------------------------------ offline by default ---
say "Setting LYNX to stay offline unless you use it"
mkdir -p "$SETTINGS_DIR"
# 1) update check off (UpdateCheck reads "automatic=0" from updates.txt)
printf 'automatic=0\n' > "$SETTINGS_DIR/updates.txt"
# 2) crash reports never sent, never asked (CrashReporter reads "never" from crash-reports.txt)
printf 'never\n' > "$SETTINGS_DIR/crash-reports.txt"
# The ONNX stem model is deliberately NOT downloaded: LYNX only fetches it from Hugging Face
# if you choose "Extract stems" on an audio clip and agree to the download. Nothing here
# triggers it, and the model (166 MB) will not occupy space in ~/.local/share/LYNX/models.

# ------------------------------------------------------------------ done ---
command -v update-desktop-database > /dev/null 2>&1 && update-desktop-database \
    "${XDG_DATA_HOME:-$HOME/.local/share}/applications" > /dev/null 2>&1 || true
command -v update-mime-database > /dev/null 2>&1 && update-mime-database \
    "${XDG_DATA_HOME:-$HOME/.local/share}/mime" > /dev/null 2>&1 || true

cat <<EOF

LYNX SHARE v${RELEASE_TAG} installed.

  Run it:        $BIN_LINK
  Or from the applications menu: search "LYNX".

Offline status: the update check is off and crash reports are set to "never".
The only things that use the network now are the ones you start yourself:
  - a live online session (File › Online session),
  - "Extract stems" (which downloads the ONNX model once, if you agree),
  - Help › Check for updates (manual).

Settings live in $SETTINGS_DIR; remove that folder to reset them.
To uninstall later:  $0 --uninstall
EOF
