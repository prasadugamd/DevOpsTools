#!/usr/bin/env bash
#
# jenkins-tls-enablement.sh
# End-to-end automation for Jenkins HTTPS (TLS) on Amdocs Jenkins servers.
# Author: Prasadu Gamini
# See: Jenkins TLS Enablement.md
#
# Usage:
#   ./jenkins-tls-enablement.sh --env pet generate-csr
#   ./jenkins-tls-enablement.sh --env pet build-keystore
#   ./jenkins-tls-enablement.sh --env pet configure
#   ./jenkins-tls-enablement.sh --env pet firewall
#   ./jenkins-tls-enablement.sh --env pet restart
#   ./jenkins-tls-enablement.sh --env pet verify
#   ./jenkins-tls-enablement.sh --env uat all
#
# Prerequisites:
#   openssl, java-*-openjdk-devel (provides keytool)
#
# Environment variables:
#   JENKINS_KEYSTORE_PASSWORD  Keystore password (default: changeit)
#   JENKINS_ADMIN_EMAIL        Admin email for CASC location config
#   JENKINS_VM_FQDN            Override VM FQDN for CSR SAN (DNS.2) and verify output
#   KEYTOOL                    Optional path to keytool (default: from PATH)
#

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly HTTPS_PORT=8443
readonly JENKINS_HOME="/pciuser/tools/jenkins/jenkins-production"
readonly CASC_CONFIG="${JENKINS_HOME}/casc_configs"
readonly LOCATION_CONFIG="${CASC_CONFIG}/jenkins-basic-configuration/location-config.yaml"
readonly OVERRIDE_CONF="/etc/systemd/system/jenkins.service.d/override.conf"
readonly CA_INTERMEDIATE="A1-Telekom-Austria-AG-IssuingCA01-Silver.cer"
readonly CA_ROOT="A1-Telekom-Austria-AG-RootCA-Silver.cer"

ENV=""
CERT_DIR=""
CERT_DIR_OVERRIDE=""
VM_HOST=""
VM_FQDN=""
VM_FQDN_OVERRIDE="${JENKINS_VM_FQDN:-}"
JENKINS_CN=""
ENV_UPPER=""
KEYSTORE_PASSWORD="${JENKINS_KEYSTORE_PASSWORD:-changeit}"
ADMIN_EMAIL="${JENKINS_ADMIN_EMAIL:-example@amdocs.com}"
DRY_RUN=false
SKIP_CSR=false
SKIP_FIREWALL=false
SKIP_RESTART=false
FIREWALL_MODE="open-port"  # open-port | disable
KEYTOOL="${KEYTOOL:-}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*" >&2; }
die()  { log "ERROR $*" >&2; exit 1; }

run() {
    if [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] $*"
    else
        info "Running: $*"
        "$@"
    fi
}

run_sudo() {
    if [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] sudo $*"
    else
        info "Running: sudo $*"
        sudo "$@"
    fi
}

is_root() {
    [[ "$(id -u)" -eq 0 ]]
}

