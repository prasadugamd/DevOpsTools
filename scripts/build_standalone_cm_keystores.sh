#!/usr/bin/env bash
#
# build_standalone_cm_keystores.sh
#
# Build Cloudera Manager standalone cluster keystores from A1 customer-signed certs.
# Supports UAT environments uat-01 through uat-06 via --uat / UAT_ID.
#
# Outputs:
#   cm-ui.jks              - CM UI (7183) + agent RPC server (7182)
#   cm-ui-trust.jks        - CM truststore (A1 CAs + optional amdocs-internal-ca)
#   hue-fullchain.pem      - Hue TLS (PEM, same host / co-located Hue)
#   hue-server.key         - Hue private key (copy of leaf key)
#   root.pem, issuing.pem  - CA PEMs for agent CAcerts / Hue ssl_cacerts
#
# Usage:
#   ./build_standalone_cm_keystores.sh --uat 05
#   ./build_standalone_cm_keystores.sh --uat 03 --generate-csr
#   UAT_ID=06 ./build_standalone_cm_keystores.sh
#
set -euo pipefail

# =============================================================================
# Global settings (not UAT-specific)
# =============================================================================
WORKDIR="${WORKDIR:-$(pwd)}"
OUTPUT_DIR="${OUTPUT_DIR:-${WORKDIR}/output}"

UAT_ID="${UAT_ID:-}"
UAT_DOMAIN="${UAT_DOMAIN:-uat.corp.amdocs.azr}"

ISSUING_CA="${ISSUING_CA:-A1-Telekom-Austria-AG-IssuingCA01-Silver.cer}"
ROOT_CA="${ROOT_CA:-A1-Telekom-Austria-AG-RootCA-Silver.cer}"

KEYSTORE_PASS="${KEYSTORE_PASS:-changeit}"
KEY_ALIAS="${KEY_ALIAS:-cm-ui}"
AMDOCSCA_PEM="${AMDOCSCA_PEM:-amdocs-internal-ca.pem}"

# Set by apply_uat_defaults() after UAT_ID is known:
LEAF_CERT=""
LEAF_KEY=""
CSR_CONF=""
CSR_CN=""
CSR_DNS01=""
CSR_DNS02=""
CSR_DNS03=""
CSR_FILE=""
BUNDLE_NAME=""

MODE="build"
SKIP_AMDCS=false

# =============================================================================
# Helpers
# =============================================================================
log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

normalize_uat_id() {
  local raw="${1#uat-}"   # allow "05" or "uat-05"
  raw="${raw#UAT-}"
  raw="${raw#0}"          # "05" -> "5" temporarily
  [[ "$raw" =~ ^[1-6]$ ]] || die "UAT_ID must be 01-06 (got: $1)"
  printf '%02d' "$raw"
}

apply_uat_defaults() {
  [[ -n "$UAT_ID" ]] || die "UAT_ID is required. Use: --uat 01|02|03|04|05|06 or export UAT_ID=05"

  UAT_ID="$(normalize_uat_id "$UAT_ID")"

  local prefix="uat-${UAT_ID}"
  local cm_alias="cm-uat-${UAT_ID}"

  LEAF_CERT="${LEAF_CERT:-${cm_alias}.cer}"
  LEAF_KEY="${LEAF_KEY:-${cm_alias}.key}"
  CSR_CONF="${CSR_CONF:-${cm_alias}_csr.conf}"
  CSR_FILE="${CSR_FILE:-${cm_alias}.csr}"

  # SAN index 01 / 02 / 03 (derived from UAT_ID)
  CSR_CN="${CSR_CN:-${cm_alias}.${UAT_DOMAIN}}"
  CSR_DNS01="${CSR_DNS01:-${prefix}-cloudera}"
  CSR_DNS02="${CSR_DNS02:-${prefix}-cloudera.${UAT_DOMAIN}}"
  CSR_DNS03="${CSR_DNS03:-${cm_alias}.${UAT_DOMAIN}}"

  OUTPUT_DIR="${OUTPUT_DIR:-${WORKDIR}/output-uat-${UAT_ID}}"
  BUNDLE_NAME="standalone-cm-uat-${UAT_ID}-keystore-bundle.tar.gz"

  log "UAT environment: uat-${UAT_ID}"
  log "  Leaf cert:  ${LEAF_CERT}"
  log "  Leaf key:   ${LEAF_KEY}"
  log "  DNS.01:     ${CSR_DNS01}"
  log "  DNS.02:     ${CSR_DNS02}"
  log "  DNS.03:     ${CSR_DNS03}"
  log "  CN:         ${CSR_CN}"
}

