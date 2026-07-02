# Cloudera Manager UI HTTPS — Customer-Signed Certificate (Standalone Cluster)

Guide for enabling **CM Web UI HTTPS (port 7183)** and **agent TLS (port 7182)** on a **standalone** Cloudera cluster using a **customer PKI** certificate (e.g. A1 Silver).

| Applies to | Standalone / single CM node (may include remote worker hosts) |
|------------|---------------------------------------------------------------|
| CM version | 7.x (validated on **7.11.3** — UAT-05) |
| Format | JKS keystore + truststore |
| Build script | `scripts/build_standalone_cm_keystores.sh --uat <01-06>` |
| Out of scope | Kafka/ZK cluster keystores, Hue (see `CM_INT_HUE_HTTPS_RUNBOOK.md`) |

---

## Table of contents

1. [Architecture](#1-architecture)
2. [Prerequisites](#2-prerequisites)
3. [Certificate request (CSR)](#3-certificate-request-csr)
4. [Build keystores (Jenkins or CM host)](#4-build-keystores-jenkins-or-cm-host)
5. [Deploy to CM server](#5-deploy-to-cm-server)
6. [Configure Cloudera Manager](#6-configure-cloudera-manager)
7. [CM UI configuration reference (all paths)](#7-cm-ui-configuration-reference-all-paths)
8. [Configure agents](#8-configure-agents)
9. [Start Cloudera Management Service](#9-start-cloudera-management-service)
10. [Validation](#10-validation)
11. [Browser trust](#11-browser-trust)
12. [Standalone vs multi-node notes](#12-standalone-vs-multi-node-notes)
13. [Troubleshooting](#13-troubleshooting)
14. [Rollback](#14-rollback)

---

## 1. Architecture

```text
Browser ──HTTPS:7183──► CM Server (cm-ui.jks, customer cert)
Agent   ──TLS:7182────► CM Server (cm-ui.jks + cm-ui-trust.jks)
                         └── mutual auth: agent presents keystore-kafka client cert
```

| Port | Purpose |
|------|---------|
| 7180 | HTTP break-glass / local login |
| 7182 | Agent heartbeats (TLS, often mutual auth) |
| 7183 | CM Web UI HTTPS |

**One customer-signed certificate** (`cm-ui.jks`) serves CM UI and agent RPC server on 7182.

---

## 2. Prerequisites

### 2.1 From customer PKI

| Item | Description |
|------|-------------|
| Leaf certificate | `.cer` or `.pem` for CM hostname |
| Private key | `.key` from CSR generation |
| Issuing CA | Intermediate `.cer` |
| Root CA | Root `.cer` |

### 2.2 SANs on leaf certificate

Include every name users and agents will use:

```text
DNS: <cm-short-hostname>           e.g. uat-05-cloudera
DNS: <cm-fqdn>                     e.g. uat-05-cloudera.uat.corp.amdocs.azr
DNS: <cm-alias>                    e.g. cm-uat-05.uat.corp.amdocs.azr
```

**UAT naming pattern (`--uat 05`):**

| Index | SAN |
|-------|-----|
| DNS.01 | `uat-05-cloudera` |
| DNS.02 | `uat-05-cloudera.uat.corp.amdocs.azr` |
| DNS.03 | `cm-uat-05.uat.corp.amdocs.azr` |

**Standalone tip:** If Hue or other services run on the **same host**, add their SANs to the **initial CSR** to avoid a second PKI request later.

### 2.3 Access and backups

```bash
BACKUP=/var/tmp/cm-https-backup-$(date +%Y%m%d)
mkdir -p "$BACKUP"
cp -a /etc/cloudera-scm-server "$BACKUP/"
cp -a /etc/cloudera-scm-agent/config.ini "$BACKUP/"
```

### 2.4 Settings checklist

- [ ] Change window approved
- [ ] CM Full Administrator login
- [ ] Root SSH to CM host (+ agent hosts if separate)
- [ ] Auto-TLS remains **disabled**

---

## 3. Certificate request (CSR)

Example `cm_csr.conf`:

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
O  = YourOrg
OU = Infra Security
CN = cm.corp.example.com

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = standalone-cdhmng01
DNS.2 = standalone-cdhmng01.corp.example.com
DNS.3 = cm.corp.example.com
```

```bash
openssl genrsa -out cm-server.key 4096
openssl req -new -key cm-server.key -out cm-server.csr -config cm_csr.conf
openssl req -in cm-server.csr -noout -text | grep -A5 "Subject Alternative Name"
```

Submit CSR to customer PKI → receive signed leaf + CA chain.

---

## 4. Build keystores (Jenkins or CM host)

**Recommended:** use the parameterized build script:

```bash
cd /pciuser/tools/jenkins/.../UAT5   # or UAT01–UAT06 folder
./build_standalone_cm_keystores.sh --uat 05
# Output: output/cm-ui.jks, output/cm-ui-trust.jks, output/A1-*.pem, bundle tar.gz
```

Manual build (alternative):

```bash
WORKDIR=/opt/cm-certs
mkdir -p "$WORKDIR" && cd "$WORKDIR"

# PEM copies
cp cm-server.cer cm-server.pem
cp IssuingCA.cer issuing.pem
cp RootCA.cer root.pem

# Verify chain
openssl verify -CAfile root.pem -untrusted issuing.pem cm-server.pem
openssl x509 -in cm-server.pem -noout -subject -ext subjectAltName

# PKCS12 → JKS (server keystore)
openssl pkcs12 -export \
  -in cm-server.pem \
  -inkey cm-server.key \
  -certfile issuing.pem \
  -name cm-ui \
  -out cm-ui.p12 \
  -passout pass:changeit

keytool -importkeystore -noprompt \
  -srckeystore cm-ui.p12 -srcstoretype PKCS12 -srcstorepass changeit \
  -destkeystore cm-ui.jks -deststoretype JKS -deststorepass changeit \
  -destkeypass changeit \
  -srcalias cm-ui -destalias cm-ui

# Optional: import root into keystore chain
keytool -importcert -noprompt -alias a1-root-ca \
  -file root.pem -keystore cm-ui.jks -storepass changeit

# Truststore (CA certs + agent issuer for mutual TLS)
keytool -importcert -noprompt -alias a1-issuing-ca \
  -file issuing.pem -keystore cm-ui-trust.jks -storepass changeit
keytool -importcert -noprompt -alias a1-root-ca \
  -file root.pem -keystore cm-ui-trust.jks -storepass changeit

# Import Amdocs Internal CA (for validating agent client certs)
# Export from existing RA truststore on cluster:
keytool -exportcert -rfc \
  -alias '<alias-in-ra-admin-truststore>' \
  -keystore /etc/certificate/ra-admin-truststore.jks \
  -storepass '<password>' \
  -file amdocs-internal-ca.pem

keytool -importcert -noprompt -alias amdocs-internal-ca \
  -file amdocs-internal-ca.pem \
  -keystore cm-ui-trust.jks -storepass changeit

# Verify
keytool -list -keystore cm-ui.jks -storepass changeit
keytool -list -keystore cm-ui-trust.jks -storepass changeit
```

---

## 5. Deploy to CM server

On the **CM host**:

```bash
sudo mkdir -p /etc/cloudera-scm-server/ssl
sudo cp cm-ui.jks cm-ui-trust.jks /etc/cloudera-scm-server/ssl/

# CRITICAL — cloudera-scm user must read directory + files (UAT-05 lesson)
sudo chown root:cloudera-scm /etc/cloudera-scm-server/ssl
sudo chmod 750 /etc/cloudera-scm-server/ssl
sudo chown cloudera-scm:cloudera-scm /etc/cloudera-scm-server/ssl/*.jks
sudo chmod 600 /etc/cloudera-scm-server/ssl/cm-ui.jks
sudo chmod 600 /etc/cloudera-scm-server/ssl/cm-ui-trust.jks

sudo -u cloudera-scm test -r /etc/cloudera-scm-server/ssl/cm-ui.jks && echo "jks OK"
sudo -u cloudera-scm test -r /etc/cloudera-scm-server/ssl/cm-ui-trust.jks && echo "trust OK"

# Agent CAcerts (same host or all agent hosts)
sudo mkdir -p /opt/cloudera/security/CAcerts
sudo cp A1-RootCA.pem A1-IssuingCA.pem /opt/cloudera/security/CAcerts/
sudo chmod 644 /opt/cloudera/security/CAcerts/*.pem
sudo openssl rehash /opt/cloudera/security/CAcerts

# amdocs-internal-ca into truststore (required for agent mutual TLS on 7182)
keytool -exportcert -rfc \
  -alias '<alias-from-ra-admin-truststore>' \
  -keystore /etc/certificate/ra-admin-truststore.jks \
  -storepass '<ra-truststore-password>' \
  -file /tmp/amdocs-internal-ca.pem

keytool -importcert -noprompt -alias amdocs-internal-ca \
  -file /tmp/amdocs-internal-ca.pem \
  -keystore /etc/cloudera-scm-server/ssl/cm-ui-trust.jks \
  -storepass changeit
```

---

## 6. Configure Cloudera Manager

### 6.1 `cloudera-scm-server.properties`

File: `/etc/cloudera-scm-server/cloudera-scm-server.properties`  
(Create if missing — some standalone installs do not ship this file until first edit.)

```properties
com.cloudera.cmf.web.server.ssl.enabled=true
com.cloudera.cmf.security.auto_tls=false

com.cloudera.cmf.web.server.ssl.keystore=/etc/cloudera-scm-server/ssl/cm-ui.jks
com.cloudera.cmf.web.server.ssl.keystore.password=changeit
com.cloudera.cmf.web.server.ssl.keystore.type=jks
com.cloudera.cmf.web.server.ssl.keystore.alias=cm-ui

com.cloudera.cmf.web.server.ssl.truststore=/etc/cloudera-scm-server/ssl/cm-ui-trust.jks
com.cloudera.cmf.web.server.ssl.truststore.password=changeit
com.cloudera.cmf.web.server.ssl.truststore.type=jks
```

```bash
sudo chown cloudera-scm:cloudera-scm /etc/cloudera-scm-server/cloudera-scm-server.properties
sudo chmod 640 /etc/cloudera-scm-server/cloudera-scm-server.properties
```

### 6.2 CM UI TLS settings (required — overrides properties)

**Navigation:** **Administration → Settings** → filter **`TLS`**

| CM UI label | Internal property | Value |
|-------------|-------------------|--------|
| Cloudera Manager TLS/SSL **Server Keystore** File Location | `keystore_path` | `/etc/cloudera-scm-server/ssl/cm-ui.jks` |
| Cloudera Manager TLS/SSL **Server Keystore** File Password | `keystore_password` | `changeit` |
| Cloudera Manager TLS/SSL **Trust Store** File | `truststore_path` | `/etc/cloudera-scm-server/ssl/cm-ui-trust.jks` |
| Cloudera Manager TLS/SSL **Trust Store** Password | `truststore_password` | `changeit` |
| Use TLS Authentication of Agents to Server | — | Keep **enabled** (if already on) |
| Auto-TLS | — | **Disabled** |

**Save** → shows **Requires Server Restart** → restart `cloudera-scm-server`.

> If UI TLS still points to `/etc/certificate/keystore-kafka.jks`, port **7183** serves **`CN=username`** (wrong cert).

### 6.3 Cloudera Management Service TLS (after CM restart)

**Navigation:** **Cloudera Management Service → Configuration** → filter **`TLS`**

| CM UI label | Internal property | Value | Notes |
|-------------|-------------------|--------|-------|
| TLS/SSL **Client Truststore** File Location | `ssl.client.truststore.location` | `/etc/cloudera-scm-server/ssl/cm-ui-trust.jks` | **Not** `cm-ui.jks` |
| Cloudera Manager Server TLS/SSL **Trust Store** Password | `ssl.client.truststore.password` | `changeit` | |
| **Enable TLS/SSL for Firehose** Debug Server | `debug.servlet.https.enabled` | ✓ Checked | Host Monitor default group |
| Firehose Debug Server TLS/SSL **Server Keystore** File Location | `debug.servlet.https.keystorePath` / `ssl_server_keystore_location` | `/etc/certificate/keystore-kafka.jks` | **Do NOT** change to `cm-ui.jks` |
| Firehose Debug Server TLS/SSL **Server Keystore** File Password | `debug.servlet.https.keystorePassword` / `ssl_server_keystore_password` | `Root00` (or cluster pass) | |

**Do not change for CM HTTPS:**

| Setting | Keep as-is |
|---------|------------|
| Navigator TLS/SSL Trust Store File | `/etc/certificate/ra-admin-truststore.jks` (legacy; optional) |
| Hue `ssl_cacerts` | Use A1 `root.pem` — **not** `ra-admin-truststore.pem` |

**Save** → **Cloudera Management Service → Actions → Start** (or Restart).

### 6.4 Restart CM server

```bash
sudo systemctl restart cloudera-scm-server
sleep 60
grep -E "7182|7183|SslContextFactory|Started ServerConnector" \
  /var/log/cloudera-scm-server/cloudera-scm-server.log | tail -15
```

Expected:

```text
x509 (cm-ui, h=[your SANs...])
keyStore=.../cm-ui.jks
trustStore=.../cm-ui-trust.jks    # for 7182
Started ServerConnector ... {0.0.0.0:7183}
```

---

## 7. CM UI configuration reference (all paths)

Quick map of **every CM UI location** vs filesystem path (standalone / UAT-05 validated):

| Layer | CM navigation | Path / value |
|-------|---------------|--------------|
| **CM server keystore** | Administration → Settings → TLS → Server Keystore | `/etc/cloudera-scm-server/ssl/cm-ui.jks` |
| **CM server truststore** | Administration → Settings → TLS → Trust Store | `/etc/cloudera-scm-server/ssl/cm-ui-trust.jks` |
| **CM properties file** | (file on disk) | `/etc/cloudera-scm-server/cloudera-scm-server.properties` |
| **Mgmt service client trust** | Cloudera Management Service → Config → TLS → Client Truststore | `/etc/cloudera-scm-server/ssl/cm-ui-trust.jks` |
| **Firehose server cert** | Cloudera Management Service → Config → TLS → Firehose keystore | `/etc/certificate/keystore-kafka.jks` |
| **Agent trusts CM (A1)** | (file) `config.ini` → `verify_cert_dir` | `/opt/cloudera/security/CAcerts/` |
| **Agent client cert** | (file) `config.ini` → `client_*` | `/etc/certificate/keystore-kafka.{key,pem}` |
| **Cluster services (Kafka/ZK)** | (unchanged) | `/etc/certificate/keystore-kafka.jks` |

**UAT-05 example URLs:**

```text
https://cm-uat-05.uat.corp.amdocs.azr:7183
https://uat-05-cloudera.uat.corp.amdocs.azr:7183
http://uat-05-cloudera.uat.corp.amdocs.azr:7180/cmf/localLogin
```

**What uses `cm-ui.jks` vs what does not:**

| Uses `cm-ui.jks` | Does NOT use `cm-ui.jks` |
|------------------|---------------------------|
| CM UI (7183) | Firehose Debug Server |
| Agent RPC server (7182) | Kafka / ZooKeeper / cluster TLS |
| YARN Queue Manager (if configured) | Agent **client** identity (`keystore-kafka`) |

---

## 8. Configure agents

### 8.1 Deploy customer CA certs (agents trust CM server cert)

On **every host** running `cloudera-scm-agent` (including CM host if agent runs there):

```bash
sudo mkdir -p /opt/cloudera/security/CAcerts
sudo cp RootCA.pem IssuingCA.pem /opt/cloudera/security/CAcerts/
sudo chmod 644 /opt/cloudera/security/CAcerts/*.pem
sudo openssl rehash /opt/cloudera/security/CAcerts
```

### 8.2 `/etc/cloudera-scm-agent/config.ini`

**File:** `/etc/cloudera-scm-agent/config.ini`

```ini
server_host=<cm-fqdn>
server_port=7182
use_tls=1

verify_cert_dir=/opt/cloudera/security/CAcerts
#verify_cert_file=/etc/certificate/ra-admin-truststore.pem

# Required if mutual agent authentication is enabled:
client_key_file=/etc/certificate/keystore-kafka.key
client_cert_file=/etc/certificate/keystore-kafka.pem
client_keypw_file=/etc/certificate/agentkey.pw
```

> **Do not** comment out `client_*` lines when mutual TLS is enabled.

### 8.3 Restart agent(s)

```bash
sudo systemctl restart cloudera-scm-agent
grep -E "7182|bad certificate|Successfully heartbeating" \
  /var/log/cloudera-scm-agent/cloudera-scm-agent.log | tail -10
```

---

## 9. Start Cloudera Management Service

1. Confirm **Hosts → `<cm-host>`** health is **Good** (agent heartbeat on 7182).
2. Confirm Management Service TLS config saved (Section 6.3).
3. **Cloudera Management Service → Actions → Start** (or Restart).
4. Wait **10–15 minutes** for monitoring charts to populate (NO DATA is normal immediately after start).
5. **Do not** restart `cloudera-scm-server` again unless TLS paths change.

---

## 10. Validation

### 10.1 Certificate on 7183

```bash
echo | openssl s_client -connect <cm-fqdn>:7183 \
  -servername cm.corp.example.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -ext subjectAltName
```

### 10.2 UI access

```text
https://<cm-fqdn>:7183
```

Break-glass:

```text
http://<cm-fqdn>:7180/cmf/localLogin
```

### 10.3 Standalone single-host checklist

| Check | Expected |
|-------|----------|
| CM UI HTTPS | Customer cert, correct SAN |
| Host health | Good |
| Management Service | All roles Started |
| Agent log | No `bad certificate` |

---

## 11. Browser trust

Import customer **Root CA** into workstation trust store:

| Browser | Trust store |
|---------|-------------|
| Chrome / Edge | Windows **Trusted Root Certification Authorities** |
| Firefox | Firefox certificate store or OS store |

CM UI cert alone is not enough — browsers must trust the customer root.

---

## 12. Standalone vs multi-node notes

| Topic | Standalone (1 CM node) | Multi-node cluster |
|-------|------------------------|---------------------|
| `cm-ui.jks` location | CM host only | CM host only |
| Agent `config.ini` | CM host + any workers | All hosts |
| A1 CAcerts | All agent hosts | All agent hosts |
| CSR SANs | CM hostname + alias | CM hostname; add Hue hosts if needed |
| DNS / firewall | VDI → CM `:7183` | VDI → CM + service hosts |

**Standalone with co-located roles:** CM, agent, and services on one box still need:

- `cm-ui.jks` for CM
- Agent `verify_cert_dir` + `client_*` for 7182
- Cluster services keep `keystore-kafka.jks` unchanged

---

## 13. Troubleshooting

| Symptom | Fix |
|---------|-----|
| UI shows wrong cert (`CN=username`) | Fix **Administration → Settings → TLS** → `cm-ui.jks`; restart CM |
| `Permission denied` on `cm-ui-trust.jks` | `chown root:cloudera-scm` + `chmod 750` on `/etc/cloudera-scm-server/ssl/` |
| `sslv3 alert bad certificate` | Uncomment agent `client_*`; deploy CAcerts; add `amdocs-internal-ca` to truststore |
| Management Service won't start | Fix agent heartbeat first; Firehose = `keystore-kafka.jks` |
| Charts show **NO DATA** | Wait 10–15 min after Management Service start; verify Host Monitor **Started** |
| Browser **Nicht sicher** but openssl shows A1 cert | Import **A1 Root CA** on VDI (SSL works; browser trust only) |
| Firehose errors | Firehose keystore = `keystore-kafka.jks`, not `cm-ui.jks` |
| `openssl` empty cert | Check DNS/connectivity; use `2>&1` |

---

## 14. Rollback

```bash
cp -a /var/tmp/cm-https-backup-YYYYMMDD/cloudera-scm-server/* /etc/cloudera-scm-server/
# Revert Administration → Settings → TLS to previous keystore paths
sudo systemctl restart cloudera-scm-server
cp /var/tmp/cm-https-backup-YYYYMMDD/config.ini /etc/cloudera-scm-agent/
sudo systemctl restart cloudera-scm-agent
```

---

## Quick reference paths

| Item | Path |
|------|------|
| CM keystore | `/etc/cloudera-scm-server/ssl/cm-ui.jks` |
| CM truststore | `/etc/cloudera-scm-server/ssl/cm-ui-trust.jks` |
| Password (example) | `changeit` |
| Alias | `cm-ui` |
| Agent CAcerts | `/opt/cloudera/security/CAcerts/` |
| Agent client cert | `/etc/certificate/keystore-kafka.{key,pem}` |
| CM log | `/var/log/cloudera-scm-server/cloudera-scm-server.log` |

---

## Related runbooks

- `scripts/build_standalone_cm_keystores.sh` — JKS build for UAT01–UAT06
- `CM_PROD_HTTPS_SAML_RUNBOOK.md` — PROD HA implementation + SAML
- `CM_INT_HUE_HTTPS_RUNBOOK.md` — Hue PEM (separate from CM UI)
- `CM_PROD_HUE_HTTPS_RUNBOOK.md` — Hue on dedicated hosts

---

## Document history

| Date | Change |
|------|--------|
| 2026-07-02 | Added full CM UI config paths, internal property names, UAT-05 validation, ssl dir permissions |

---

*Document: Standalone CM UI HTTPS with customer-signed certificate — implementation guide.*