require_root() {
    is_root && return 0
    die "This step requires root/sudo. The jenkins user cannot run it.
Run from bastion (or any sudo-enabled account):

  cd ${CERT_DIR}
  sudo ./${SCRIPT_NAME} --env ${ENV} ${COMMAND:-configure}

Privileged commands: configure | firewall | restart"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

resolve_keytool() {
    # 1) Explicit override (--keytool or KEYTOOL env)
    if [[ -n "$KEYTOOL" ]]; then
        [[ -x "$KEYTOOL" ]] || die "keytool not executable: $KEYTOOL"
        info "Using keytool: $KEYTOOL"
        return 0
    fi

    # 2) Standard PATH lookup
    if command -v keytool >/dev/null 2>&1; then
        KEYTOOL="$(command -v keytool)"
        info "Using keytool: $KEYTOOL"
        return 0
    fi

    # 3) Common RHEL/OpenJDK fallback
    local candidate
    for candidate in /usr/lib/jvm/*/bin/keytool; do
        if [[ -x "$candidate" ]]; then
            KEYTOOL="$candidate"
            info "Using keytool: $KEYTOOL"
            return 0
        fi
    done

    die "keytool not found. Install Java JDK (devel package), then retry:
  sudo yum install -y java-17-openjdk-devel
  which keytool
Or set: export KEYTOOL=/usr/bin/keytool"
}

resolve_java_home() {
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
        info "Using JAVA_HOME: $JAVA_HOME"
        return 0
    fi
    local java_bin
    java_bin="$(command -v java 2>/dev/null || true)"
    [[ -n "$java_bin" ]] || die "java not found. Install: yum install -y java-17-openjdk java-17-openjdk-devel"
    java_bin="$(readlink -f "$java_bin")"
    JAVA_HOME="$(dirname "$(dirname "$java_bin")")"
    info "Using JAVA_HOME: $JAVA_HOME"
}

# ---------------------------------------------------------------------------
# Environment presets
# ---------------------------------------------------------------------------
load_env_preset() {
    local env="$1"
    case "$env" in
        pet)
            VM_HOST="vm-jenkins-pet-we-001"
            JENKINS_CN="jenkins.pet.corp.amdocs.azr"
            ENV_UPPER="PET"
            CERT_DIR="${JENKINS_HOME}/pet-corp-amdocs-azr/PET-JENKINS"
            ;;
        prod)
            VM_HOST="vm-jenkins-prod-we-001"
            JENKINS_CN="jenkins.prod.corp.amdocs.azr"
            ENV_UPPER="PROD"
            CERT_DIR="${JENKINS_HOME}/prod-corp-amdocs-azr/PROD-JENKINS"
            ;;
        int)
            VM_HOST="vm-jenkins-int-we-001"
            JENKINS_CN="jenkins.int.corp.amdocs.azr"
            ENV_UPPER="INT"
            CERT_DIR="${JENKINS_HOME}/int-corp-amdocs-azr/INT-JENKINS"
            ;;
        uat)
            VM_HOST="vm-jenkins-uat-we-001"
            JENKINS_CN="jenkins.uat.corp.amdocs.azr"
            ENV_UPPER="UAT"
            CERT_DIR="${JENKINS_HOME}/uat-corp-amdocs-azr/UAT-JENKINS"
            ;;
        *)
            die "Unknown environment: $env (use: pet, prod, int, uat)"
            ;;
    esac
    ENV="$env"
}

# Derived paths (set after load_env_preset)
set_paths() {
    PREFIX="jenkins-${ENV}"
    CSR_CONF="${CERT_DIR}/${PREFIX}-csr.conf"
    KEY_FILE="${CERT_DIR}/${PREFIX}.key"
    CSR_FILE="${CERT_DIR}/${PREFIX}.csr"
    LEAF_CERT="${CERT_DIR}/${PREFIX}.cer"
    FULLCHAIN="${CERT_DIR}/${PREFIX}-fullchain.cer"
    P12_FILE="${CERT_DIR}/${PREFIX}.p12"
    JKS_FILE="${CERT_DIR}/${PREFIX}.jks"
    ALIAS="${PREFIX}"
    CHAIN_TXT="${CERT_DIR}/jenkins-cert-chain.txt"
    JENKINS_URL="https://${JENKINS_CN}:${HTTPS_PORT}"
    VM_FQDN="${VM_FQDN_OVERRIDE:-${VM_HOST}.${ENV}.corp.amdocs.azr}"
}

usage() {
    cat <<EOF
${SCRIPT_NAME} — Jenkins TLS enablement automation

Usage:
  ${SCRIPT_NAME} --env uat COMMAND
  ${SCRIPT_NAME} uat COMMAND              # shorthand (env as first argument)

Commands:
  generate-csr    Create CSR config and generate private key + CSR          [jenkins user]
  build-keystore  Build full chain, PKCS12, JKS, validate, set permissions  [jenkins user]
  configure       Write systemd override.conf and CASC location-config.yaml   [root/bastion]
  firewall        Configure firewalld for port ${HTTPS_PORT}                  [root/bastion]
  restart         Reload systemd and restart Jenkins                          [root/bastion]
  verify          Run local validation checks
  all             Full flow — build-keystore as jenkins; configure/restart as root/bastion

Options:
  --env ENV              Environment: pet | prod | int | uat (required)
  --cert-dir PATH        Override certificate directory
  --vm-fqdn FQDN         Override VM FQDN for CSR SAN DNS.2 (default: vm-jenkins-<env>-we-001.<env>.corp.amdocs.azr)
  --keytool PATH         Optional path to keytool (default: PATH, then /usr/lib/jvm/*/bin/keytool)
  --keystore-password P  Keystore password (default: changeit or \$JENKINS_KEYSTORE_PASSWORD)
  --admin-email EMAIL    Admin email for location-config.yaml
  --skip-csr             Skip CSR generation in 'all' mode
  --skip-firewall        Skip firewall configuration
  --skip-restart         Skip Jenkins restart
  --disable-firewalld    Disable firewalld instead of opening port ${HTTPS_PORT}
  --dry-run              Print commands without executing
  -h, --help             Show this help

Examples:
  # As jenkins user — keystore only
  ${SCRIPT_NAME} --env uat build-keystore

  # As bastion user — HTTPS config + restart
  sudo ${SCRIPT_NAME} --env uat configure
  sudo ${SCRIPT_NAME} --env uat firewall
  sudo ${SCRIPT_NAME} --env uat restart

  # Full flow (run build-keystore as jenkins, then remaining steps as bastion)
  ${SCRIPT_NAME} --env uat --skip-csr build-keystore
  sudo ${SCRIPT_NAME} --env uat configure
  sudo ${SCRIPT_NAME} --env uat firewall
  sudo ${SCRIPT_NAME} --env uat restart
  ${SCRIPT_NAME} --env uat verify

Manual step (cannot be automated):
  Submit ${CSR_FILE:-jenkins-<env>.csr} to A1 PKI and place signed certs in cert directory:
    - jenkins-<env>.cer
    - ${CA_INTERMEDIATE}
    - ${CA_ROOT}

EOF
}

