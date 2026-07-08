#!/bin/bash
# install.sh — One-liner installer for merjs
# Usage: curl -fsSL https://merjs.trilok.ai/install.sh | bash
# Or:    wget -qO- https://merjs.trilok.ai/install.sh | bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Config
REPO="${REPO:-justrach/merjs}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${VERSION:-latest}"

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "macos";;
        *)          echo "unknown";;
    esac
}

# Detect architecture
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64";;
        arm64|aarch64)  echo "aarch64";;
        *)              echo "unknown";;
    esac
}

OS=$(detect_os)
ARCH=$(detect_arch)

if [ "$OS" = "unknown" ] || [ "$ARCH" = "unknown" ]; then
    echo -e "${RED}Error: Unsupported platform: $(uname -s)/$(uname -m)${NC}"
    echo "Supported: linux/x86_64, linux/aarch64, macos/x86_64, macos/aarch64"
    exit 1
fi

echo -e "${BLUE}🚀 merjs installer${NC}"
echo "   Platform: ${OS}/${ARCH}"
echo "   Install dir: ${INSTALL_DIR}"
echo ""

# Check for required tools
check_deps() {
    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        echo -e "${RED}Error: curl or wget is required${NC}"
        exit 1
    fi
}
check_deps

download() {
    local url="$1"
    local output="$2"

    if command -v curl &> /dev/null; then
        curl -fsSL "$url" -o "$output"
    else
        wget -q "$url" -O "$output"
    fi
}

# Get latest version if not specified
if [ "$VERSION" = "latest" ]; then
    echo -e "${YELLOW}📦 Fetching latest version...${NC}"
    VERSION=$(curl -s "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$VERSION" ]; then
        VERSION="v0.2.5"  # fallback
    fi
fi

echo -e "${BLUE}   Version: ${VERSION}${NC}"

# Release assets are bare binaries named mer-<arch>-<os> (arch before os so
# that `ghr install` derives the command name "mer" instead of falling back
# to the repo name — see cataggar/ghr's deriveBareBinaryName heuristic).
ASSET="mer-${ARCH}-${OS}"
BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
URL="${BASE_URL}/${ASSET}"
CHECKSUMS_URL="${BASE_URL}/checksums.txt"

# Create temp directory
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

echo -e "${YELLOW}⬇️  Downloading ${ASSET}...${NC}"
if ! download "$URL" "${TMP_DIR}/mer"; then
    echo -e "${RED}Error: Failed to download ${URL}${NC}"
    echo "You may need to build from source:"
    echo "  git clone https://github.com/${REPO}.git"
    echo "  cd merjs && zig build cli"
    exit 1
fi

# Verify checksum when possible; a missing checksums.txt (or checksum tool)
# is a soft failure so the install can still proceed.
if download "$CHECKSUMS_URL" "${TMP_DIR}/checksums.txt" 2>/dev/null; then
    echo -e "${YELLOW}🔒 Verifying checksum...${NC}"
    (
        cd "$TMP_DIR"
        if command -v shasum &> /dev/null; then
            grep " ${ASSET}\$" checksums.txt | sed "s| ${ASSET}\$| mer|" | shasum -a 256 -c - \
                || { echo -e "${RED}Error: checksum verification failed${NC}"; exit 1; }
        elif command -v sha256sum &> /dev/null; then
            grep " ${ASSET}\$" checksums.txt | sed "s| ${ASSET}\$| mer|" | sha256sum -c - \
                || { echo -e "${RED}Error: checksum verification failed${NC}"; exit 1; }
        else
            echo -e "${YELLOW}   (no sha256 tool found, skipping verification)${NC}"
        fi
    )
else
    echo -e "${YELLOW}   (checksums.txt unavailable, skipping verification)${NC}"
fi

echo -e "${YELLOW}🔧 Installing...${NC}"

# Check if we need sudo
if [ -w "$INSTALL_DIR" ]; then
    SUDO=""
else
    echo -e "${YELLOW}   (may prompt for sudo password)${NC}"
    SUDO="sudo"
fi

$SUDO mkdir -p "$INSTALL_DIR"
$SUDO cp "${TMP_DIR}/mer" "${INSTALL_DIR}/mer"
$SUDO chmod +x "${INSTALL_DIR}/mer"

# Verify installation
if command -v mer &> /dev/null; then
    INSTALLED_VERSION=$(mer --version 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✅ merjs installed successfully!${NC}"
    echo ""
    echo "   Version: ${INSTALLED_VERSION}"
    echo "   Location: $(which mer)"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo "   mer init myapp    # Create a new project"
    echo "   mer dev           # Start dev server"
    echo ""
else
    echo -e "${YELLOW}⚠️  mer installed but not in PATH${NC}"
    echo "   Add this to your shell profile:"
    echo "   export PATH=\"${INSTALL_DIR}:\$PATH\""
fi

# Print quickstart
echo -e "${BLUE}Documentation:${NC} https://merjs.trilok.ai/docs"
echo -e "${BLUE}GitHub:${NC} https://github.com/${REPO}"