cer_to_pem() {
  local infile="$1"
  local outfile="$2"
  if openssl x509 -in "$infile" -noout 2>/dev/null; then
    cp "$infile" "$outfile"
  else
    openssl x509 -inform DER -in "$infile" -out "$outfile"
  fi
}

# Compare cert and key (OpenSSL 1.x/3.x compatible — pkey -modulus not available everywhere)
verify_key_matches_cert() {
  local leaf_pem="$1"
  local key_file="$2"
  local cert_fp key_fp

  if key_mod=$(openssl rsa -in "$key_file" -noout -modulus 2>/dev/null | openssl md5); then
    cert_mod=$(openssl x509 -in "$leaf_pem" -noout -modulus | openssl md5)
    [[ "$cert_mod" == "$key_mod" ]] && return 0
  fi

  cert_fp=$(openssl x509 -in "$leaf_pem" -noout -pubkey | openssl md5 | awk '{print $NF}')
  if openssl rsa -in "$key_file" -noout 2>/dev/null; then
    key_fp=$(openssl rsa -in "$key_file" -pubout 2>/dev/null | openssl md5 | awk '{print $NF}')
  else
    key_fp=$(openssl pkey -in "$key_file" -pubout 2>/dev/null | openssl md5 | awk '{print $NF}')
  fi
  [[ "$cert_fp" == "$key_fp" ]] || die "Private key does not match leaf certificate"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") --uat <01|02|03|04|05|06> [OPTIONS]

Required:
  --uat ID          UAT environment id: 01, 02, 03, 04, 05, or 06
                    (or export UAT_ID=05)

Options:
  --generate-csr    Generate CSR + private key only (submit to A1 PKI)
  --workdir DIR     Working directory (default: current directory)
  --output DIR      Output directory (default: ./output-uat-<ID>)
  --leaf-cert FILE  Override signed leaf certificate filename
  --leaf-key FILE   Override private key filename
  --domain DOMAIN   DNS domain suffix (default: uat.corp.amdocs.azr)
  --skip-amdocs-ca  Skip amdocs-internal-ca in truststore

Environment variables:
  UAT_ID, UAT_DOMAIN, WORKDIR, OUTPUT_DIR, LEAF_CERT, LEAF_KEY
  CSR_DNS01, CSR_DNS02, CSR_DNS03, CSR_CN (override auto-generated SANs)
  KEYSTORE_PASS, KEY_ALIAS

Naming pattern (auto-generated for --uat 05):
  Files:     cm-uat-05.cer, cm-uat-05.key
  DNS.01:    uat-05-cloudera
  DNS.02:    uat-05-cloudera.uat.corp.amdocs.azr
  DNS.03:    cm-uat-05.uat.corp.amdocs.azr
  CM URL:    https://cm-uat-05.uat.corp.amdocs.azr:7183

Examples:
  cd /pciuser/tools/jenkins/.../UAT5
  ./build_standalone_cm_keystores.sh --uat 05

  ./build_standalone_cm_keystores.sh --uat 03 --generate-csr
  ./build_standalone_cm_keystores.sh --uat 03
EOF
}

