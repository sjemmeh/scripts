#!/bin/bash

set -e

# Validate inputs
if [ $# -ne 2 ]; then
  echo "Usage: $0 <hostname> <ip>"
  echo "Example: $0 scrypted.local 10.0.0.6"
  exit 1
fi

HOSTNAME="$1"
IP="$2"
OUTPUT_DIR="./$HOSTNAME"
KEY_FILE="${OUTPUT_DIR}/${HOSTNAME}.key"
CRT_FILE="${OUTPUT_DIR}/${HOSTNAME}.crt"
CONF_FILE="$(mktemp)"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Create OpenSSL config with IP SAN and DNS
cat > "$CONF_FILE" <<EOF
[req]
default_bits       = 4096
distinguished_name = req_distinguished_name
req_extensions     = req_ext
x509_extensions    = v3_ca
prompt             = no
default_md         = sha256

[req_distinguished_name]
CN = $HOSTNAME

[req_ext]
subjectAltName = @alt_names

[v3_ca]
subjectAltName = @alt_names
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
IP.1 = $IP
DNS.1 = $HOSTNAME
EOF

# Generate cert and key
openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
  -keyout "$KEY_FILE" \
  -out "$CRT_FILE" \
  -config "$CONF_FILE"

echo "Certificate and key generated:"
echo "  - $CRT_FILE"
echo "  - $KEY_FILE"

# Clean up
rm -f "$CONF_FILE"
