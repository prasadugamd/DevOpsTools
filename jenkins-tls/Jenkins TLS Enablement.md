# Jenkins TLS Enablement

**Author:** Prasadu Gamini  
**Document purpose:** Step-by-step procedure to enable HTTPS (TLS) on Amdocs Jenkins servers using A1 Telekom Austria corporate PKI certificates.

**Applies to:** INT, PROD, PET, and UAT Jenkins environments  
**HTTPS port:** 8443  
**Last updated:** June 2026  
**Validated on:** PET (`vm-jenkins-pet-we-001`)

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Environment Reference](#2-environment-reference)
3. [Step 1 — Create CSR Configuration](#step-1--create-csr-configuration)
4. [Step 2 — Generate Private Key and CSR](#step-2--generate-private-key-and-csr)
5. [Step 3 — Submit CSR to A1 PKI](#step-3--submit-csr-to-a1-pki)
6. [Step 4 — Obtain Signed Certificate and CA Certificates](#step-4--obtain-signed-certificate-and-ca-certificates)
7. [Step 5 — Build Full Certificate Chain](#step-5--build-full-certificate-chain)
8. [Step 6 — Create PKCS12 and JKS Keystore](#step-6--create-pkcs12-and-jks-keystore)
9. [Step 7 — Validate Keystore](#step-7--validate-keystore)
10. [Step 8 — Secure File Permissions](#step-8--secure-file-permissions)
11. [Step 9 — Configure Jenkins HTTPS (systemd)](#step-9--configure-jenkins-https-systemd)
12. [Step 10 — Update Jenkins Location URL (CASC)](#step-10--update-jenkins-location-url-casc)
13. [Step 11 — Configure Firewall](#step-11--configure-firewall)
14. [Step 12 — Network Access (Citrix VDI)](#step-12--network-access-citrix-vdi)
15. [Step 13 — Restart Jenkins and Verify](#step-13--restart-jenkins-and-verify)
16. [Troubleshooting](#troubleshooting)
17. [Appendix — Environment-Specific Values](#appendix--environment-specific-values)

---

## 1. Prerequisites

| Item | Requirement |
|------|-------------|
| Server access | SSH as `jenkins` user for certs/keystore; **bastion/root** for systemd, firewall, restart |
| Tools | `openssl`, `keytool` (from Java JDK **devel** package) |
| Java JDK | `java-17-openjdk-devel` (RHEL 8) — JRE alone does not include `keytool` |
| PKI | A1 Telekom Austria corporate PKI team access to sign CSR |
| CA certificates | A1 Root CA and Intermediate CA (Silver tier) |
| Jenkins install | Linux package install with systemd service |
| CASC | Configuration-as-Code enabled (`CASC_JENKINS_CONFIG` set) |

**Install keytool (once per server, as root/bastion):**

```bash
sudo yum install -y java-17-openjdk-devel
which keytool    # expected: /usr/bin/keytool
```

**Who runs what:**

| Step | User | Commands |
|------|------|----------|
| CSR + keystore | `jenkins` | `generate-csr`, `build-keystore` |
| systemd + firewall + restart | **bastion/root** | `configure`, `firewall`, `restart` |
| Verify | `jenkins` or bastion | `verify` |

**Certificate chain hierarchy:**

```
jenkins.<env>.corp.amdocs.azr          (Leaf / Server certificate)
   └── A1-Telekom-Austria-AG-IssuingCA01-Silver   (Intermediate CA)
        └── A1-Telekom-Austria-AG-RootCA-Silver   (Root CA)
```

---

## 2. Environment Reference

Replace `<env>` with `int`, `prod`, `pet`, or `uat` as applicable.

| Environment | VM Hostname | Jenkins URL (CN) | Cert Directory |
|-------------|-------------|------------------|----------------|
| INT | `vm-jenkins-int-we-001` | `jenkins.int.corp.amdocs.azr` | `/pciuser/tools/jenkins/jenkins-production/int-corp-amdocs-azr/INT-JENKINS` |
| PROD | `vm-jenkins-prod-we-001` | `jenkins.prod.corp.amdocs.azr` | `/pciuser/tools/jenkins/jenkins-production/prod-corp-amdocs-azr/PROD-JENKINS` |
| PET | `vm-jenkins-pet-we-001` | `jenkins.pet.corp.amdocs.azr` | `/pciuser/tools/jenkins/jenkins-production/pet-corp-amdocs-azr/PET-JENKINS` |
| UAT | `vm-jenkins-uat-we-001` | `jenkins.uat.corp.amdocs.azr` | `/pciuser/tools/jenkins/jenkins-production/uat-corp-amdocs-azr/UAT-JENKINS` |

**Naming convention for files:**

| File | Example (PET) |
|------|---------------|
| CSR config | `jenkins-pet-csr.conf` |
| Private key | `jenkins-pet.key` |
| CSR | `jenkins-pet.csr` |
| Signed cert | `jenkins-pet.cer` |
| Full chain | `jenkins-pet-fullchain.cer` |
| PKCS12 | `jenkins-pet.p12` |
| JKS keystore | `jenkins-pet.jks` |
| Keystore alias | `jenkins-pet` |

---

## Step 1 — Create CSR Configuration

Create a CSR configuration file in the Jenkins cert directory.

**File:** `jenkins-<env>-csr.conf`

**Example (PET):**

```ini
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
CN = jenkins.pet.corp.amdocs.azr

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = vm-jenkins-pet-we-001
DNS.2 = vm-jenkins-pet-we-001.pet.corp.amdocs.azr
DNS.3 = jenkins.pet.corp.amdocs.azr
```

**Notes:**
- `CN` must match the primary Jenkins URL hostname.
- Include VM hostname and service DNS name in `subjectAltName`.

---

## Step 2 — Generate Private Key and CSR

Run from the cert directory as the `jenkins` user.

```bash
cd /pciuser/tools/jenkins/jenkins-production/<env>-corp-amdocs-azr/<ENV>-JENKINS

openssl req \
  -new \
  -nodes \
  -newkey rsa:4096 \
  -keyout jenkins-<env>.key \
  -out jenkins-<env>.csr \
  -config jenkins-<env>-csr.conf
```

**Validate CSR content:**

```bash
openssl req -in jenkins-<env>.csr -noout -text
```

Confirm:
- Subject CN matches intended Jenkins URL
- SAN entries include VM and service hostnames
- Key size is 4096 bits

---

## Step 3 — Submit CSR to A1 PKI

Send **only** the CSR file to the A1 / corporate PKI team:

```
jenkins-<env>.csr
```

Do **not** share the private key (`jenkins-<env>.key`).

---

## Step 4 — Obtain Signed Certificate and CA Certificates

After PKI signing, place the following files in the cert directory:

| File | Description |
|------|-------------|
| `jenkins-<env>.cer` | Signed server (leaf) certificate |
| `A1-Telekom-Austria-AG-IssuingCA01-Silver.cer` | Intermediate CA |
| `A1-Telekom-Austria-AG-RootCA-Silver.cer` | Root CA |

**Verify signed certificate:**

```bash
openssl x509 -in jenkins-<env>.cer -noout -text
```

Confirm:
- Subject matches CSR CN
- Issuer is `A1-Telekom-Austria-AG-IssuingCA01-Silver`

**Optional — convert CA certs to PEM (if needed):**

```bash
openssl x509 -inform DER -in A1-Telekom-Austria-AG-IssuingCA01-Silver.cer -out A1-IssuingCA01-Silver.crt
openssl x509 -inform DER -in A1-Telekom-Austria-AG-RootCA-Silver.cer -out A1-RootCA-Silver.crt
```

---

## Step 5 — Build Full Certificate Chain

Concatenate certificates in this **exact order**:

```
Leaf → Intermediate → Root
```

```bash
cat jenkins-<env>.cer \
    A1-Telekom-Austria-AG-IssuingCA01-Silver.cer \
    A1-Telekom-Austria-AG-RootCA-Silver.cer \
> jenkins-<env>-fullchain.cer
```

**Verify chain (optional):**

```bash
openssl verify \
  -CAfile A1-Telekom-Austria-AG-RootCA-Silver.cer \
  -untrusted A1-Telekom-Austria-AG-IssuingCA01-Silver.cer \
  jenkins-<env>.cer
```

Expected output: `jenkins-<env>.cer: OK`

**Confirm 3 certificates in chain file:**

```bash
grep -c "BEGIN CERTIFICATE" jenkins-<env>-fullchain.cer
```

Expected output: `3`

---

## Step 6 — Create PKCS12 and JKS Keystore

Jenkins (Java) requires a keystore containing the private key and full certificate chain.

**6.1 Create PKCS12 keystore:**

```bash
openssl pkcs12 -export \
  -in jenkins-<env>-fullchain.cer \
  -inkey jenkins-<env>.key \
  -out jenkins-<env>.p12 \
  -name jenkins-<env>
```

Set and remember the export password (commonly `changeit`).

**6.2 Convert PKCS12 to JKS:**

```bash
keytool -importkeystore \
  -srckeystore jenkins-<env>.p12 \
  -srcstoretype PKCS12 \
  -destkeystore jenkins-<env>.jks \
  -deststoretype JKS
```

---

## Step 7 — Validate Keystore

**Full keystore listing:**

```bash
keytool -list -v -keystore jenkins-<env>.jks
```

**Required results:**

| Check | Expected |
|-------|----------|
| Entry type | `PrivateKeyEntry` |
| Certificate chain length | `3` |
| Alias | `jenkins-<env>` |

**Chain order check:**

```bash
keytool -list -v -keystore jenkins-<env>.jks | grep -E "Alias name:|Owner:|Issuer:"
```

Expected chain:

1. **Leaf:** Owner = `CN=jenkins.<env>.corp.amdocs.azr` → Issuer = `IssuingCA01-Silver`
2. **Intermediate:** Owner = `IssuingCA01-Silver` → Issuer = `RootCA-Silver`
3. **Root:** Owner = `RootCA-Silver` → Issuer = `RootCA-Silver` (self-signed)

**Export chain for records:**

```bash
keytool -list -v -keystore jenkins-<env>.jks | grep "Owner:" > jenkins-cert-chain.txt
```

---

## Step 8 — Secure File Permissions

```bash
chmod 600 jenkins-<env>.key jenkins-<env>.p12 jenkins-<env>.jks
chown jenkins:jenkins jenkins-<env>.key jenkins-<env>.p12 jenkins-<env>.jks
```

**Verify Jenkins user can read keystore:**

```bash
sudo -u jenkins test -r /path/to/jenkins-<env>.jks && echo "keystore readable"
```

---

## Step 9 — Configure Jenkins HTTPS (systemd)

Create or edit the systemd override file as **root**:

**File:** `/etc/systemd/system/jenkins.service.d/override.conf`

**Template (update keystore path per environment):**

```ini
[Service]
Environment=JENKINS_HOME=/pciuser/tools/jenkins/jenkins-production
# Disable HTTP and enable HTTPS
Environment=JENKINS_PORT=-1
Environment=JENKINS_HTTPS_PORT=8443
Environment=JENKINS_HTTPS_KEYSTORE=/pciuser/tools/jenkins/jenkins-production/<env>-corp-amdocs-azr/<ENV>-JENKINS/jenkins-<env>.jks
Environment=JENKINS_HTTPS_KEYSTORE_PASSWORD=changeit
Environment=CASC_JENKINS_CONFIG=/pciuser/tools/jenkins/jenkins-production/casc_configs
Environment="JAVA_OPTS=-Djenkins.install.runSetupWizard=false"
Environment="JAVA_OPTS=$JAVA_OPTS \
-Dorg.jenkinsci.plugins.pipeline.utility.steps.conf.ReadYamlStep.MAX_CODE_POINT_LIMIT=9437184 \
-Dorg.jenkinsci.plugins.pipeline.utility.steps.conf.ReadYamlStep.DEFAULT_MAX_ALIASES_FOR_COLLECTIONS=1000 \
-Dorg.jenkinsci.plugins.pipeline.utility.steps.conf.ReadYamlStep.MAX_MAX_ALIASES_FOR_COLLECTIONS=1000 \
-Djava.awt.headless=true \
-Dhudson.model.DirectoryBrowserSupport.CSP=default-src\ 'self';img-src\ 'self'\ data:;\ style-src\ 'self'\ 'unsafe-inline';script-src\ 'self';"
```

**PET keystore path example:**

```
/pciuser/tools/jenkins/jenkins-production/pet-corp-amdocs-azr/PET-JENKINS/jenkins-pet.jks
```

**Verify environment is loaded:**

```bash
sudo systemctl show jenkins -p Environment | grep -E "HTTPS|KEYSTORE|PORT"
```

---

## Step 10 — Update Jenkins Location URL (CASC)

Edit the CASC location configuration so Jenkins generates correct links and SAML callbacks.

**File:** `/pciuser/tools/jenkins/jenkins-production/casc_configs/jenkins-basic-configuration/location-config.yaml`

**Correct format (must include `https://`):**

```yaml
unclassified:
    location:
       url: "https://jenkins.<env>.corp.amdocs.azr:8443"
       adminAddress: "example@amdocs.com"
```

**PET example:**

```yaml
unclassified:
    location:
       url: "https://jenkins.pet.corp.amdocs.azr:8443"
       adminAddress: "example@amdocs.com"
```

Use the certificate CN as the primary URL to avoid hostname/certificate mismatches.

---

## Step 11 — Configure Firewall

Jenkins listens on port **8443**. Ensure the host firewall allows inbound TCP 8443.

**Recommended — open port 8443 only (keep firewalld enabled):**

```bash
sudo firewall-cmd --permanent --add-port=8443/tcp
sudo firewall-cmd --reload
sudo systemctl enable firewalld
sudo systemctl start firewalld
sudo firewall-cmd --list-ports
```

**Alternative (used on PET during initial enablement — not recommended long-term):**

```bash
sudo systemctl stop firewalld
sudo systemctl disable firewalld
```

> **Note:** Disabling firewalld entirely removes host-level protection. Prefer opening port 8443 only.

---

## Step 12 — Network Access (Citrix VDI)

Request firewall rules from the network team to allow Citrix VDI subnet access to Jenkins HTTPS.

| Source | Destination | Port | Protocol |
|--------|-------------|------|----------|
| Citrix VDI subnet | `vm-jenkins-<env>-we-001.<env>.corp.amdocs.azr` | 8443 | TCP |
| Citrix VDI subnet | `jenkins.<env>.corp.amdocs.azr` | 8443 | TCP |

**PET example:**

| Source | Destination | Port | Protocol |
|--------|-------------|------|----------|
| Citrix VDI subnet | `vm-jenkins-pet-we-001.pet.corp.amdocs.azr` | 8443 | TCP |
| Citrix VDI subnet | `jenkins.pet.corp.amdocs.azr` | 8443 | TCP |

---

## Step 13 — Restart Jenkins and Verify

**13.1 Apply systemd changes and restart:**

```bash
sudo systemctl daemon-reload
sudo systemctl restart jenkins
sudo systemctl status jenkins
```

**13.2 Confirm Jenkins is listening on 8443 (on the VM):**

```bash
ss -tlnp | grep 8443
curl -vk https://localhost:8443
```

**13.3 Test from Citrix VDI (Command Prompt):**

```cmd
powershell -Command "Test-NetConnection vm-jenkins-<env>-we-001.<env>.corp.amdocs.azr -Port 8443"
```

Expected: `TcpTestSucceeded : True`

**13.4 Browser access:**

```
https://jenkins.<env>.corp.amdocs.azr:8443
```

**13.5 Validation checklist:**

| Check | Pass criteria |
|-------|---------------|
| Jenkins service | `active (running)` |
| Port 8443 | Listening (`ss -tlnp`) |
| Keystore chain | 3 certificates, correct order |
| VDI connectivity | `TcpTestSucceeded : True` |
| Browser | Jenkins login/dashboard loads |
| Certificate | Shows A1 chain; CN matches URL |

---

## Troubleshooting

### `keytool not found`

Jenkins runtime (`java-17-openjdk`) does not include `keytool`. Install the **devel** package:

```bash
sudo yum install -y java-17-openjdk-devel
which keytool
./jenkins-tls-enablement.sh --env uat build-keystore
```

### TCP connection timeout from VDI (`TcpTestSucceeded : False`)

| Cause | Action |
|-------|--------|
| Host firewall blocking 8443 | Open port 8443 in `firewalld` (Step 11) |
| Network rule missing | Request Citrix VDI → Jenkins rule (Step 12) |
| Jenkins not running | Check `systemctl status jenkins` and `journalctl -u jenkins -n 50` |

### Jenkins fails to start after HTTPS config

```bash
sudo journalctl -u jenkins -n 80 --no-pager
```

| Cause | Action |
|-------|--------|
| Wrong keystore path | Verify path in `override.conf` |
| Wrong password | Match `JENKINS_HTTPS_KEYSTORE_PASSWORD` to JKS password |
| Keystore not readable | Fix ownership/permissions (Step 8) |
| Invalid/incomplete chain | Rebuild full chain (Step 5); chain length must be 3 |

### Browser shows "Not Secure"

| Cause | Action |
|-------|--------|
| Missing `https://` in URL | Use full URL: `https://jenkins.<env>.corp.amdocs.azr:8443` |
| A1 Root CA not trusted on VDI | Request IT to deploy A1 Root CA to VDI trust store |
| Hostname mismatch | Access URL must match certificate CN or SAN |

### `Test-NetConnection` not found in Command Prompt

`Test-NetConnection` is a PowerShell cmdlet. Run from cmd:

```cmd
powershell -Command "Test-NetConnection vm-jenkins-pet-we-001.pet.corp.amdocs.azr -Port 8443"
```

---

## Appendix — Environment-Specific Values

### PET (validated June 2026)

| Item | Value |
|------|-------|
| Server | `vm-jenkins-pet-we-001` |
| Cert directory | `/pciuser/tools/jenkins/jenkins-production/pet-corp-amdocs-azr/PET-JENKINS` |
| Keystore | `jenkins-pet.jks` |
| Alias | `jenkins-pet` |
| CN | `jenkins.pet.corp.amdocs.azr` |
| HTTPS URL | `https://jenkins.pet.corp.amdocs.azr:8443` |
| Keystore password | `changeit` |

### PROD

| Item | Value |
|------|-------|
| Server | `vm-jenkins-prod-we-001` |
| Cert directory | `/pciuser/tools/jenkins/jenkins-production/prod-corp-amdocs-azr/PROD-JENKINS` |
| Keystore | `jenkins-prod.jks` |
| Alias | `jenkins-prod` |
| HTTPS URL | `https://vm-jenkins-prod-we-001.prod.corp.amdocs.azr:8443` |

### INT

| Item | Value |
|------|-------|
| Server | `vm-jenkins-int-we-001` |
| Cert directory | `/pciuser/tools/jenkins/jenkins-production/int-corp-amdocs-azr/INT-JENKINS` |
| Keystore | `jenkins-int.jks` |
| Alias | `jenkins-int` |
| CN | `jenkins.int.corp.amdocs.azr` |
| HTTPS URL | `https://vm-jenkins-int-we-001.int.corp.amdocs.azr:8443` |

### UAT

| Item | Value |
|------|-------|
| Server | `vm-jenkins-uat-we-001` |
| Cert directory | `/pciuser/tools/jenkins/jenkins-production/uat-corp-amdocs-azr/UAT-JENKINS` |
| Keystore | `jenkins-uat.jks` |
| Alias | `jenkins-uat` |
| CN | `jenkins.uat.corp.amdocs.azr` |
| HTTPS URL | `https://jenkins.uat.corp.amdocs.azr:8443` |

---

## Artifacts Produced

| Artifact | Purpose |
|----------|---------|
| `jenkins-<env>-csr.conf` | CSR configuration |
| `jenkins-<env>.key` | Private key (keep secure) |
| `jenkins-<env>.csr` | Certificate signing request |
| `jenkins-<env>.cer` | Signed leaf certificate |
| `jenkins-<env>-fullchain.cer` | Full TLS certificate chain |
| `jenkins-<env>.p12` | PKCS12 keystore |
| `jenkins-<env>.jks` | Java keystore for Jenkins |
| `jenkins-cert-chain.txt` | Chain validation export |
| `override.conf` | Systemd HTTPS configuration |

---

## End-to-End Flow Summary

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────┐
│  CSR + Key Gen  │────▶│  A1 PKI Sign │────▶│  Full Chain     │
└─────────────────┘     └──────────────┘     └────────┬────────┘
                                                      │
┌─────────────────┐     ┌──────────────┐     ┌────────▼────────┐
│  Browser / VDI  │◀────│  Firewall    │◀────│  PKCS12 → JKS   │
│  Verification   │     │  Port 8443   │     └────────┬────────┘
└─────────────────┘     └──────────────┘              │
                                                      ▼
                                            ┌─────────────────┐
                                            │ override.conf   │
                                            │ HTTPS :8443     │
                                            │ + CASC URL      │
                                            └─────────────────┘
```

---

## Automation Script

An end-to-end bash script automates all steps except PKI signing (manual).

**Script:** `jenkins-tls-enablement.sh`

**Prerequisite on server:**

```bash
sudo yum install -y java-17-openjdk-devel openssl
which keytool openssl
```

**Copy to Jenkins server and make executable:**

```bash
chmod +x jenkins-tls-enablement.sh
```

### Commands

| Command | Description |
|---------|-------------|
| `generate-csr` | Create CSR config + private key + CSR |
| `build-keystore` | Full chain, PKCS12, JKS, validate, permissions |
| `configure` | Write `override.conf` and `location-config.yaml` |
| `firewall` | Open port 8443 in firewalld |
| `restart` | Reload systemd and restart Jenkins |
| `verify` | Run local validation checks |
| `all` | Full flow (pauses for PKI signing) |

### Examples

**Full end-to-end (with PKI pause):**

```bash
./jenkins-tls-enablement.sh --env pet all
```

**After PKI returns signed certs (skip CSR regeneration):**

```bash
# As jenkins user
./jenkins-tls-enablement.sh --env uat --skip-csr build-keystore

# As bastion user (sudo)
sudo ./jenkins-tls-enablement.sh --env uat configure
sudo ./jenkins-tls-enablement.sh --env uat firewall
sudo ./jenkins-tls-enablement.sh --env uat restart

# Verify
./jenkins-tls-enablement.sh --env uat verify
```

**Individual phases:**

```bash
./jenkins-tls-enablement.sh --env pet generate-csr
# ... submit CSR to A1 PKI, place signed certs ...
./jenkins-tls-enablement.sh --env pet build-keystore
./jenkins-tls-enablement.sh --env pet configure
./jenkins-tls-enablement.sh --env pet firewall
./jenkins-tls-enablement.sh --env pet restart
./jenkins-tls-enablement.sh --env pet verify
```

**Options:**

```bash
--env pet|prod|int|uat         # Required environment
--cert-dir /custom/path      # Override cert directory
--vm-fqdn hostname.fqdn      # Override VM FQDN for CSR SAN DNS.2 (or JENKINS_VM_FQDN)
--keystore-password changeit # Or set JENKINS_KEYSTORE_PASSWORD
--admin-email user@amdocs.com
--skip-csr                   # Skip CSR in 'all' mode
--skip-firewall              # Skip firewall step
--skip-restart               # Skip Jenkins restart
--disable-firewalld          # Disable firewalld (not recommended)
--dry-run                    # Print actions without executing
```

**Environment variables:**

```bash
export JENKINS_KEYSTORE_PASSWORD=changeit
export JENKINS_ADMIN_EMAIL=example@amdocs.com
export JENKINS_VM_FQDN=vm-jenkins-pet-we-001.custom.corp.amdocs.azr
```

---

*Document: Jenkins TLS Enablement | Author: Prasadu Gamini | Amdocs Jenkins on A1 Telekom Austria PKI*