generate_csr() {
  apply_uat_defaults

  log "Generating CSR configuration: ${CSR_CONF}"
  cat > "${WORKDIR}/${CSR_CONF}" <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = v3_req

[ dn ]
C  = US
ST = Illinois
L  = Chicago
O  = Amdocs
OU = Infra Security
CN = ${CSR_CN}

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${CSR_DNS01}
DNS.2 = ${CSR_DNS02}
DNS.3 = ${CSR_DNS03}
EOF

  log "Generating private key: ${LEAF_KEY}"
  openssl genrsa -out "${WORKDIR}/${LEAF_KEY}" 4096
  chmod 600 "${WORKDIR}/${LEAF_KEY}"

  log "Generating CSR: ${CSR_FILE}"
  openssl req -new \
    -key "${WORKDIR}/${LEAF_KEY}" \
    -out "${WORKDIR}/${CSR_FILE}" \
    -config "${WORKDIR}/${CSR_CONF}"

  log "SANs in CSR:"
  openssl req -in "${WORKDIR}/${CSR_FILE}" -noout -text | grep -A5 "Subject Alternative Name" || true

  log "Done. Submit ${CSR_FILE} to A1 PKI."
  log "After receiving signed ${LEAF_CERT}, run:"
  log "  ./build_standalone_cm_keystores.sh --uat ${UAT_ID}"
}

