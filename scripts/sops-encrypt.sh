#!/usr/bin/env bash
# Encrypt a plaintext secret file in-place with SOPS + Age.
# Usage: ./scripts/sops-encrypt.sh clusters/dev/secrets/my-secret.yaml
set -euo pipefail

FILE="${1:-}"
if [[ -z "$FILE" ]]; then
  echo "Usage: $0 <path-to-secret-file>"
  exit 1
fi

if [[ ! -f "$FILE" ]]; then
  echo "Error: file not found: $FILE"
  exit 1
fi

if sops --encrypted-regex '^(data|stringData)$' -e -i "$FILE"; then
  echo "Encrypted: $FILE"
else
  echo "Encryption failed for: $FILE"
  exit 1
fi
