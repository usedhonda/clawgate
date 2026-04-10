#!/bin/bash
# Setup self-signed code signing certificate for ClawGate development.
# This eliminates the need to re-grant AX permission after every rebuild.
#
# Usage: ./scripts/setup-cert.sh [--reset] [--non-interactive] [--keychain-password <password>]
#
# Uses macOS built-in LibreSSL (/usr/bin/openssl) to create P12 files
# compatible with macOS Security.framework. Homebrew OpenSSL 3.x creates
# P12 files that `security import` rejects.

set -euo pipefail

CERT_NAME="ClawGate Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CERT_DIR="/tmp/clawgate-cert-setup"
OPENSSL=/usr/bin/openssl
RESET=false
NON_INTERACTIVE=false
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)
      RESET=true; shift ;;
    --non-interactive)
      NON_INTERACTIVE=true; shift ;;
    --keychain-password)
      KEYCHAIN_PASSWORD="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: ./scripts/setup-cert.sh [--reset] [--non-interactive] [--keychain-password <password>]" >&2
      exit 2 ;;
  esac
done

# --- Step 1: Check if we already have a valid identity ---
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  if [[ "$RESET" != "true" ]]; then
    # Ensure non-interactive codesign access is configured even when cert already exists.
    if [[ -n "$KEYCHAIN_PASSWORD" ]]; then
      security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
      security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
    fi
    echo ""
    echo "=== '$CERT_NAME' is already installed and trusted ==="
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    echo ""
    echo "No action needed. Re-run with --reset only when certificate is broken."
    exit 0
  fi
fi

if [[ "$RESET" == "true" ]]; then
  # --- Step 0: Nuke ALL existing "ClawGate Dev" items (certs, keys, identities) ---
  echo "=== Cleaning up ALL existing '$CERT_NAME' items ==="

  # Delete identities (cert + key pairs) — may fail if ambiguous, that's fine
  security delete-identity -c "$CERT_NAME" 2>/dev/null || true
  security delete-identity -c "$CERT_NAME" 2>/dev/null || true
  security delete-identity -c "$CERT_NAME" 2>/dev/null || true

  # Delete any remaining certificates by SHA-1 hash (handles duplicates)
  while true; do
    HASH=$(security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null \
      | grep "SHA-1" | awk '{print $NF}' | head -1 || true)
    if [ -z "$HASH" ]; then break; fi
    if security delete-certificate -Z "$HASH" "$KEYCHAIN" 2>/dev/null; then
      echo "  Deleted cert $HASH"
    else
      break
    fi
  done

  # Delete orphaned private keys by label
  security delete-key -l "$CERT_NAME" 2>/dev/null || true
  security delete-key -l "$CERT_NAME" 2>/dev/null || true
  security delete-key -l "$CERT_NAME" 2>/dev/null || true

  echo "  Cleanup done"

  # Re-check after cleanup
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo ""
    echo "Cleanup did not remove all '$CERT_NAME' identities. Resolve manually." >&2
    exit 1
  fi
fi

# --- Step 2: Generate certificate using LibreSSL ---
rm -rf "$CERT_DIR"
mkdir -p "$CERT_DIR"

echo "=== Creating certificate with LibreSSL ($($OPENSSL version)) ==="

cat > "$CERT_DIR/cert.cfg" <<'EOF'
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_code_sign

[ dn ]
CN = ClawGate Dev

[ v3_code_sign ]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:false
EOF

$OPENSSL req -x509 -newkey rsa:2048 \
  -keyout "$CERT_DIR/key.pem" \
  -out "$CERT_DIR/cert.pem" \
  -days 3650 -nodes \
  -config "$CERT_DIR/cert.cfg" 2>/dev/null

echo "  Certificate generated (valid 10 years)"

# --- Step 3: Create P12 using LibreSSL ---
$OPENSSL pkcs12 -export \
  -out "$CERT_DIR/cert.p12" \
  -inkey "$CERT_DIR/key.pem" \
  -in "$CERT_DIR/cert.pem" \
  -passout pass:clawgate

echo "  P12 bundle created"

# --- Step 4: Unlock keychain + Import ---
if [[ -n "$KEYCHAIN_PASSWORD" ]]; then
  echo "  Unlocking keychain with provided password..."
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
else
  echo "  Unlocking keychain (may prompt for login password)..."
  security unlock-keychain "$KEYCHAIN"
fi

security import "$CERT_DIR/cert.p12" \
  -k "$KEYCHAIN" \
  -P "clawgate" \
  -T /usr/bin/codesign

echo "  Imported to login keychain"

# Allow non-interactive codesign access to private key.
if [[ -n "$KEYCHAIN_PASSWORD" ]]; then
  if security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "  Key partition list configured (codesign prompt suppression)"
  else
    echo "  WARN: Failed to set key partition list automatically" >&2
  fi
fi

# --- Step 5: Trust the certificate ---
# Self-signed certs need explicit trust for codesign to accept them.
# Try CLI first (needs GUI auth dialog), fall back to manual instructions.
echo ""
echo "=== Trust setting ==="
echo "  Trying CLI trust..."
if security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$CERT_DIR/cert.pem" 2>/dev/null; then
  echo "  Trusted via CLI"
else
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    echo "  WARN: CLI trust failed in non-interactive mode. Manual trust may be required." >&2
  else
  echo ""
  echo "  CLI trust failed. Please trust manually in Keychain Access:"
  echo ""
  echo "    1. Search 'ClawGate Dev' (there should be exactly ONE certificate)"
  echo "    2. Double-click it"
  echo "    3. Expand 'Trust'"
  echo "    4. Set 'Code Signing' -> 'Always Trust'"
  echo "    5. Close (enter login password)"
  echo ""
  open -a "Keychain Access"
  echo "  Press Enter after trusting..."
  read -r
  fi
fi

# --- Step 6: Cleanup temp files ---
rm -rf "$CERT_DIR"

# --- Step 7: Verify ---
echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "=== SUCCESS ==="
  security find-identity -v -p codesigning | grep "$CERT_NAME"
  echo ""
  echo "Sign with:"
  echo "  codesign --force --deep --options runtime --entitlements ClawGate.entitlements --sign \"$CERT_NAME\" ClawGate.app"
else
  echo "=== FAILED ==="
  echo "'$CERT_NAME' not found as valid codesigning identity."
  echo "Ensure trust is set to 'Always Trust' in Keychain Access."
  exit 1
fi