build_keystores() {
  apply_uat_defaults
  need_cmd openssl
  need_cmd keytool

  cd "$WORKDIR"

  [[ -f "$LEAF_CERT" ]]  || die "Leaf certificate not found: ${WORKDIR}/${LEAF_CERT}"
  [[ -f "$LEAF_KEY" ]]   || die "Private key not found: ${WORKDIR}/${LEAF_KEY}"
  [[ -f "$ISSUING_CA" ]] || die "Issuing CA not found: ${ISSUING_CA}"
  [[ -f "$ROOT_CA" ]]    || die "Root CA not found: ${ROOT_CA}"

  mkdir -p "$OUTPUT_DIR"
  local leaf_pem="${OUTPUT_DIR}/leaf.pem"
  local issuing_pem="${OUTPUT_DIR}/issuing.pem"
  local root_pem="${OUTPUT_DIR}/root.pem"

  log "Converting certificates to PEM..."
  cer_to_pem "$LEAF_CERT" "$leaf_pem"
  cer_to_pem "$ISSUING_CA" "$issuing_pem"
  cer_to_pem "$ROOT_CA" "$root_pem"

  log "Verifying certificate chain..."
  openssl verify -CAfile "$root_pem" -untrusted "$issuing_pem" "$leaf_pem"

  log "Leaf certificate details:"
  openssl x509 -in "$leaf_pem" -noout -subject -issuer -dates
  openssl x509 -in "$leaf_pem" -noout -ext subjectAltName || true

  log "Verifying private key matches certificate..."
  verify_key_matches_cert "$leaf_pem" "$LEAF_KEY"

  log "Building PKCS12 / cm-ui.jks..."
  local p12="${OUTPUT_DIR}/cm-ui.p12"
  local jks="${OUTPUT_DIR}/cm-ui.jks"
  rm -f "$p12" "$jks"

  openssl pkcs12 -export \
    -in "$leaf_pem" \
    -inkey "$LEAF_KEY" \
    -certfile "$issuing_pem" \
    -name "$KEY_ALIAS" \
    -out "$p12" \
    -passout pass:"$KEYSTORE_PASS"

  keytool -importkeystore -noprompt \
    -srckeystore "$p12" -srcstoretype PKCS12 -srcstorepass "$KEYSTORE_PASS" \
    -destkeystore "$jks" -deststoretype JKS -deststorepass "$KEYSTORE_PASS" \
    -destkeypass "$KEYSTORE_PASS" \
    -srcalias "$KEY_ALIAS" -destalias "$KEY_ALIAS"

  keytool -importcert -noprompt \
    -alias a1-root-ca \
    -file "$root_pem" \
    -keystore "$jks" \
    -storepass "$KEYSTORE_PASS"

  log "Building cm-ui-trust.jks..."
  local trust_jks="${OUTPUT_DIR}/cm-ui-trust.jks"
  rm -f "$trust_jks"

  keytool -importcert -noprompt \
    -alias a1-issuing-ca \
    -file "$issuing_pem" \
    -keystore "$trust_jks" \
    -storepass "$KEYSTORE_PASS"

  keytool -importcert -noprompt \
    -alias a1-root-ca \
    -file "$root_pem" \
    -keystore "$trust_jks" \
    -storepass "$KEYSTORE_PASS"

  if [[ "$SKIP_AMDCS" != true && -f "${WORKDIR}/${AMDOCSCA_PEM}" ]]; then
    log "Importing amdocs-internal-ca into truststore..."
    keytool -importcert -noprompt \
      -alias amdocs-internal-ca \
      -file "${WORKDIR}/${AMDOCSCA_PEM}" \
      -keystore "$trust_jks" \
      -storepass "$KEYSTORE_PASS"
  else
    log "WARN: ${AMDOCSCA_PEM} not found — add amdocs-internal-ca for agent mutual TLS"
  fi

  log "Building Hue PEM bundle..."
  local hue_chain="${OUTPUT_DIR}/hue-fullchain.pem"
  local hue_key="${OUTPUT_DIR}/hue-server.key"
  cat "$leaf_pem" "$issuing_pem" "$root_pem" > "$hue_chain"
  cp "$LEAF_KEY" "$hue_key"
  chmod 600 "$hue_key"

  cp "$root_pem" "${OUTPUT_DIR}/A1-RootCA.pem"
  cp "$issuing_pem" "${OUTPUT_DIR}/A1-IssuingCA.pem"

  log "Validating keystores..."
  keytool -list -keystore "$jks" -storepass "$KEYSTORE_PASS" | head -20
  keytool -list -keystore "$trust_jks" -storepass "$KEYSTORE_PASS"
  keytool -list -v -keystore "$jks" -storepass "$KEYSTORE_PASS" -alias "$KEY_ALIAS" | grep -A8 "SAN:" || true

  local bundle="${OUTPUT_DIR}/${BUNDLE_NAME}"
  tar czf "$bundle" -C "$OUTPUT_DIR" \
    cm-ui.jks cm-ui-trust.jks hue-fullchain.pem hue-server.key \
    root.pem issuing.pem leaf.pem A1-RootCA.pem A1-IssuingCA.pem 2>/dev/null || \
  tar czf "$bundle" -C "$OUTPUT_DIR" \
    cm-ui.jks cm-ui-trust.jks hue-fullchain.pem hue-server.key root.pem issuing.pem

  rm -f "$p12"

  log "=============================================="
  log "BUILD COMPLETE — uat-${UAT_ID} → ${OUTPUT_DIR}/"
  log "=============================================="
  ls -la "${OUTPUT_DIR}/cm-ui.jks" "${OUTPUT_DIR}/cm-ui-trust.jks" "${OUTPUT_DIR}/hue-fullchain.pem"
  log ""
  log "CM URL:  https://${CSR_DNS03}:7183"
  log "Agent:   server_host=${CSR_DNS02}"
  log "Bundle:  ${bundle}"
}

# =============================================================================
# Main — parse args
# =============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uat|-u)       UAT_ID="$2"; shift ;;
    --generate-csr) MODE="csr" ;;
    --workdir)      WORKDIR="$2"; shift ;;
    --output)       OUTPUT_DIR="$2"; shift ;;
    --leaf-cert)    LEAF_CERT="$2"; shift ;;
    --leaf-key)     LEAF_KEY="$2"; shift ;;
    --domain)       UAT_DOMAIN="$2"; shift ;;
    --skip-amdocs-ca) SKIP_AMDCS=true ;;
    --help|-h)      usage; exit 0 ;;
    *)              die "Unknown option: $1 (use --help)" ;;
  esac
  shift
done

if [[ "$MODE" == "csr" ]]; then
  need_cmd openssl
  generate_csr
else
  build_keystores
fi
