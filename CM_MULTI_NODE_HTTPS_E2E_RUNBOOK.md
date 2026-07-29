# Cloudera Manager Multi-Node HTTPS — End-to-End Runbook (INT / PROD / PET)

Consolidated procedure for **multi-node** Cloudera clusters using **A1 Silver PKI**, covering:

1. **CM UI HTTPS** (7183) + agent mutual TLS (7182)
2. **YARN Queue Manager** HTTPS (uses CM keystore)
3. **Hue UI / Load Balancer** HTTPS (8889)
4. **Hue → Hive** outbound trust (`ssl_cacerts`)

| Field | Value |
|-------|-------|
| **Applies to** | INT, PROD, PET (multi-node: cdhmng01 + Hue on 02/03 + data nodes) |
| **CM / Runtime** | 7.11.x / 7.1.9 (validated pattern) |
| **CA** | A1 Silver + **Amdocs Internal CA** (cluster/agent/Hive) |
| **Out of scope** | Kafka/ZK `keystore-kafka.jks` identity; Auto-TLS; Ping SAML (see `CM_PROD_HTTPS_SAML_RUNBOOK.md`) |
| **Standalone UAT** | Use `CM_STANDALONE_HTTPS_RUNBOOK.md` instead |

---

## Table of contents

1. [Environment matrix](#1-environment-matrix)
2. [Architecture and trust model](#2-architecture-and-trust-model)
3. [Certificate strategy and SANs](#3-certificate-strategy-and-sans)
4. [Prerequisites and backups](#4-prerequisites-and-backups)
5. [Phase 1 — Build CM keystores](#5-phase-1--build-cm-keystores)
6. [Phase 2 — Deploy CM UI HTTPS + agents](#6-phase-2--deploy-cm-ui-https--agents)
7. [Phase 3 — YARN Queue Manager](#7-phase-3--yarn-queue-manager)
8. [Phase 4 — Hue HTTPS (UI + LB)](#8-phase-4--hue-https-ui--lb)
9. [Phase 5 — Hue → Hive trust](#9-phase-5--hue--hive-trust)
10. [End-to-end validation](#10-end-to-end-validation)
11. [Rollback](#11-rollback)
12. [Troubleshooting](#12-troubleshooting)
13. [Master checklist](#13-master-checklist)
14. [Related documents](#14-related-documents)

---

## 1. Environment matrix

Replace placeholders with the target environment. Confirm PET hostnames before cutover if they differ.

| Item | INT | PROD | PET |
|------|-----|------|-----|
| Domain | `int.corp.amdocs.azr` | `prod.corp.amdocs.azr` | `pet.corp.amdocs.azr` |
| Prefix | `int-01-` | `prod-01-` | `pet-01-` (confirm) |
| CM host | `…-cdhmng01` | `…-cdhmng01` | `…-cdhmng01` |
| Hue hosts | `…-cdhmng02`, `…-cdhmng03` | same | same |
| CM alias | `cm.int.corp.amdocs.azr` | `cm.prod.corp.amdocs.azr` | `cm.pet.corp.amdocs.azr` |
| Hue alias | `hue.int.corp.amdocs.azr` | `hue.prod.corp.amdocs.azr` | `hue.pet.corp.amdocs.azr` |
| CM URL | `https://…-cdhmng01…:7183` | same pattern | same pattern |
| Hue URL | `https://…-cdhmng02…:8889/hue/` | same pattern | same pattern |
| Jenkins (example) | `…/int-corp-amdocs/CM/` | `…/prod-corp-amdocs-azr/PROD-CM*` | `…/pet-corp-amdocs-azr/` |

**Variables used below:**

```text
ENV_DOMAIN   = <int|prod|pet>.corp.amdocs.azr
CM_HOST      = <prefix>-cdhmng01.<ENV_DOMAIN>
HUE_HOST_A   = <prefix>-cdhmng02.<ENV_DOMAIN>
HUE_HOST_B   = <prefix>-cdhmng03.<ENV_DOMAIN>
CM_ALIAS     = cm.<ENV_DOMAIN>
HUE_ALIAS    = hue.<ENV_DOMAIN>
```

---

## 2. Architecture and trust model

```text
Browser ──HTTPS:7183──► CM Server (cm-ui.jks) ── also serves Queue Manager TLS
Agent   ──mTLS:7182──► CM Server (cm-ui.jks + cm-ui-trust.jks)
                         trust includes A1 CAs + Amdocs Internal CA

Browser ──HTTPS:8889──► Hue LB (hue-fullchain.pem) ──► Hue Server :8888 (TLS)
Hue Server ──TLS──► HiveServer2 (trust via ssl_cacerts = hue-trust-combined.pem)
                    └── must include Amdocs Internal CA (not A1-only)
```

| Component | Artifact | Host(s) | Trust notes |
|-----------|----------|---------|-------------|
| CM UI | `cm-ui.jks` / `cm-ui-trust.jks` | cdhmng01 | Truststore = A1 + **amdocs-internal-ca** |
| YARN Queue Manager | **Same** `cm-ui.jks` | cdhmng01 (typical) | Reuses CM server TLS |
| Agents | Client: `keystore-kafka.*`; Server trust: A1 in `CAcerts` | **All** cluster hosts | Keep client_* uncommented |
| Hue UI / LB | `hue-fullchain.pem` + `hue-*.key` | cdhmng02, cdhmng03 | A1 leaf + chain |
| Hue → Hive | **`hue-trust-combined.pem`** | cdhmng02, cdhmng03 | A1 root + `ra-admin-truststore.pem` |
| Firehose | `keystore-kafka.jks` | Management Service | **Never** switch to `cm-ui.jks` |

### What must not change

| Leave unchanged | Why |
|-----------------|-----|
| `/etc/certificate/keystore-kafka.jks` (cluster identity) | Kafka / ZK / Firehose / agent client |
| Auto-TLS | Remains disabled |
| LDAP TLS settings (unless separately planned) | Unrelated to Hue UI HTTPS |

---

## 3. Certificate strategy and SANs

### 3.1 Recommended: two deployments (CM vs Hue)

| Cert | Used for | Minimum SANs |
|------|----------|--------------|
| **CM leaf** | CM UI 7183, agent RPC 7182, Queue Manager | `cdhmng01`, FQDN, `cm.<domain>` |
| **Hue leaf** | Hue Server + LB on 02/03 | `cdhmng02` FQDN, `cdhmng03` FQDN, `hue.<domain>` |

**Do not** replace `cm-ui.jks` with a Hue-only cert (missing cdhmng01 / cm alias breaks CM).

### 3.2 Optional: one multi-SAN leaf (CM + Hue)

If PKI allows one CSR with all names (as on PROD-FULL-SAN), you may reuse the same leaf for:

- CM JKS on cdhmng01, **and**
- Hue PEMs on cdhmng02/03

Still deploy **JKS** on CM host and **PEM** on Hue hosts (different formats/paths).

### 3.3 CSR SAN templates

**CM (minimum):**

```text
DNS: <prefix>-cdhmng01
DNS: <prefix>-cdhmng01.<ENV_DOMAIN>
DNS: cm.<ENV_DOMAIN>
```

**Hue (minimum):**

```text
DNS: <prefix>-cdhmng02.<ENV_DOMAIN>
DNS: <prefix>-cdhmng03.<ENV_DOMAIN>
DNS: hue.<ENV_DOMAIN>
```

(Add short hostnames if users browse without FQDN.)

### 3.4 Files from A1 PKI

| File | Purpose |
|------|---------|
| Leaf `.cer` / `.pem` | Server certificate |
| Leaf `.key` | Private key |
| `A1-…-IssuingCA01-Silver.cer` | Intermediate |
| `A1-…-RootCA-Silver.cer` | Root |

---

## 4. Prerequisites and backups

- [ ] Change window / CAB
- [ ] CM Full Administrator
- [ ] Root SSH to CM + Hue + all agent hosts
- [ ] A1 leaf/key/CAs available on Jenkins or build host
- [ ] DNS for `cm.` / `hue.` aliases (or use host FQDNs)
- [ ] VDI can resolve Hue hosts (INT lesson: DNS_FAIL blocks browser even if cert is correct)

**Backup on CM host:**

```bash
BACKUP=/var/tmp/cm-https-backup-$(date +%Y%m%d)
mkdir -p "$BACKUP"
cp -a /etc/cloudera-scm-server "$BACKUP/"
cp -a /etc/cloudera-scm-agent/config.ini "$BACKUP/config.ini.cmhost"
```

**Backup Hue TLS config (screenshot or export CM config) before changing Hue SSL paths.**

---

## 5. Phase 1 — Build CM keystores

On Jenkins or a build host (paths are environment-specific):

```bash
# Normalize to PEM
openssl x509 -in cm-leaf.cer -out cm-leaf.pem   # or DER→PEM as needed
cp A1-…-IssuingCA01-Silver.cer issuing.pem
cp A1-…-RootCA-Silver.cer root.pem

openssl verify -CAfile root.pem -untrusted issuing.pem cm-leaf.pem
openssl x509 -in cm-leaf.pem -noout -subject -ext subjectAltName

# PKCS12 → JKS
openssl pkcs12 -export \
  -inkey cm-leaf.key -in cm-leaf.pem -certfile issuing.pem \
  -out cm-ui.p12 -name cm-ui -passout pass:changeit

keytool -importkeystore -noprompt \
  -srckeystore cm-ui.p12 -srcstoretype PKCS12 -srcstorepass changeit \
  -destkeystore cm-ui.jks -deststoretype JKS -deststorepass changeit \
  -srcalias cm-ui -destalias cm-ui

# Truststore: A1 + Amdocs Internal CA (agent mTLS)
keytool -importcert -noprompt -alias a1-issuing-ca \
  -file issuing.pem -keystore cm-ui-trust.jks -storepass changeit
keytool -importcert -noprompt -alias a1-root-ca \
  -file root.pem -keystore cm-ui-trust.jks -storepass changeit

# Export Amdocs Internal CA from existing RA truststore (alias varies by env)
keytool -list -v -keystore /etc/certificate/ra-admin-truststore.jks \
  -storepass '<ra-password>' | grep -i alias
keytool -exportcert -rfc -alias '<amdocs-alias>' \
  -keystore /etc/certificate/ra-admin-truststore.jks \
  -storepass '<ra-password>' -file amdocs-internal-ca.pem
keytool -importcert -noprompt -alias amdocs-internal-ca \
  -file amdocs-internal-ca.pem -keystore cm-ui-trust.jks -storepass changeit

keytool -list -keystore cm-ui.jks -storepass changeit
keytool -list -keystore cm-ui-trust.jks -storepass changeit | grep -E 'a1-|amdocs|cm-ui'
```

---

## 6. Phase 2 — Deploy CM UI HTTPS + agents

### 6.1 Install on CM server (`cdhmng01`)

```bash
sudo mkdir -p /etc/cloudera-scm-server/ssl
sudo cp cm-ui.jks cm-ui-trust.jks /etc/cloudera-scm-server/ssl/
sudo chown cloudera-scm:cloudera-scm /etc/cloudera-scm-server/ssl/*.jks
sudo chmod 600 /etc/cloudera-scm-server/ssl/*.jks
# Directory must be traversable by cloudera-scm (often root:cloudera-scm 750)
sudo chown root:cloudera-scm /etc/cloudera-scm-server/ssl
sudo chmod 750 /etc/cloudera-scm-server/ssl
```

**`/etc/cloudera-scm-server/cloudera-scm-server.properties`:**

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

### 6.2 CM UI TLS (overrides properties — critical)

**Administration → Settings → TLS**

| Setting | Value |
|---------|--------|
| Server Keystore | `/etc/cloudera-scm-server/ssl/cm-ui.jks` |
| Server Keystore Password | `changeit` |
| Trust Store | `/etc/cloudera-scm-server/ssl/cm-ui-trust.jks` |
| Trust Store Password | `changeit` |
| Agent TLS authentication | Keep **enabled** |
| Auto-TLS | **Disabled** |

> If UI still points at `keystore-kafka.jks`, 7183 serves the wrong cert (`CN=username`).

### 6.3 Cloudera Management Service TLS

**Cloudera Management Service → Configuration → TLS**

| Setting | Value |
|---------|--------|
| Client Truststore | `/etc/cloudera-scm-server/ssl/cm-ui-trust.jks` |
| Truststore password | `changeit` |
| **Firehose keystore** | **`/etc/certificate/keystore-kafka.jks`** (password `Root00`) |

### 6.4 Restart CM server

```bash
sudo systemctl restart cloudera-scm-server
sleep 60
grep -E "7182|7183|SslContextFactory|Started ServerConnector|x509 \(cm-ui" \
  /var/log/cloudera-scm-server/cloudera-scm-server.log | tail -20
```

### 6.5 Agents — all cluster hosts

On **every** host (mgmt + data):

```bash
sudo mkdir -p /opt/cloudera/security/CAcerts
sudo cp root.pem issuing.pem /opt/cloudera/security/CAcerts/
# use consistent names, e.g. A1-RootCA.pem / A1-IssuingCA.pem
sudo chmod 644 /opt/cloudera/security/CAcerts/*.pem
sudo openssl rehash /opt/cloudera/security/CAcerts
```

**`/etc/cloudera-scm-agent/config.ini` — both required:**

```ini
verify_cert_dir=/opt/cloudera/security/CAcerts
#verify_cert_file=/etc/certificate/ra-admin-truststore.pem

client_key_file=/etc/certificate/keystore-kafka.key
client_cert_file=/etc/certificate/keystore-kafka.pem
client_keypw_file=/etc/certificate/agentkey.pw
```

```bash
sudo systemctl restart cloudera-scm-agent
```

Then **Cloudera Management Service → Actions → Start**. Wait until hosts are green and all Management roles Started.

---

## 7. Phase 3 — YARN Queue Manager

Queue Manager typically reuses the **CM UI TLS** material on cdhmng01.

1. Confirm CM HTTPS works on `:7183` with A1 cert.
2. **YARN → Queue Manager → Configuration** → TLS/SSL:
   - Use CM keystore paths if QM is configured to share CM TLS, **or**
   - Point QM TLS settings at `/etc/cloudera-scm-server/ssl/cm-ui.jks` / truststore as required by your CM version.
3. Restart Queue Manager roles if prompted.
4. Validate browser/API to Queue Manager HTTPS URL (often via CM or QM port — confirm per env).

**Rule:** Queue Manager must present a cert whose SAN matches the hostname users use; with shared `cm-ui.jks`, that is the **CM leaf SANs** (cdhmng01 / `cm.` alias).

---

## 8. Phase 4 — Hue HTTPS (UI + LB)

### 8.1 Build Hue PEMs (Jenkins)

```bash
# From Hue leaf (or multi-SAN leaf shared with CM)
cat hue-leaf.pem issuing.pem root.pem > hue-fullchain.pem
cp hue-leaf.key hue-<env>.key          # e.g. hue-prod.key / hue-int.key
grep -c "BEGIN CERTIFICATE" hue-fullchain.pem   # expect 3
openssl verify -CAfile root.pem -untrusted issuing.pem hue-leaf.pem
openssl x509 -in hue-leaf.pem -noout -ext subjectAltName
```

### 8.2 Deploy to **both** Hue hosts

```bash
sudo mkdir -p /etc/cloudera/security/hue
sudo cp hue-fullchain.pem hue-<env>.key root.pem /etc/cloudera/security/hue/

# Parent dirs must allow hue to traverse
sudo chmod 755 /etc/cloudera /etc/cloudera/security

# Combined trust — required for Hue→Hive (Phase 5); create now
cat /etc/cloudera/security/hue/root.pem \
    /etc/certificate/ra-admin-truststore.pem \
  > /etc/cloudera/security/hue/hue-trust-combined.pem

sudo chown -R hue:hue /etc/cloudera/security/hue
sudo chmod 755 /etc/cloudera/security/hue
sudo chmod 644 /etc/cloudera/security/hue/*.pem
sudo chmod 600 /etc/cloudera/security/hue/hue-<env>.key

sudo -u hue test -r /etc/cloudera/security/hue/hue-fullchain.pem && echo OK_fullchain
sudo -u hue test -r /etc/cloudera/security/hue/hue-<env>.key && echo OK_key
sudo -u hue test -r /etc/cloudera/security/hue/hue-trust-combined.pem && echo OK_trust
```

> **Owner must be `hue:hue`.** `root:root` + `640` often blocks Hue from reading the truststore.

### 8.3 Cloudera Manager — Hue TLS

**Hue → Configuration → TLS**

| Setting | Value |
|---------|--------|
| **Enable TLS/SSL for Hue** (`ssl_enable`) | ✓ **Checked** (mandatory) |
| `ssl_certificate` | `/etc/cloudera/security/hue/hue-fullchain.pem` |
| `ssl_private_key` | `/etc/cloudera/security/hue/hue-<env>.key` |
| **`ssl_cacerts`** | **`/etc/cloudera/security/hue/hue-trust-combined.pem`** |
| LB certificate / key | Same fullchain + key |
| Enable TLS for Load Balancer | ✓ Checked (if shown) |

Optional safety valve (`hue_safety_valve.ini`):

```ini
[desktop]
ssl_certificate_chain=/etc/cloudera/security/hue/hue-fullchain.pem
```

### 8.4 Rolling restart Hue

**Hue → Actions → Rolling Restart**

- ✓ Stale configuration only (preferred)
- ✓ Hue Server + Load Balancer
- KTR optional

```bash
CONF=$(ls -td /var/run/cloudera-scm-agent/process/*-hue-HUE_SERVER | head -1)
grep -E 'ssl_certificate|ssl_private_key|ssl_cacerts' "$CONF/hue.ini"
# must show all three; ssl_cacerts = hue-trust-combined.pem
```

**User URL:** `https://<HUE_HOST_A>:8889/hue/` (not `http://…:8888`).

---

## 9. Phase 5 — Hue → Hive trust

### 9.1 Why combined trust is mandatory

| File | Role |
|------|------|
| `hue-fullchain.pem` | What **browsers** see (A1) |
| `ssl_cacerts` → `hue-trust-combined.pem` | What Hue uses for **outbound** TLS (Hive, Impala, …) |

`ra-admin-truststore.pem` is typically **CN=Amdocs Internal CA** (cluster TLS).  
Setting `ssl_cacerts` to A1 `root.pem` **only** → login works, Hive fails (`NoneType` / `settimeout` / No databases).

```bash
# Confirm Amdocs CA in ra-admin PEM
openssl crl2pkcs7 -nocrl -certfile /etc/certificate/ra-admin-truststore.pem 2>/dev/null \
  | openssl pkcs7 -print_certs -noout
```

### 9.2 CM setting (already set in Phase 4)

```text
ssl_cacerts = /etc/cloudera/security/hue/hue-trust-combined.pem
```

After any trust-file change: Rolling Restart **Hue Server** (both hosts).

### 9.3 Validate Hive from Hue

1. Open `https://<HUE_HOST>:8889/hue/` → Hive editor  
2. Databases list must populate  
3. `SHOW DATABASES;` or `SELECT 1;` succeeds  

If Tez then fails with **Snappy** / `Could not initialize class org.xerial.snappy.Snappy` and `/tmp` is `noexec`, that is **not** a Hue cert issue — set `-Djava.io.tmpdir=` to an exec-capable path on YARN/Tez hosts (see troubleshooting).

---

## 10. End-to-end validation

| # | Check | Command / action |
|---|--------|------------------|
| 1 | CM cert on 7183 | `openssl s_client -connect <CM_HOST>:7183 -servername <CM_ALIAS>` → A1 issuer + SANs |
| 2 | CM UI login | Browser `https://<CM_HOST>:7183` |
| 3 | Hosts green | All agents heartbeating |
| 4 | Management Service | All roles Started; charts populate |
| 5 | Firehose keystore | Still `keystore-kafka.jks` |
| 6 | Queue Manager | HTTPS / UI reachable with expected cert |
| 7 | Hue LB TLS | `openssl s_client -connect <HUE_HOST>:8889 …` → A1 + Hue SANs |
| 8 | Hue login | `https://<HUE_HOST>:8889/hue/` |
| 9 | Hue → Hive | Databases listed; simple query OK |
| 10 | `hue.ini` | Contains `ssl_certificate`, `ssl_private_key`, `ssl_cacerts=…hue-trust-combined.pem` |

---

## 11. Rollback

| Layer | Action |
|-------|--------|
| Hue TLS only | Uncheck Enable TLS; or set `ssl_cacerts` back to `/etc/certificate/ra-admin-truststore.pem`; restart Hue |
| CM UI | Restore backup `ssl/` + properties; set Admin → TLS back to previous keystore; restart `cloudera-scm-server` |
| Agents | Restore `config.ini` / `CAcerts`; restart agents |
| Queue Manager | Follow CM TLS rollback if it shared `cm-ui.jks` |

---

## 12. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| 7183 wrong cert / `CN=username` | UI TLS still on `keystore-kafka.jks` | Admin → Settings → TLS → `cm-ui.jks` |
| `sslv3 alert bad certificate` (agents) | `client_*` commented after `verify_cert_dir` | Uncomment client key/cert/pw; restart agent |
| Permission denied on JKS | ssl dir `root:root` 750 | `chown root:cloudera-scm`; `chmod 750` on dir; JKS `cloudera-scm` 600 |
| Hue won't start; `REQUESTS_CA_BUNDLE does not exist` | Parent `/etc/cloudera/security` 750 root:root | `chmod 755 /etc/cloudera /etc/cloudera/security` |
| `ERR_SSL_PROTOCOL_ERROR` on Hue :8889 | `ssl_enable` off / LB HTTP | Check Enable TLS; restart Hue Server + LB; use `https://` |
| Login OK; Hive No databases / `NoneType`… | `ssl_cacerts` = A1 only | Use **`hue-trust-combined.pem`**; `chown hue:hue`; restart Hue Server |
| `hue-trust-combined.pem` is `root:root` 640 | Hue cannot read trust | `chown hue:hue`; `chmod 644` |
| Firehose / Host Monitor TLS errors | Firehose set to `cm-ui.jks` | Revert to `keystore-kafka.jks` |
| Tez Snappy init failure | `/tmp` `noexec` | `-Djava.io.tmpdir=/var/lib/cloudera-scm/tmp` on YARN/Tez (not Hue cert) |

---

## 13. Master checklist

### CM + agents + Queue Manager

- [ ] CM leaf SANs correct; JKS + truststore built (A1 + amdocs-internal-ca)
- [ ] Deployed to `/etc/cloudera-scm-server/ssl/` with correct ownership
- [ ] Admin → Settings → TLS points to `cm-ui.jks` / `cm-ui-trust.jks`
- [ ] Management Service client truststore = `cm-ui-trust.jks`; Firehose = `keystore-kafka.jks`
- [ ] Agents: `verify_cert_dir` + uncommented `client_*`; A1 in `CAcerts`; all hosts green
- [ ] Queue Manager HTTPS validated

### Hue + Hive

- [ ] Hue PEMs on **both** cdhmng02 and cdhmng03
- [ ] Parent dirs `755`; files `hue:hue`; key `600`; PEMs `644`
- [ ] **`hue-trust-combined.pem`** = A1 root + ra-admin (Amdocs Internal CA), `hue:hue`
- [ ] Enable TLS checked; LB TLS enabled
- [ ] `ssl_cacerts` = combined path (not A1 root alone)
- [ ] Rolling restart Hue Server + LB
- [ ] HTTPS :8889 login OK
- [ ] Hive databases + simple query OK

### Environment sign-off

- [ ] INT / PROD / PET (as applicable) validated with env-specific hostnames
- [ ] User URLs documented (CM :7183, Hue :8889)

---

## 14. Related documents

| Document | Use when |
|----------|----------|
| `CM_PROD_HTTPS_SAML_RUNBOOK.md` | PROD CM HTTPS detail + Ping SAML |
| `CM_PROD_HUE_HTTPS_RUNBOOK.md` | PROD Hue-only deep dive |
| `CM_INT_HUE_HTTPS_RUNBOOK.md` | INT Hue-only (keep existing `cm-ui.jks`) |
| `CM_STANDALONE_HTTPS_RUNBOOK.md` | Single-node / UAT standalone |
| `scripts/build_standalone_cm_keystores.sh` | UAT standalone JKS automation |

---

## Document history

| Date | Change |
|------|--------|
| 2026-07-28 | Initial consolidated multi-node E2E runbook (INT/PROD/PET): CM, Queue Manager, Hue UI, Hue→Hive |

*Pattern validated on PROD and INT Hue rollouts (2026); apply same steps to PET with PET host/DNS names.*