parse_args() {
    local cmd=""

    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    for arg in "$@"; do
        if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env)           ENV="$2"; shift 2 ;;
            --cert-dir)      CERT_DIR_OVERRIDE="$2"; shift 2 ;;
            --vm-fqdn)       VM_FQDN_OVERRIDE="$2"; shift 2 ;;
            --keytool)       KEYTOOL="$2"; shift 2 ;;
            --keystore-password) KEYSTORE_PASSWORD="$2"; shift 2 ;;
            --admin-email)   ADMIN_EMAIL="$2"; shift 2 ;;
            --skip-csr)      SKIP_CSR=true; shift ;;
            --skip-firewall) SKIP_FIREWALL=true; shift ;;
            --skip-restart)  SKIP_RESTART=true; shift ;;
            --disable-firewalld) FIREWALL_MODE="disable"; shift ;;
            --dry-run)       DRY_RUN=true; shift ;;
            -h|--help)       usage; exit 0 ;;
            pet|prod|int|uat)
                [[ -z "$ENV" ]] || die "Environment specified twice: $ENV and $1"
                ENV="$1"
                shift
                ;;
            generate-csr|build-keystore|configure|firewall|restart|verify|all)
                cmd="$1"; shift ;;
            *) die "Unknown argument: $1 (use --help)" ;;
        esac
    done

    [[ -n "$ENV" ]] || die "--env is required (pet | prod | int | uat)\nExample: ${SCRIPT_NAME} uat all --skip-csr"
    load_env_preset "$ENV"
    if [[ -n "$CERT_DIR_OVERRIDE" ]]; then
        CERT_DIR="$CERT_DIR_OVERRIDE"
    fi
    set_paths
    COMMAND="${cmd:-}"
    [[ -n "$COMMAND" ]] || { usage; exit 1; }
}

check_prerequisites() {
    need_cmd openssl
    need_cmd grep
    resolve_keytool
    mkdir -p "$CERT_DIR"
    info "Cert directory: $CERT_DIR"
    info "Jenkins CN:     $JENKINS_CN"
    info "VM FQDN:        $VM_FQDN"
    info "Jenkins URL:    $JENKINS_URL"
}

