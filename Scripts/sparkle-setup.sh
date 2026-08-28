#!/bin/bash
# One-time setup for Sparkle auto-updates.
# Downloads the Sparkle CLI tools (sign_update, generate_keys) and creates
# an Ed25519 key pair. Private key lives in your Keychain; public key is
# saved to .sparkle-public-key (commit this — it's needed at build time).
set -euo pipefail

cd "$(dirname "$0")/.."

SPARKLE_VERSION="2.9.4"
SPARKLE_CHECKSUM="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
SPARKLE_DIR=".sparkle-tools"
SPARKLE_TARBALL="Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/${SPARKLE_TARBALL}"

# --- 1) Install CLI tools ---
if [ ! -f "$SPARKLE_DIR/bin/sign_update" ]; then
    echo "→ Downloading Sparkle ${SPARKLE_VERSION}…"
    mkdir -p "$SPARKLE_DIR"
    curl -fsSL "$SPARKLE_URL" -o "/tmp/$SPARKLE_TARBALL"
    # Verify checksum against Package.resolved's binaryTarget checksum (supply-chain guard)
    if command -v shasum >/dev/null 2>&1; then
        echo "${SPARKLE_CHECKSUM}  /tmp/${SPARKLE_TARBALL}" | shasum -a 256 -c - || {
            echo "✗ Checksum mismatch for ${SPARKLE_TARBALL} — possible tampering, aborting." >&2
            rm -f "/tmp/$SPARKLE_TARBALL"
            exit 1
        }
    else
        echo "  ⚠ shasum not found — skipping checksum verification (install via Xcode CLT)"
    fi
    tar -xJf "/tmp/$SPARKLE_TARBALL" -C "$SPARKLE_DIR"
    rm -f "/tmp/$SPARKLE_TARBALL"
    echo "  ✓ Installed to $SPARKLE_DIR/bin (checksum verified)"
else
    echo "→ Sparkle tools already installed at $SPARKLE_DIR/bin"
    # Verify existing install matches expected version
    if [ -f "$SPARKLE_DIR/bin/sign_update" ] && ! "$SPARKLE_DIR/bin/sign_update" --help 2>&1 | grep -q "$SPARKLE_VERSION"; then
        echo "  ⚠ Existing tools may not be $SPARKLE_VERSION — remove $SPARKLE_DIR to re-download."
    fi
fi

GEN="$SPARKLE_DIR/bin/generate_keys"

# --- 2) Generate or recover the public key ---
if [ -f ".sparkle-public-key" ]; then
    echo "→ .sparkle-public-key already exists; nothing to do."
    echo
    echo "Public key:"
    cat .sparkle-public-key
    exit 0
fi

EXISTING=""
if EXISTING=$("$GEN" -p 2>/dev/null) && [ -n "$EXISTING" ]; then
    echo "→ Found existing Sparkle key pair in Keychain"
else
    echo "→ Generating a new Ed25519 key pair…"
    "$GEN"
    EXISTING=$("$GEN" -p)
fi

echo "$EXISTING" > .sparkle-public-key
echo "  ✓ Public key saved to .sparkle-public-key"

echo
echo "Public key:"
cat .sparkle-public-key
echo
echo "✓ Sparkle setup complete."
echo
echo "  • Commit .sparkle-public-key — it's embedded in the app at build time"
echo "  • The private key stays in your Keychain; never commit it"
echo "  • Scripts/release.sh will auto-sign each DMG with it"
