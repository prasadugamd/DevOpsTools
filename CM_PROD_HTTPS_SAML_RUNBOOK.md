# Cloudera Manager PROD — HTTPS (A1 PKI) & Ping SAML Runbook

| Field | Value |
|-------|-------|
| **Environment** | Production (`prod.corp.amdocs.azr`) |
| **CM Version** | 7.11.3 |
| **Runtime** | Cloudera Runtime 7.1.9 |
| **CM Server Host** | `prod-01-cdhmng01.prod.corp.amdocs.azr` |
| **CM UI URL (validated)** | `https://prod-01-cdhmng01.prod.corp.amdocs.azr:7183` |
| **Reference (INT)** | `https://int-01-cdhmng01.int.corp.amdocs.azr:7183` |
| **Certificate authority** | A1 Silver PKI (customer) |
| **Status (Jun 2026)** | PROD HTTPS + agents deployed; SAML pending |
| **Jenkins cert path** | `/pciuser/tools/jenkins/jenkins-production/prod-corp-amdocs-azr/PROD-CM/CM-A1-SIGNED` |

---

## Table of contents

1. [Scope and architecture](#1-scope-and-architecture)
2. [Port reference](#2-port-reference)
3. [What changes vs what stays unchanged](#3-what-changes-vs-what-stays-unchanged)
4. [Prerequisites](#4-prerequisites)
5. [Runbook — PROD HTTPS implementation](#5-runbook--prod-https-implementation)
6. [Agent rollout (all cluster hosts)](#6-agent-rollout-all-cluster-hosts)
7. [Validation checklist](#7-validation-checklist)
8. [Troubleshooting](#8-troubleshooting)
9. [Rollback](#9-rollback)
10. [SAML / Ping — prerequisites](#10-saml--ping--prerequisites)
11. [SAML / Ping — implementation](#11-saml--ping--implementation)
12. [ESAPI prerequisites (required for SAML on CM 7.11)](#12-esapi-prerequisites-required-for-saml-on-cm-711)
13. [Post-SAML authorization](#13-post-saml-authorization)
14. [Appendix — file paths and passwords](#14-appendix--file-paths-and-passwords)

---

## 1. Scope and architecture

### 1.1 HTTPS scope (completed in PROD)

- Replace Cloudera Manager **UI HTTPS** certificate (port **7183**) with **A1-signed** certificate.
- Keep **agent mutual TLS** (port **7182**) working with existing **Amdocs Internal CA** agent client certificates.
- Do **not** change Kafka, ZooKeeper, or cluster service keystores (`/etc/certificate/keystore-kafka.jks`).

### 1.2 SAML scope (planned)

- Cloudera Manager = **SAML Service Provider (SP)**
- PingFederate / PingOne = **SAML Identity Provider (IdP)**
- Browser SSO (SAML 2.0): SP-initiated and IdP-initiated login; SP-initiated logout (SLO)
- **Same** A1 HTTPS certificate used for UI and SAML (no separate Ping-only cert)

### 1.3 High-level TLS flow

```
Browser ──HTTPS:7183──► CM Server (cm-ui.jks, A1 cert)
Agent   ──TLS:7182────► CM Server (cm-ui.jks + cm-ui-trust.jks)
                         └── validates agent client cert (keystore-kafka / Amdocs Internal CA)
```

### 1.4 PROD cluster hosts (9)

| Role | Hostnames |
|------|-----------|
| CM / Management | `prod-01-cdhmng01`, `prod-01-cdhmng02`, `prod-01-cdhmng03` |
| Data | `prod-01-cdhdat01` … `prod-01-cdhdat06` |

---

## 2. Port reference

| Port | Purpose | Certificate / trust |
|------|---------|---------------------|
| **7180** | HTTP break-glass / local login | None |
| **7182** | Agent ↔ CM RPC (heartbeats, mutual TLS) | Server: `cm-ui.jks`; Trust: `cm-ui-trust.jks` |
| **7183** | CM Web UI HTTPS | Server: `cm-ui.jks` |

---

## 3. What changes vs what stays unchanged

### 3.1 Changed (PROD)

| Component | Change |
|-----------|--------|
| `/etc/cloudera-scm-server/ssl/cm-ui.jks` | A1 leaf + chain for CM UI and 7182 server cert |
| `/etc/cloudera-scm-server/ssl/cm-ui-trust.jks` | A1 Root + Issuing CA + **amdocs-internal-ca** (for agent client cert validation) |
| `/etc/cloudera-scm-server/cloudera-scm-server.properties` | UI SSL keystore settings |
| **Administration → Settings → TLS** | Server keystore/truststore → `cm-ui.jks` / `cm-ui-trust.jks` (was `keystore-kafka.jks`) |
| **Cloudera Management Service** | Client truststore → `cm-ui-trust.jks` |
| `/etc/cloudera-scm-agent/config.ini` (all hosts) | `verify_cert_dir` + **uncommented** `client_*` lines |
| `/opt/cloudera/security/CAcerts/` (all hosts) | A1 Root + Issuing CA PEMs + `openssl rehash` |

### 3.2 Unchanged (do not modify for this effort)

| Component | Path / note |
|-----------|-------------|
| Kafka / ZK cluster keystore | `/etc/certificate/keystore-kafka.jks` (password `Root00`) |
| Agent **client** identity | `keystore-kafka.key` / `.pem` / `agentkey.pw` |
| Firehose Debug Server keystore | **`/etc/certificate/keystore-kafka.jks`** (default group) — **not** `cm-ui.jks` |
| RA admin truststore | `/etc/certificate/ra-admin-truststore.jks` (cluster TLS only) |
| Auto-TLS | Remains **disabled** (`com.cloudera.cmf.security.auto_tls=false`) |

---

## 4. Prerequisites

### 4.1 Certificates from customer (A1 PKI)

Request or obtain:

| File | Purpose |
|------|---------|
| `cm-prod.cer` (or PEM) | Leaf certificate |
| `cm-prod.key` | Private key |
| `A1-Telekom-Austria-AG-IssuingCA01-Silver.cer` | Intermediate CA |
| `A1-Telekom-Austria-AG-RootCA-Silver.cer` | Root CA |

**Required SANs on leaf certificate:**

```
DNS: prod-01-cdhmng01
DNS: prod-01-cdhmng01.prod.corp.amdocs.azr
DNS: cm.prod.corp.amdocs.azr
```

**CSR reference (`cm_csr.conf`):**

```ini
[ dn ]
CN = cm.prod.corp.amdocs.azr
O  = Amdocs
OU = Infra Security

[ alt_names ]
DNS.1 = prod-01-cdhmng01
DNS.2 = prod-01-cdhmng01.prod.corp.amdocs.azr
DNS.3 = cm.prod.corp.amdocs.azr
```

### 4.2 Access and approvals

- [ ] Change window / CAB approval
- [ ] CM **Full Administrator** account
- [ ] Root SSH to all 9 hosts
- [ ] Jenkins job access for JKS build (optional)
- [ ] DNS ticket for `cm.prod.corp.amdocs.azr` (recommended; alias may be missing on server today)

### 4.3 Backups before change

On **prod-01-cdhmng01**:

```bash
BACKUP=/var/tmp/cm-https-backup-$(date +%Y%m%d)
mkdir -p "$BACKUP"
cp -a /etc/cloudera-scm-server "$BACKUP/"
cp -a /etc/cloudera-scm-agent/config.ini "$BACKUP/config.ini"
cp -a /etc/default/cloudera-scm-server "$BACKUP/" 2>/dev/null
```

---

## 5. Runbook — PROD HTTPS implementation

### Phase A — Build keystores (Jenkins or CM host)

#### A1. Verify certificate chain

```bash
openssl x509 -inform DER -in cm-prod.cer -noout -subject -issuer -dates
openssl verify -CAfile A1-RootCA.pem -untrusted A1-IssuingCA.pem cm-prod.pem
```

#### A2. Build PKCS12 and JKS

```bash
# Convert certs to PEM if DER
openssl pkcs12 -export \
  -inkey cm-prod.key \
  -in cm-prod.pem \
  -certfile A1-IssuingCA.pem \
  -out cm-ui.p12 \
  -name cm-ui \
  -passout pass:changeit

keytool -importkeystore -noprompt \
  -srckeystore cm-ui.p12 -srcstoretype PKCS12 -srcstorepass changeit \
  -destkeystore cm-ui.jks -deststoretype JKS -deststorepass changeit \
  -srcalias cm-ui -destalias cm-ui

# Truststore: A1 CAs + Amdocs Internal CA (for agent mutual TLS)
keytool -importcert -noprompt -alias a1-issuing-ca \
  -file A1-IssuingCA.pem -keystore cm-ui-trust.jks -storepass changeit
keytool -importcert -noprompt -alias a1-root-ca \
  -file A1-RootCA.pem -keystore cm-ui-trust.jks -storepass changeit

# Export Amdocs Internal CA from existing RA truststore (PROD alias may differ)
keytool -exportcert -rfc \
  -alias '<alias-from-ra-admin-truststore>' \
  -keystore /etc/certificate/ra-admin-truststore.jks \
  -storepass '<ra-truststore-password>' \
  -file /tmp/amdocs-internal-ca.pem

keytool -importcert -noprompt -alias amdocs-internal-ca \
  -file /tmp/amdocs-internal-ca.pem \
  -keystore cm-ui-trust.jks -storepass changeit
```

#### A3. Verify JKS

```bash
keytool -list -keystore cm-ui.jks -storepass changeit
keytool -list -keystore cm-ui-trust.jks -storepass changeit | grep -E "cm-ui|a1-|amdocs"
```

Expected: alias `cm-ui`, PrivateKeyEntry; truststore contains `a1-issuing-ca`, `a1-root-ca`, `amdocs-internal-ca`.

---

### Phase B — Deploy to CM server (`prod-01-cdhmng01`)

#### B1. Install JKS files

```bash
sudo mkdir -p /etc/cloudera-scm-server/ssl
sudo cp cm-ui.jks cm-ui-trust.jks /etc/cloudera-scm-server/ssl/
sudo chown cloudera-scm:cloudera-scm /etc/cloudera-scm-server/ssl/*.jks
sudo chmod 600 /etc/cloudera-scm-server/ssl/*.jks
```

#### B2. Update `cloudera-scm-server.properties`

File: `/etc/cloudera-scm-server/cloudera-scm-server.properties`

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

#### B3. Update CM UI TLS settings (critical — overrides properties)

**Administration → Settings → TLS** (filter: TLS)

| Setting | Value |
|---------|-------|
| Server Keystore | `/etc/cloudera-scm-server/ssl/cm-ui.jks` |
| Server Keystore Password | `changeit` |
| Trust Store | `/etc/cloudera-scm-server/ssl/cm-ui-trust.jks` |
| Trust Store Password | `changeit` |
| Use TLS Authentication of Agents to Server | **Keep enabled** (do not disable) |
| Auto-TLS | **Disabled** |

> **Lesson learned:** If UI TLS settings still point to `/etc/certificate/keystore-kafka.jks`, port **7183** will serve the wrong certificate (`CN=username`) even when `cloudera-scm-server.properties` is correct.

#### B4. Cloudera Management Service TLS

**Cloudera Management Service → Configuration → TLS**

| Setting | Value |
|---------|-------|
| TLS/SSL Client Truststore File Location | `/etc/cloudera-scm-server/ssl/cm-ui-trust.jks` |
| Cloudera Manager Server TLS/SSL Trust Store Password | `changeit` |
| Firehose Debug Server keystore (default group) | `/etc/certificate/keystore-kafka.jks` |
| Firehose keystore password | `Root00` |

> **Do not** set Firehose keystore to `cm-ui.jks` on any host.

#### B5. Restart CM server

```bash
sudo systemctl restart cloudera-scm-server
sleep 60
grep -E "7182|7183|SslContextFactory|Started ServerConnector" \
  /var/log/cloudera-scm-server/cloudera-scm-server.log | tail -15
```

**Expected log lines:**

```
x509 (cm-ui, h=[prod-01-cdhmng01, prod-01-cdhmng01.prod.corp.amdocs.azr, cm.prod.corp.amdocs.azr])
keyStore=file:///etc/cloudera-scm-server/ssl/cm-ui.jks
trustStore=file:///etc/cloudera-scm-server/ssl/cm-ui-trust.jks   # for 7182
Started ServerConnector ... {0.0.0.0:7183}
```

---

### Phase C — CM host agent (`prod-01-cdhmng01`)

#### C1. Deploy A1 CA certs for agent trust

```bash
sudo mkdir -p /opt/cloudera/security/CAcerts
sudo cp A1-RootCA.pem A1-IssuingCA.pem /opt/cloudera/security/CAcerts/
sudo chmod 644 /opt/cloudera/security/CAcerts/*.pem
sudo openssl rehash /opt/cloudera/security/CAcerts
```

#### C2. Update `/etc/cloudera-scm-agent/config.ini`

**Required configuration** (both changes are mandatory):

```ini
verify_cert_dir=/opt/cloudera/security/CAcerts
#verify_cert_file=/etc/certificate/ra-admin-truststore.pem

client_key_file=/etc/certificate/keystore-kafka.key
client_cert_file=/etc/certificate/keystore-kafka.pem
client_keypw_file=/etc/certificate/agentkey.pw
```

> **Lesson learned:** Switching only to `verify_cert_dir` **without** uncommenting `client_*` causes `sslv3 alert bad certificate` when mutual agent authentication is enabled.

#### C3. Restart agent

```bash
sudo systemctl restart cloudera-scm-agent
grep -E "7182|bad certificate|Successfully heartbeating" \
  /var/log/cloudera-scm-agent/cloudera-scm-agent.log | tail -10
```

#### C4. Start Cloudera Management Service

**Cloudera Management Service → Actions → Start**

Wait until all five roles are **Started** and host health is **Good**.

---

## 6. Agent rollout (all cluster hosts)

Repeat on **each** of the 9 hosts:

```bash
# 1. A1 CAs
sudo mkdir -p /opt/cloudera/security/CAcerts
sudo cp A1-RootCA.pem A1-IssuingCA.pem /opt/cloudera/security/CAcerts/
sudo chmod 644 /opt/cloudera/security/CAcerts/*.pem
sudo openssl rehash /opt/cloudera/security/CAcerts

# 2. Confirm client cert files exist
ls -l /etc/certificate/keystore-kafka.key \
      /etc/certificate/keystore-kafka.pem \
      /etc/certificate/agentkey.pw

# 3. config.ini — same as prod-01-cdhmng01
# 4. Restart agent
sudo systemctl restart cloudera-scm-agent
```

**Bulk verification from CM host:**

```bash
for h in prod-01-cdhmng0{1,2,3} prod-01-cdhdat0{1,2,3,4,5,6}; do
  echo "=== $h ==="
  ssh root@${h}.prod.corp.amdocs.azr \
    "grep -E '^verify_cert|^client_' /etc/cloudera-scm-agent/config.ini | head -6; \
     ls /opt/cloudera/security/CAcerts/*.pem 2>/dev/null | wc -l"
done
```

---

## 7. Validation checklist

### 7.1 CM server TLS

```bash
echo | openssl s_client -connect prod-01-cdhmng01.prod.corp.amdocs.azr:7183 \
  -servername cm.prod.corp.amdocs.azr 2>/dev/null \
  | openssl x509 -noout -subject -issuer -ext subjectAltName
```

Expected issuer: `A1-Telekom-Austria-AG-IssuingCA01-Silver`; CN: `cm.prod.corp.amdocs.azr`.

### 7.2 UI access

| Check | Expected |
|-------|----------|
| URL | `https://prod-01-cdhmng01.prod.corp.amdocs.azr:7183` |
| Firefox | Padlock / secure connection |
| Chrome | May need A1 Root in **Windows** trust store (Firefox uses its own store) |
| Login | Local admin works (until SAML enabled) |

### 7.3 Hosts and Management Service

| Check | Expected |
|-------|----------|
| Hosts page | 9 hosts, heartbeat metrics visible |
| Host health | Good |
| Cloudera Management Service | All 5 roles Started |
| Cluster services | Green / operational |

### 7.4 Agent logs (per host)

```bash
grep -E "bad certificate|Successfully heartbeating" \
  /var/log/cloudera-scm-agent/cloudera-scm-agent.log | tail -5
```

No `bad certificate` errors after restart.

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| UI shows `CN=username` / Amdocs cert | CM UI **Settings → TLS** still uses `keystore-kafka.jks` | Point to `cm-ui.jks` / `cm-ui-trust.jks` |
| `sslv3 alert bad certificate` on 7182 | `client_*` commented in `config.ini` | Uncomment `client_key_file`, `client_cert_file`, `client_keypw_file` |
| Same error after `verify_cert_dir` only | Agent does not trust A1 server cert | Deploy A1 PEMs to `CAcerts` + `openssl rehash` |
| Management Service won't start | Host health bad (no heartbeat) | Fix agent first |
| `Connection refused` to firehose | Management Service not running | Start service after host green |
| Firehose / Host Monitor TLS errors | Firehose set to `cm-ui.jks` | Revert to `keystore-kafka.jks` |
| `cm.prod.corp.amdocs.azr` DNS fails | No DNS A record | Use node FQDN or create DNS alias |
| Chrome "Not secure", Firefox OK | Different trust stores | Import A1 Root into Windows **Trusted Root CAs** |
| `unable to load certificate` in openssl pipe | Connection failed; stderr hidden | Use `echo \| openssl s_client ... 2>&1 \| head -50` |

---

## 9. Rollback

### 9.1 CM server

```bash
# Restore from backup
cp -a /var/tmp/cm-https-backup-YYYYMMDD/cloudera-scm-server/* /etc/cloudera-scm-server/

# Revert CM UI: Administration → Settings → TLS
#   Server Keystore → /etc/certificate/keystore-kafka.jks (previous)
#   Trust Store     → /etc/certificate/ra-admin-truststore.jks (previous)

sudo systemctl restart cloudera-scm-server
```

### 9.2 Agent

```bash
cp /etc/cloudera-scm-agent/config.ini.B4CA20260601 /etc/cloudera-scm-agent/config.ini
sudo systemctl restart cloudera-scm-agent
```

---

## 10. SAML / Ping — prerequisites

Complete **only after** PROD HTTPS is stable (this runbook Phase B–C validated).

### 10.1 Platform

| Requirement | Detail |
|-------------|--------|
| Cloudera edition | **Enterprise** (not Express) |
| CM access | Full Administrator |
| CM UI | **HTTPS on 7183** with customer-trusted cert (A1) |
| CM URL stability | Use canonical URL in Ping and CM metadata (recommend `https://prod-01-cdhmng01.prod.corp.amdocs.azr:7183` until `cm.prod` DNS exists) |
| Break-glass | `http://prod-01-cdhmng01.prod.corp.amdocs.azr:7180/cmf/localLogin` |

### 10.2 Ping / IdP

| Requirement | Detail |
|-------------|--------|
| Product | PingFederate or PingOne |
| Protocol | SAML 2.0 |
| Auth adapter | AD / LDAP / MFA (per customer IdP design) |
| Metadata | IdP metadata XML export (Entity ID, SSO URL, SLO URL, signing cert) |
| Application | New SAML SP connection for Cloudera Manager PROD |

### 10.3 Certificates for SAML

| Requirement | Detail |
|-------------|--------|
| Signing keystore | **Same** `cm-ui.jks` (alias `cm-ui`, password `changeit`) |
| Separate Ping cert | **Not required** — one cert for HTTPS + SAML |
| Self-signed | **Not acceptable** for PROD Ping SAML |
| SAN / URL match | Assertion Consumer Service (ACS) URL must match HTTPS URL host |

### 10.4 What SAML does **not** require

- No change to Kafka / ZooKeeper TLS
- No change to agent `keystore-kafka` client certs
- No change to Firehose keystore
- No second CM certificate for Ping only

### 10.5 Coordination checklist (before SAML cutover)

- [ ] Ping team: PROD SAML application created
- [ ] DNS / load balancer URLs agreed with IdP team
- [ ] Attribute mapping defined (`uid`, `mail`, `cn` or equivalent)
- [ ] CM local admin break-glass account tested on port **7180**
- [ ] ESAPI prerequisites applied (Section 12)
- [ ] User → CM role mapping plan documented (Section 13)
- [ ] Change window for `systemctl restart cloudera-scm-server`

---

## 11. SAML / Ping — implementation

### Phase 1 — Export CM Service Provider (SP) metadata

1. Log in to CM as local admin: `https://prod-01-cdhmng01.prod.corp.amdocs.azr:7183`
2. **Administration → Settings → External Authentication**
3. Set **Authentication Type** to **SAML** (or use export if available before full cutover)
4. Export / note SP metadata:
   - SP Entity ID
   - ACS (Assertion Consumer Service) URL — typically `https://<cm-host>:7183/cmf/saml/...`
   - Single Logout URL (if used)

Deliver SP metadata XML to Ping team.

### Phase 2 — Configure Ping (IdP)

On PingFederate / PingOne:

1. Create SAML application for **Cloudera Manager PROD**
2. Import CM **SP metadata**
3. Protocol: **SAML 2.0**, Browser SSO profile
4. Attribute contract (minimum):
   - `uid` or `username` (maps to CM user)
   - `mail` (optional)
   - `cn` or `givenName` + `sn` (optional)
5. Signing: include IdP signing certificate in assertion
6. Export **IdP metadata XML** for CM

### Phase 3 — Apply ESAPI prerequisites (Section 12)

Complete **before** enabling SAML and restarting CM server.

### Phase 4 — Configure SAML in Cloudera Manager

1. **Administration → Settings**
2. Filter: **External Authentication**
3. Configure:

| Setting | Value |
|---------|-------|
| Authentication Type | **SAML** |
| IdP metadata | Upload Ping IdP metadata XML |
| Keystore path | `/etc/cloudera-scm-server/ssl/cm-ui.jks` |
| Keystore password | `changeit` |
| Key alias | `cm-ui` |

4. **Save**
5. Restart CM server:

```bash
sudo systemctl restart cloudera-scm-server
tail -f /var/log/cloudera-scm-server/cloudera-scm-server.log
```

### Phase 5 — Validation

| Test | Steps | Expected |
|------|-------|----------|
| SP-initiated login | Open `https://prod-01-cdhmng01...:7183` | Redirect to Ping → return to CM UI |
| IdP-initiated | Launch CM from Ping portal | Lands in CM UI authenticated |
| Logout (SLO) | Logout from CM | Logout propagated to Ping (if configured) |
| Break-glass | `http://prod-01-cdhmng01...:7180/cmf/localLogin` | Local admin login works |
| Agent / cluster | Hosts page | No impact on heartbeats |

### Phase 6 — Troubleshooting SAML

| Error | Action |
|-------|--------|
| `Error invoking Velocity template` / ESAPI `ConfigurationException` | Apply Section 12 (ESAPI jar symlink, `ESAPI.properties`, JVM `--add-opens`) |
| Redirect loop | Check ACS URL vs actual CM URL (host/port/https) |
| User authenticated but no CM access | Map user to CM role (Section 13) |
| SAML fails completely | Use break-glass **7180** local login; revert Authentication Type to LOCAL temporarily |

---

## 12. ESAPI prerequisites (required for SAML on CM 7.11)

Observed on INT; apply on **prod-01-cdhmng01** before SAML enablement.

### 12.1 ESAPI JAR symlink

```bash
sudo mkdir -p /usr/share/cmf/lib/
sudo ln -sf /opt/cloudera/cm/lib/esapi-2.4.0.0.jar /usr/share/cmf/lib/esapi-2.4.0.0.jar
sudo chown -h cloudera-scm:cloudera-scm /usr/share/cmf/lib/esapi-2.4.0.0.jar
```

Verify:

```bash
find / -name "esapi*.jar" 2>/dev/null
ls -l /usr/share/cmf/lib/esapi-2.4.0.0.jar
```

### 12.2 ESAPI properties

File: `/etc/cloudera-scm-server/esapi/ESAPI.properties`

```properties
# ESAPI.Logger=PLACEHOLDER_LOGGER
ESAPI.Logger=org.owasp.esapi.reference.Log4JLogFactory
```

Ensure directory owned by `cloudera-scm`:

```bash
sudo chown -R cloudera-scm:cloudera-scm /etc/cloudera-scm-server/esapi
```

### 12.3 validation.xml (if missing)

```bash
# Create minimal validation.xml if SAML encoder fails
sudo vi /etc/cloudera-scm-server/esapi/validation.xml
sudo chown cloudera-scm:cloudera-scm /etc/cloudera-scm-server/esapi/validation.xml
sudo chmod 644 /etc/cloudera-scm-server/esapi/validation.xml
```

### 12.4 JVM options in `/etc/default/cloudera-scm-server`

Add to `CMF_JAVA_OPTS` (preserve existing flags):

```bash
--add-opens=java.base/java.lang=ALL-UNNAMED \
--add-opens=java.base/java.util=ALL-UNNAMED \
--add-opens=java.base/java.net=ALL-UNNAMED \
--add-opens=java.base/sun.security.x509=ALL-UNNAMED \
--add-opens=java.xml/com.sun.org.apache.xerces.internal.dom=ALL-UNNAMED
```

Ensure these are present:

```bash
-Dorg.owasp.esapi.resources=/etc/cloudera-scm-server/esapi
-Djava.util.logging.config.file=/etc/cloudera-scm-server/esapi/logging.properties
```

Restart after changes:

```bash
sudo systemctl restart cloudera-scm-server
grep -i esapi /var/log/cloudera-scm-server/cloudera-scm-server.log | tail -20
```

---

## 13. Post-SAML authorization

Authentication ≠ authorization in CM.

After successful Ping login:

1. **Administration → Users** — create or verify user (match SAML `uid` / NameID)
2. Assign role:
   - Full Administrator
   - Operator
   - BDR Manager
   - Read-only
3. Or map LDAP/AD groups if integrated

Users without a CM role will authenticate via Ping but cannot operate the cluster.

---

## 14. Appendix — file paths and passwords

| Item | Path / value |
|------|----------------|
| CM UI keystore | `/etc/cloudera-scm-server/ssl/cm-ui.jks` |
| CM UI truststore | `/etc/cloudera-scm-server/ssl/cm-ui-trust.jks` |
| Keystore / truststore password | `changeit` |
| Keystore alias | `cm-ui` |
| CM properties | `/etc/cloudera-scm-server/cloudera-scm-server.properties` |
| Agent config | `/etc/cloudera-scm-agent/config.ini` |
| Agent A1 CAs | `/opt/cloudera/security/CAcerts/` |
| Agent client key/cert | `/etc/certificate/keystore-kafka.key`, `.pem`, `agentkey.pw` |
| Cluster keystore (unchanged) | `/etc/certificate/keystore-kafka.jks` (`Root00`) |
| RA admin truststore | `/etc/certificate/ra-admin-truststore.jks` |
| CM server log | `/var/log/cloudera-scm-server/cloudera-scm-server.log` |
| Agent log | `/var/log/cloudera-scm-agent/cloudera-scm-agent.log` |
| ESAPI config | `/etc/cloudera-scm-server/esapi/` |
| JVM defaults | `/etc/default/cloudera-scm-server` |
| Jenkins PROD certs | `/pciuser/tools/jenkins/jenkins-production/prod-corp-amdocs-azr/PROD-CM/CM-A1-SIGNED` |
| INT reference URL | `https://int-01-cdhmng01.int.corp.amdocs.azr:7183` |
| PROD CM URL | `https://prod-01-cdhmng01.prod.corp.amdocs.azr:7183` |
| Break-glass login | `http://prod-01-cdhmng01.prod.corp.amdocs.azr:7180/cmf/localLogin` |

---

## Document history

| Date | Author | Change |
|------|--------|--------|
| 2026-06-02 | Operations | Initial PROD HTTPS runbook + SAML prerequisites (post-implementation) |

---

*Reference: INT implementation notes in `CM_HTTPS_PING.txt`, `CM_HTTPS_Zookeeper.txt`.*