# ---------------------------------------------------------------------------
# Step 1-2: CSR generation
# ---------------------------------------------------------------------------
cmd_generate_csr() {
    check_prerequisites

    if [[ -f "$CSR_CONF" && -f "$KEY_FILE" && -f "$CSR_FILE" ]]; then
        warn "CSR artifacts already exist; skipping generation."
        warn "  $CSR_CONF"
        warn "  $KEY_FILE"
        warn "  $CSR_FILE"
        return 0
    fi

    info "Creating CSR configuration: $CSR_CONF"
    if [[ "$DRY_RUN" == false ]]; then
        cat > "$CSR_CONF" <<EOF
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
CN = ${JENKINS_CN}

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${VM_HOST}
DNS.2 = ${VM_FQDN}
DNS.3 = ${JENKINS_CN}
EOF
        chmod 600 "$CSR_CONF"
    else
        info "[dry-run] Would write $CSR_CONF"
    fi

    run openssl req \
        -new -nodes -newkey rsa:4096 \
        -keyout "$KEY_FILE" \
        -out "$CSR_FILE" \
        -config "$CSR_CONF"

    run chmod 600 "$KEY_FILE" "$CSR_FILE"
    run openssl req -in "$CSR_FILE" -noout -text

    info "CSR generated successfully."
    info "NEXT: Submit ONLY this file to A1 PKI: $CSR_FILE"
    info "      Do NOT share: $KEY_FILE"
}

# ---------------------------------------------------------------------------
# Step 4-8: Keystore build
# ---------------------------------------------------------------------------
require_signed_certs() {
    local missing=()
    [[ -f "$KEY_FILE" ]]      || missing+=("$KEY_FILE")
    [[ -f "$LEAF_CERT" ]]     || missing+=("$LEAF_CERT")
    [[ -f "${CERT_DIR}/${CA_INTERMEDIATE}" ]] || missing+=("${CERT_DIR}/${CA_INTERMEDIATE}")
    [[ -f "${CERT_DIR}/${CA_ROOT}" ]]         || missing+=("${CERT_DIR}/${CA_ROOT}")

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required files:\n  $(printf '%s\n  ' "${missing[@]}")"
    fi
}

