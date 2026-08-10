#!/usr/bin/env bash
# setup-signing-secrets.sh — push macOS code-signing / notarization
# credentials into this repo's GitHub Actions secrets.
#
# Inputs (paths can be overridden via env vars):
#   MACOS_P12_PATH    pre-exported Developer ID Application .p12
#   NOTARY_P8_PATH    App Store Connect API key .p8
#   TAP_TOKEN         fine-grained PAT with contents:write on
#                     NovaShang/homebrew-tap — needed by release.yml's
#                     "Update cask in the Homebrew tap" step, which pushes
#                     to another repository and so cannot use GITHUB_TOKEN.
#                     Prompted for if unset; pass an empty line to skip.
#
# A .p12 with an empty export password is auto-re-encrypted with a fresh
# random password before being pushed; CI needs *some* password to import
# the .p12 into its temporary keychain. The new password is set as the
# MACOS_CERT_PASSWORD secret and never echoed.
#
# The .p12 is checked for a Developer ID Application identity before
# anything is pushed: this keychain also holds an unrelated, expired
# "Apple Distribution" certificate from another team, and a release signed
# with the wrong identity fails notarization only at the very end.

set -euo pipefail

TEAM_ID="7M23245ZBD"
NOTARY_KEY_ID="R2NW73H5TJ"
NOTARY_ISSUER_ID="0d7532d3-6b3c-4474-bd99-e99ecfffb04f"

CERT_DIR="${HOME}/Documents/个人项目/开发者证书"
MACOS_P12_PATH="${MACOS_P12_PATH:-${CERT_DIR}/Certificates1.p12}"
NOTARY_P8_PATH="${NOTARY_P8_PATH:-${CERT_DIR}/AuthKey_${NOTARY_KEY_ID}.p8}"

for f in "${MACOS_P12_PATH}" "${NOTARY_P8_PATH}"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing $f" >&2
    exit 1
  fi
done

echo "→ checking gh auth"
gh auth status >/dev/null

stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT

# Try empty password first; if it works we re-encrypt under a random
# password (it's bad form to ship an unprotected .p12 into CI). Otherwise
# prompt for the password the user set on export.
echo "→ probing .p12 password"
if openssl pkcs12 -legacy -in "${MACOS_P12_PATH}" -nokeys -passin "pass:" -noout 2>/dev/null; then
  echo "  source .p12 has no password; re-encrypting under a fresh random one"
  P12_PASS="$(openssl rand -base64 24)"
  # Two-step re-encrypt: dump to PEM in memory, repack with new password.
  # Skips touching the disk for the PEM (process substitution keeps it
  # in a fifo).
  REPACKED="${stage}/identity.p12"
  pem="${stage}/identity.pem"
  umask 077
  openssl pkcs12 -legacy -in "${MACOS_P12_PATH}" -nodes -passin "pass:" -out "${pem}" >/dev/null
  openssl pkcs12 -legacy -export -in "${pem}" -out "${REPACKED}" -password "pass:${P12_PASS}" -name "Bento Developer ID" >/dev/null
  rm -f "${pem}"
  P12_TO_PUSH="${REPACKED}"
else
  # Allow non-interactive use: P12_PASS env var (or stdin when not a tty).
  if [ -n "${P12_PASS:-}" ]; then
    : # already set in env
  elif [ -t 0 ]; then
    printf "Enter the password you set when exporting %s: " "$(basename "${MACOS_P12_PATH}")"
    stty -echo
    read -r P12_PASS
    stty echo
    printf "\n"
  else
    read -r P12_PASS
  fi
  if [ -z "${P12_PASS}" ]; then
    echo "ERROR: empty password rejected" >&2
    exit 1
  fi
  if ! openssl pkcs12 -legacy -in "${MACOS_P12_PATH}" -nokeys -passin "pass:${P12_PASS}" -noout 2>/dev/null; then
    echo "ERROR: that password does not unlock ${MACOS_P12_PATH}" >&2
    exit 1
  fi
  P12_TO_PUSH="${MACOS_P12_PATH}"
fi

# Confirm the .p12 really carries the Developer ID Application identity
# that release.yml's "Resolve signing identity" step greps for. Cheaper to
# fail here than 20 minutes into a release build.
echo "→ verifying the .p12 holds a Developer ID Application identity"
subjects="$(openssl pkcs12 -legacy -in "${P12_TO_PUSH}" -nokeys -passin "pass:${P12_PASS}" 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null || true)"
if ! printf '%s' "${subjects}" | grep -q "Developer ID Application"; then
  echo "ERROR: no 'Developer ID Application' certificate in ${MACOS_P12_PATH}" >&2
  echo "  found: ${subjects:-<nothing readable>}" >&2
  echo "  Re-export from Keychain Access: select the 'Developer ID" >&2
  echo "  Application: Chi On Ho (${TEAM_ID})' identity, right-click, Export." >&2
  exit 1
fi
echo "  ${subjects}"

echo "→ setting GitHub Actions secrets"
base64 -i "${P12_TO_PUSH}" | gh secret set MACOS_CERT_P12_BASE64
gh secret set MACOS_CERT_PASSWORD    --body "${P12_PASS}"
gh secret set MACOS_TEAM_ID          --body "${TEAM_ID}"
gh secret set APPLE_NOTARY_KEY_ID    --body "${NOTARY_KEY_ID}"
gh secret set APPLE_NOTARY_ISSUER_ID --body "${NOTARY_ISSUER_ID}"
gh secret set APPLE_NOTARY_KEY_P8    < "${NOTARY_P8_PATH}"

# The Homebrew tap lives in its own repository (Homebrew resolves a tap
# name by prepending "homebrew-", with no bare-name fallback), so the cask
# write-back is a cross-repo push and GITHUB_TOKEN will not reach it.
if [ -z "${TAP_TOKEN:-}" ] && [ -t 0 ]; then
  echo
  echo "HOMEBREW_TAP_TOKEN — fine-grained PAT, contents:write on"
  echo "NovaShang/homebrew-tap only. Create one at:"
  echo "  https://github.com/settings/personal-access-tokens/new"
  printf "Paste it (or press Enter to skip): "
  stty -echo
  read -r TAP_TOKEN
  stty echo
  printf "\n"
fi

if [ -n "${TAP_TOKEN:-}" ]; then
  gh secret set HOMEBREW_TAP_TOKEN --body "${TAP_TOKEN}"
  TAP_TOKEN=""
else
  echo "  skipped HOMEBREW_TAP_TOKEN — the release will publish, then fail"
  echo "  at the cask step, leaving the tap on the previous version."
fi

# Best-effort wipe.
P12_PASS=""

echo
echo "done. Secrets in this repo:"
gh secret list | grep -E "MACOS_|APPLE_NOTARY|HOMEBREW_TAP" || true
