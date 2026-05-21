#!/usr/bin/env bash
#
# Antigravity CLI - Termux Bootstrapper Script
#
# A custom-engineered installer designed specifically for Android/Termux environments.
# It automatically installs glibc-runner (grun), downloads the official glibc Linux ARM64
# dynamic binary, stages it, verifies checksum integrity, and creates a wrapper for execution.
#

set -euo pipefail

# 1. Color and Output Theme
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0;0m' # No Color

info() { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; }

echo -e "${CYAN}==================================================${NC}"
echo -e "${CYAN}        Antigravity CLI - Termux Installer        ${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""

# 2. Check Architecture & OS
info "Detecting system environment..."
if [[ "$(uname -s)" != "Linux" ]]; then
    error "This script is customized specifically for Linux (Termux on Android). For standard OS, use the official script."
    exit 1
fi

case "$(uname -m)" in
    aarch64|arm64) arch="arm64" ;;
    *)
        error "Unsupported architecture: $(uname -m). Antigravity Termux adapter is optimized for 64-bit ARM CPUs (aarch64)."
        exit 1
        ;;
esac
success "Device architecture verified: aarch64 (ARM64)"

# 3. Resolve Termux Directories
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
STAGING_DIR="$HOME/.cache/antigravity/staging"
INSTALL_DIR="$PREFIX/lib/antigravity"
WRAPPER_PATH="$PREFIX/bin/agy"

# Ensure crucial directories exist
mkdir -p "$PREFIX/bin" "$STAGING_DIR" "$INSTALL_DIR"

# 4. Install & Verify glibc-runner (grun)
if ! command -v grun &>/dev/null; then
    info "glibc-runner (grun) not found. Attempting automatic installation..."
    if command -v pkg &>/dev/null; then
        pkg update -y || true
        # Install glibc-repo first to make glibc-runner package available
        info "Installing glibc-repo repository dependency..."
        pkg install -y glibc-repo || true
        pkg update -y || true
        
        info "Installing glibc-runner package..."
        if pkg install -y glibc-runner || pkg install -y grun; then
            if command -v grun &>/dev/null; then
                success "glibc-runner (grun) installed successfully."
            else
                error "Package appeared to install, but 'grun' command is still not found."
                exit 1
            fi
        else
            echo ""
            error "Failed to install 'glibc-runner' automatically."
            echo -e "${YELLOW}💡 Troubleshooting Steps:${NC}"
            echo -e "  1. Your current Termux mirror might be outdated or unreachable."
            echo -e "     Please run ${CYAN}termux-change-repo${NC} and select an official, updated mirror (e.g., Tsinghua, BFSU, or F-Droid)."
            echo -e "  2. Perform a complete package upgrade:"
            echo -e "     ${CYAN}pkg update && pkg upgrade -y${NC}"
            echo -e "  3. Manually try to install glibc-runner:"
            echo -e "     ${CYAN}pkg install -y glibc-repo && pkg install -y glibc-runner${NC}"
            echo ""
            exit 1
        fi
    else
        error "Package manager 'pkg' not found. Are you sure you are inside Termux?"
        exit 1
    fi
else
    success "glibc-runner (grun) is already installed."
fi

# 5. Fetch Manifest
DOWNLOAD_BASE_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app"
MANIFEST_URL="$DOWNLOAD_BASE_URL/manifests/linux_arm64.json"

info "Querying release repository manifest..."
DOWNLOADER=""
if command -v curl &>/dev/null; then
    DOWNLOADER="curl"
elif command -v wget &>/dev/null; then
    DOWNLOADER="wget"
else
    error "Either curl or wget is required but neither is installed."
    exit 1
fi

fetch_url() {
    if [ "$DOWNLOADER" = "curl" ]; then
        curl -fsSL "$1"
    else
        wget -q -O - "$1"
    fi
}

manifest_json=$(fetch_url "$MANIFEST_URL" 2>/dev/null || true)
if [ -z "$manifest_json" ]; then
    error "Could not connect to the release server to download the manifest."
    exit 1
fi

parse_json_key() {
    local payload="$1"
    local key="$2"
    echo "$payload" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

version=$(parse_json_key "$manifest_json" "version")
url=$(parse_json_key "$manifest_json" "url")
sha512=$(parse_json_key "$manifest_json" "sha512")

if [ -z "$url" ] || [ -z "$sha512" ]; then
    error "Failed to parse release manifest. The manifest may be corrupted or malformed."
    exit 1
fi

success "Latest available Antigravity CLI version: $version"

# 6. Download & SHA512 Verification
staging_payload="$STAGING_DIR/agy.tar.gz"

cleanup() {
    rm -f "$staging_payload" 2>/dev/null || true
}
trap cleanup EXIT

info "Downloading release package..."
if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL -o "$staging_payload" "$url"
else
    wget -q -O "$staging_payload" "$url"
fi

info "Verifying package integrity..."
actual_hash=$(sha512sum "$staging_payload" | cut -d' ' -f1 || true)

if [ "$actual_hash" != "$sha512" ]; then
    error "Security Halt: The downloaded payload checksum does not match the manifest."
    exit 1
fi
success "Download complete and checksum verified."

# 7. Extract Binary
info "Extracting binary..."
if ! tar -xzf "$staging_payload" -C "$INSTALL_DIR" antigravity 2>/dev/null; then
    error "Failed to extract binary from archive."
    exit 1
fi
chmod +x "$INSTALL_DIR/antigravity"
success "Binary staged successfully."

# 8. Create Launcher Wrapper
info "Creating dynamic launch wrapper at $WRAPPER_PATH..."
cat << EOF > "$WRAPPER_PATH"
#!/data/data/com.termux/files/usr/bin/bash
#
# Termux dynamic glibc-runner bridge wrapper for Antigravity CLI
#
exec grun "$INSTALL_DIR/antigravity" "\$@"
EOF

chmod +x "$WRAPPER_PATH"
success "Wrapper created and executable bits set."

# 9. Initialization Handoff
info "Configuring Termux environment dependencies..."
# Execute native configuration through glibc-runner
if grun "$INSTALL_DIR/antigravity" install --dir "$PREFIX/bin" 2>/dev/null || true; then
    success "Shell configurations initialized."
else
    warn "Soft-warning: Initial configuration setup threw non-fatal warnings."
fi

echo ""
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}🎉 Antigravity CLI successfully installed on Termux!${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo -e "You can now run the tool directly using:"
echo -e "  ${CYAN}agy${NC}"
echo ""
echo -e "To verify installation, run:"
echo -e "  ${CYAN}agy --version${NC}"
echo ""