cmd_build_keystore() {
    check_prerequisites
    require_signed_certs

    info "Verifying signed leaf certificate"
    run openssl x509 -in "$LEAF_CERT" -noout -subject -issuer

    info "Building full certificate chain: $FULLCHAIN"
    if [[ "$DRY_RUN" == false ]]; then
        cat "$LEAF_CERT" \
            "${CERT_DIR}/${CA_INTERMEDIATE}" \
            "${CERT_DIR}/${CA_ROOT}" > "$FULLCHAIN"
        chmod 600 "$FULLCHAIN"
    fi

    local cert_count
    if [[ "$DRY_RUN" == false ]]; then
        cert_count=$(grep -c "BEGIN CERTIFICATE" "$FULLCHAIN" || true)
        [[ "$cert_count" -eq 3 ]] || die "Expected 3 certificates in chain, found: $cert_count"
        info "Chain contains 3 certificates"
    fi

    info "Verifying chain with openssl"
    run openssl verify \
        -CAfile "${CERT_DIR}/${CA_ROOT}" \
        -untrusted "${CERT_DIR}/${CA_INTERMEDIATE}" \
        "$LEAF_CERT"

    info "Creating PKCS12 keystore: $P12_FILE"
    if [[ "$DRY_RUN" == false ]]; then
        openssl pkcs12 -export \
            -in "$FULLCHAIN" \
            -inkey "$KEY_FILE" \
            -out "$P12_FILE" \
            -name "$ALIAS" \
            -passout "pass:${KEYSTORE_PASSWORD}"
    else
        info "[dry-run] Would create $P12_FILE"
    fi

    info "Converting PKCS12 to JKS: $JKS_FILE"
    if [[ "$DRY_RUN" == false ]]; then
        # Remove existing JKS to avoid interactive overwrite prompt
        [[ -f "$JKS_FILE" ]] && rm -f "$JKS_FILE"
        "$KEYTOOL" -importkeystore -noprompt \
            -srckeystore "$P12_FILE" \
            -srcstoretype PKCS12 \
            -srcstorepass "$KEYSTORE_PASSWORD" \
            -destkeystore "$JKS_FILE" \
            -deststoretype JKS \
            -deststorepass "$KEYSTORE_PASSWORD"
    else
        info "[dry-run] Would create $JKS_FILE"
    fi

    info "Validating keystore"
    if [[ "$DRY_RUN" == false ]]; then
        "$KEYTOOL" -list -v -keystore "$JKS_FILE" -storepass "$KEYSTORE_PASSWORD" 2>&1 \
            | grep -v "JKS keystore uses a proprietary format" \
            | grep -E "Alias name:|Owner:|Issuer:" || true

        local chain_len
        chain_len=$("$KEYTOOL" -list -v -keystore "$JKS_FILE" -storepass "$KEYSTORE_PASSWORD" 2>&1 \
            | grep -v "JKS keystore uses a proprietary format" \
            | grep "Certificate chain length" | head -1 | awk -F: '{print $2}' | tr -d ' ')
        [[ "$chain_len" == "3" ]] || die "Expected certificate chain length 3, got: ${chain_len:-unknown}"

        "$KEYTOOL" -list -v -keystore "$JKS_FILE" -storepass "$KEYSTORE_PASSWORD" 2>&1 \
            | grep -v "JKS keystore uses a proprietary format" \
            | grep "Owner:" > "$CHAIN_TXT" || true
        info "Chain export: $CHAIN_TXT"
        info "Note: JKS format warning from keytool is expected; Jenkins uses JKS on PROD/PET."
    fi

    info "Setting file permissions"
    run chmod 600 "$KEY_FILE" "$P12_FILE" "$JKS_FILE" "$FULLCHAIN" 2>/dev/null || \
        run chmod 600 "$KEY_FILE" "$P12_FILE" "$JKS_FILE"
    if is_root && id jenkins &>/dev/null; then
        run chown jenkins:jenkins "$KEY_FILE" "$P12_FILE" "$JKS_FILE" "$FULLCHAIN" 2>/dev/null || \
            run chown jenkins:jenkins "$KEY_FILE" "$P12_FILE" "$JKS_FILE" || true
    else
        info "Skipping chown (files owned by $(whoami); no root/sudo required for jenkins user)"
    fi

    info "Keystore build completed: $JKS_FILE"
}

# ---------------------------------------------------------------------------
# Step 9-10: Jenkins configuration
# ---------------------------------------------------------------------------
cmd_configure() {
    require_root
    check_prerequisites
    [[ -f "$JKS_FILE" ]] || die "Keystore not found: $JKS_FILE (run build-keystore first)"
    resolve_java_home

    local java_env_block=""
    if [[ ! -x /usr/bin/java ]]; then
        info "Adding JAVA_HOME and PATH (/usr/bin/java not found — same as PET but with explicit Java path)"
        java_env_block="Environment=JAVA_HOME=${JAVA_HOME}
Environment=\"PATH=${JAVA_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"
"
    fi

    info "Writing systemd override: $OVERRIDE_CONF"
    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$(dirname "$OVERRIDE_CONF")"
        tee "$OVERRIDE_CONF" > /dev/null <<EOF
[Service]
${java_env_block}Environment=JENKINS_HOME=${JENKINS_HOME}
# Disable HTTP and enable HTTPS
Environment=JENKINS_PORT=-1
Environment=JENKINS_HTTPS_PORT=${HTTPS_PORT}
Environment=JENKINS_HTTPS_KEYSTORE=${JKS_FILE}
Environment=JENKINS_HTTPS_KEYSTORE_PASSWORD=${KEYSTORE_PASSWORD}
Environment=CASC_JENKINS_CONFIG=${CASC_CONFIG}
Environment="JAVA_OPTS=-Djenkins.install.runSetupWizard=false"
Environment="JAVA_OPTS=\$JAVA_OPTS \\
-Dorg.jenkinsci.plugins.pipeline.utility.steps.conf.ReadYamlStep.MAX_CODE_POINT_LIMIT=9437184 \\
-Dorg.jenkinsci.plugins.pipeline.utility.steps.conf.ReadYamlStep.DEFAULT_MAX_ALIASES_FOR_COLLECTIONS=1000 \\
-Dorg.jenkinsci.plugins.pipeline.utility.steps.conf.ReadYamlStep.MAX_MAX_ALIASES_FOR_COLLECTIONS=1000 \\
-Djava.awt.headless=true \\
-Dhudson.model.DirectoryBrowserSupport.CSP=default-src\\ 'self';img-src\\ 'self'\\ data:;\\ style-src\\ 'self'\\ 'unsafe-inline';script-src\\ 'self';"
EOF
    else
        info "[dry-run] Would write $OVERRIDE_CONF"
    fi

    info "Updating CASC location config: $LOCATION_CONFIG"
    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$(dirname "$LOCATION_CONFIG")"
        tee "$LOCATION_CONFIG" > /dev/null <<EOF
unclassified:
    location:
       url: "${JENKINS_URL}"
       adminAddress: "${ADMIN_EMAIL}"
EOF
        if id jenkins &>/dev/null; then
            chown jenkins:jenkins "$LOCATION_CONFIG" 2>/dev/null || true
            chown -R jenkins:jenkins "$(dirname "$LOCATION_CONFIG")" 2>/dev/null || true
        fi
    else
        info "[dry-run] Would write $LOCATION_CONFIG"
    fi

    info "Configuration completed."
    info "  Keystore: $JKS_FILE"
    info "  URL:      $JENKINS_URL"
}

# ---------------------------------------------------------------------------
# Step 11: Firewall
# ---------------------------------------------------------------------------
cmd_firewall() {
    require_root
    if ! command -v firewall-cmd &>/dev/null; then
        warn "firewall-cmd not found; skipping firewall configuration."
        return 0
    fi

    case "$FIREWALL_MODE" in
        open-port)
            info "Opening port ${HTTPS_PORT}/tcp in firewalld"
            systemctl enable firewalld 2>/dev/null || true
            systemctl start firewalld 2>/dev/null || true
            firewall-cmd --permanent --add-port="${HTTPS_PORT}/tcp"
            firewall-cmd --reload
            if [[ "$DRY_RUN" == false ]]; then
                firewall-cmd --list-ports
            fi
            ;;
        disable)
            warn "Disabling firewalld (not recommended for production)"
            systemctl stop firewalld
            systemctl disable firewalld
            ;;
    esac
    info "Firewall step completed."
}

# ---------------------------------------------------------------------------
# Step 13: Restart Jenkins
# ---------------------------------------------------------------------------
cmd_restart() {
    require_root
    info "Reloading systemd and restarting Jenkins"
    systemctl daemon-reload
    systemctl restart jenkins
    sleep 3
    if [[ "$DRY_RUN" == false ]]; then
        systemctl status jenkins --no-pager || true
    fi
    info "Jenkins restart completed."
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
cmd_verify() {
    check_prerequisites
    local failed=0

    info "=== Verification for ${ENV} ==="

    if [[ -f "$JKS_FILE" ]]; then
        info "Keystore exists: $JKS_FILE"
        if [[ "$DRY_RUN" == false ]]; then
            "$KEYTOOL" -list -v -keystore "$JKS_FILE" -storepass "$KEYSTORE_PASSWORD" 2>/dev/null \
                | grep -E "Alias name:|Certificate chain length|Entry type" || true
        fi
    else
        warn "Keystore missing: $JKS_FILE"
        failed=$((failed + 1))
    fi

    if [[ -f "$OVERRIDE_CONF" ]]; then
        info "override.conf exists"
        if [[ "$DRY_RUN" == false ]]; then
            grep -E "HTTPS|KEYSTORE" "$OVERRIDE_CONF" 2>/dev/null || sudo grep -E "HTTPS|KEYSTORE" "$OVERRIDE_CONF" || true
        fi
    else
        warn "override.conf missing: $OVERRIDE_CONF"
        failed=$((failed + 1))
    fi

    if [[ -f "$LOCATION_CONFIG" ]]; then
        info "location-config.yaml:"
        if [[ "$DRY_RUN" == false ]]; then
            grep "url:" "$LOCATION_CONFIG" || true
        fi
    else
        warn "location-config.yaml missing: $LOCATION_CONFIG"
    fi

    if [[ "$DRY_RUN" == false ]] && systemctl is-active jenkins &>/dev/null; then
        info "Jenkins service: active"
        if ss -tlnp 2>/dev/null | grep -q ":${HTTPS_PORT} "; then
            info "Port ${HTTPS_PORT}: LISTENING"
        else
            warn "Port ${HTTPS_PORT}: NOT listening"
            failed=$((failed + 1))
        fi
        if command -v curl &>/dev/null; then
            if curl -sk --connect-timeout 5 "https://localhost:${HTTPS_PORT}" -o /dev/null; then
                info "HTTPS localhost:${HTTPS_PORT}: OK"
            else
                warn "HTTPS localhost:${HTTPS_PORT}: FAILED"
                failed=$((failed + 1))
            fi
        fi
    elif [[ "$DRY_RUN" == false ]]; then
        warn "Jenkins service is not active"
        failed=$((failed + 1))
    fi

    info "Access URLs:"
    info "  $JENKINS_URL"
    info "  https://${VM_FQDN}:${HTTPS_PORT}"
    info ""
    info "VDI test (run from Citrix VDI cmd):"
    info "  powershell -Command \"Test-NetConnection ${VM_FQDN} -Port ${HTTPS_PORT}\""

    if [[ $failed -gt 0 ]]; then
        die "$failed verification check(s) failed"
    fi
    info "All verification checks passed."
}

# ---------------------------------------------------------------------------
# Full flow
# ---------------------------------------------------------------------------
wait_for_pki() {
    echo ""
    info "================================================================"
    info "MANUAL STEP: Submit CSR to A1 PKI"
    info "  CSR file: $CSR_FILE"
    info ""
    info "After PKI signing, place these files in: $CERT_DIR"
    info "  - ${PREFIX}.cer"
    info "  - ${CA_INTERMEDIATE}"
    info "  - ${CA_ROOT}"
    info "================================================================"
    echo ""
    read -r -p "Press Enter when signed certificates are in place (or Ctrl+C to abort)... "
}

cmd_all() {
    info "Starting full Jenkins TLS enablement for environment: ${ENV}"

    if [[ "$SKIP_CSR" != true ]]; then
        cmd_generate_csr
        wait_for_pki
    else
        info "Skipping CSR generation (--skip-csr)"
    fi

    cmd_build_keystore

    if ! is_root; then
        echo ""
        info "================================================================"
        info "Keystore build complete (jenkins user steps done)."
        info "Run these commands as bastion/root user:"
        info "  cd ${CERT_DIR}"
        info "  sudo ./${SCRIPT_NAME} --env ${ENV} configure"
        info "  sudo ./${SCRIPT_NAME} --env ${ENV} firewall"
        info "  sudo ./${SCRIPT_NAME} --env ${ENV} restart"
        info "Then verify as jenkins user:"
        info "  ./${SCRIPT_NAME} --env ${ENV} verify"
        info "================================================================"
        return 0
    fi

    cmd_configure

    if [[ "$SKIP_FIREWALL" != true ]]; then
        cmd_firewall
    else
        info "Skipping firewall (--skip-firewall)"
    fi

    if [[ "$SKIP_RESTART" != true ]]; then
        cmd_restart
    else
        info "Skipping restart (--skip-restart)"
    fi

    cmd_verify
    info "Full TLS enablement completed for ${ENV}."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    case "$COMMAND" in
        generate-csr)   cmd_generate_csr ;;
        build-keystore) cmd_build_keystore ;;
        configure)      cmd_configure ;;
        firewall)       cmd_firewall ;;
        restart)        cmd_restart ;;
        verify)         cmd_verify ;;
        all)            cmd_all ;;
        *)              die "Unknown command: $COMMAND" ;;
    esac
}

main "$@"
