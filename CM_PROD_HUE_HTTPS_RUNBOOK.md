# Hue PROD — Permanent HTTPS (A1 PKI) Runbook

| Field | Value |
|-------|-------|
| **Environment** | Production (`prod.corp.amdocs.azr`) |
| **CM / Runtime** | 7.11.3 / 7.1.9 |
| **Hue hosts** | `prod-01-cdhmng02`, `prod-01-cdhmng03` |
| **Current state** | HTTP on 8888 (Hue Server) and 8889 (Load Balancer) |
| **Target state** | HTTPS on 8889 (primary user URL) |
| **Certificate authority** | A1 Silver PKI (same as CM / Queue Manager) |
| **Jenkins path (suggested)** | `/pciuser/tools/jenkins/jenkins-production/prod-corp-amdocs-azr/PROD-CM/HUE-A1-SIGNED` |

---

## 1. Problem summary

| URL (current) | Protocol | Issue |
|---------------|----------|-------|
| `http://prod-01-cdhmng02:8888/hue/` | HTTP | Hue Server direct — non-optimized |
| `http://prod-01-cdhmng03:8888/hue/` | HTTP | Hue Server direct — non-optimized |
| `http://prod-01-cdhmng02:8889/hue/` | HTTP | Load Balancer — no TLS |
| `http://prod-01-cdhmng03:8889/hue/` | HTTP | Load Balancer — no TLS |

**Root cause in CM:** `Enable TLS/SSL for Hue` is **unchecked**; cert/key fields are **empty**.

**Why not reuse `cm-ui.jks` as-is:**

- CM cert SANs cover `cdhmng01` / `cm.prod...` only — **not** `cdhmng02` / `cdhmng03`
- Hue requires **PEM** files on **Hue hosts**, not JKS on `cdhmng01`
- Permanent fix = **dedicated A1 Hue certificate** with correct SANs

---

## 2. Architecture

```text
                    ┌─────────────────────────────────────┐
  Browser ──HTTPS──►│ Hue Load Balancer :8889             │
  (use this URL)    │  prod-01-cdhmng02 OR cdhmng03     │
                    └──────────────┬──────────────────────┘
                                   │ TLS to backends
                    ┌──────────────▼──────────────────────┐
                    │ Hue Server :8888 (TLS enabled)      │
                    │  on cdhmng02 + cdhmng03             │
                    └─────────────────────────────────────┘
```

| Role | Hosts | Port (HTTP today) | Port (HTTPS target) |
|------|-------|-------------------|---------------------|
| Hue Load Balancer | cdhmng02, cdhmng03 | 8889 | **8889 HTTPS** |
| Hue Server | cdhmng02, cdhmng03 | 8888 | 8888 HTTPS (backend) |

**Standard user URL after fix:**

```text
https://prod-01-cdhmng02.prod.corp.amdocs.azr:8889/hue/
```

(Optional DNS alias: `https://hue.prod.corp.amdocs.azr:8889/hue/`)

---

## 3. Certificate requirements

### 3.1 Request new A1 certificate (Hue)

**CN:** `hue.prod.corp.amdocs.azr`

**Required SANs:**

```text
DNS: prod-01-cdhmng02
DNS: prod-01-cdhmng02.prod.corp.amdocs.azr
DNS: prod-01-cdhmng03
DNS: prod-01-cdhmng03.prod.corp.amdocs.azr
DNS: hue.prod.corp.amdocs.azr
```

### 3.2 CSR template (`hue_csr.conf`)

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
CN = hue.prod.corp.amdocs.azr

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = prod-01-cdhmng02
DNS.2 = prod-01-cdhmng02.prod.corp.amdocs.azr
DNS.3 = prod-01-cdhmng03
DNS.4 = prod-01-cdhmng03.prod.corp.amdocs.azr
DNS.5 = hue.prod.corp.amdocs.azr
```

```bash
openssl genrsa -out hue-prod.key 4096
openssl req -new -key hue-prod.key -out hue-prod.csr -config hue_csr.conf
openssl req -in hue-prod.csr -noout -text | grep -A5 "Subject Alternative Name"
```

Submit CSR to A1 PKI; receive signed `hue-prod.cer` + chain CAs.

---

## 4. Build PEM files (Jenkins)

```bash
cd /pciuser/tools/jenkins/jenkins-production/prod-corp-amdocs-azr/PROD-CM/HUE-A1-SIGNED

# Convert to PEM if needed
cp hue-prod.cer hue-prod.pem
cp A1-Telekom-Austria-AG-IssuingCA01-Silver.cer issuing.pem
cp A1-Telekom-Austria-AG-RootCA-Silver.cer root.pem

# Verify chain
openssl verify -CAfile root.pem -untrusted issuing.pem hue-prod.pem
openssl x509 -in hue-prod.pem -noout -subject -issuer -ext subjectAltName

# Full chain for Hue ssl_certificate (order: server, intermediate, root)
cat hue-prod.pem issuing.pem root.pem > hue-fullchain.pem
grep -c "BEGIN CERTIFICATE" hue-fullchain.pem   # expect 3
```

---

## 5. Deploy certificates to Hue hosts

Run on **both** `prod-01-cdhmng02` and `prod-01-cdhmng03`:

```bash
sudo mkdir -p /etc/cloudera/security/hue
sudo cp hue-fullchain.pem hue-prod.key root.pem /etc/cloudera/security/hue/

# Parent dirs must allow hue to traverse (common PROD trap: security/ is root:root 750)
sudo chmod 755 /etc/cloudera /etc/cloudera/security

# Combined trust for Hue→Hive (see §5.1) — do this on BOTH hosts
cat /etc/cloudera/security/hue/root.pem \
    /etc/certificate/ra-admin-truststore.pem \
  > /etc/cloudera/security/hue/hue-trust-combined.pem

sudo chown -R hue:hue /etc/cloudera/security/hue
sudo chmod 755 /etc/cloudera/security/hue
sudo chmod 644 /etc/cloudera/security/hue/hue-fullchain.pem
sudo chmod 644 /etc/cloudera/security/hue/root.pem
sudo chmod 644 /etc/cloudera/security/hue/hue-trust-combined.pem
sudo chmod 600 /etc/cloudera/security/hue/hue-prod.key

ls -la /etc/cloudera/security/hue/
namei -l /etc/cloudera/security/hue/hue-trust-combined.pem
grep -c "BEGIN CERTIFICATE" /etc/cloudera/security/hue/hue-trust-combined.pem   # expect >= 2

# Must succeed as hue — file ownership alone is not enough if a parent is 750 root:root
sudo -u hue test -r /etc/cloudera/security/hue/hue-fullchain.pem && echo OK_fullchain
sudo -u hue test -r /etc/cloudera/security/hue/hue-prod.key && echo OK_key
sudo -u hue test -r /etc/cloudera/security/hue/hue-trust-combined.pem && echo OK_trust
```

### 5.1 Why `ssl_cacerts` must be a combined trust (Hue → Hive)

Hue **`ssl_cacerts`** is not only “Hue server CA.” CM maps it into Hue’s outbound trust (`REQUESTS_CA_BUNDLE`). Hue uses it when connecting to **HiveServer2**, Impala, and other TLS backends.

| CA in trust | Needed for |
|-------------|------------|
| A1 Silver Root (`root.pem`) | Trusting A1-signed material / consistency with Hue UI PKI |
| **Amdocs Internal CA** (`ra-admin-truststore.pem`) | Trusting **cluster TLS** (HiveServer2, etc.) |

On PROD, `ra-admin-truststore.pem` is the Amdocs Internal CA:

```bash
openssl crl2pkcs7 -nocrl -certfile /etc/certificate/ra-admin-truststore.pem 2>/dev/null \
  | openssl pkcs7 -print_certs -noout
# expect: subject=CN = Amdocs Internal CA
```

| Wrong | Right |
|-------|-------|
| Set `ssl_cacerts` = A1 `root.pem` **only** | Set `ssl_cacerts` = **`hue-trust-combined.pem`** |
| Drop `ra-admin-truststore.pem` entirely | **Keep** Amdocs Internal CA **inside** the combined file |

**Symptom if A1-only:** Hue login works; Hive editor shows **No databases found** / `'NoneType' object has no attribute 'settimeout'` / `'id'`.

> **PROD lesson (cdhmng02):** Files were correctly `hue:hue` 644/600, but `/etc/cloudera/security` was `drwxr-x--- root:root`. Hue could not enter the path → startup failed with `REQUESTS_CA_BUNDLE does not exist`. Fix = `chmod 755` on `/etc/cloudera` and `/etc/cloudera/security`.

**File map:**

| CM setting | Path on Hue hosts |
|------------|-------------------|
| `ssl_certificate` | `/etc/cloudera/security/hue/hue-fullchain.pem` |
| `ssl_private_key` | `/etc/cloudera/security/hue/hue-prod.key` |
| **`ssl_cacerts`** | **`/etc/cloudera/security/hue/hue-trust-combined.pem`** |
| Load Balancer cert/key | Same fullchain + key as Hue Server |
| `root.pem` (A1 only) | Keep on disk for building chain / combined trust — **not** used alone as `ssl_cacerts` |

---

## 6. Cloudera Manager configuration

**Hue → Configuration** → search **`TLS`** / `SSL`

### 6.1 Hue Server (Default Group)

| Setting | Value |
|---------|--------|
| **Enable TLS/SSL for Hue** (`ssl_enable`) | ✓ **Checked** — **mandatory**; cert paths alone do nothing |
| **Hue TLS/SSL Server Certificate File** (`ssl_certificate`) | `/etc/cloudera/security/hue/hue-fullchain.pem` |
| **Hue TLS/SSL Server Private Key File** (`ssl_private_key`) | `/etc/cloudera/security/hue/hue-prod.key` |
| **Hue TLS/SSL Server CA Certificate** (`ssl_cacerts`) | **`/etc/cloudera/security/hue/hue-trust-combined.pem`** |
| **Hue TLS/SSL Private Key Password** (`ssl_password`) | Leave empty if key is not encrypted |

### 6.2 Hue Load Balancer (Default Group)

| Setting | Value |
|---------|--------|
| **Enable TLS/SSL for Hue Load Balancer** | ✓ **Checked** (if shown) |
| **Hue Load Balancer TLS/SSL Server Certificate File** | `/etc/cloudera/security/hue/hue-fullchain.pem` |
| **Hue Load Balancer TLS/SSL Server Private Key File** | `/etc/cloudera/security/hue/hue-prod.key` |
| **Hue Load Balancer TLS/SSL Server SSLPassPhraseDialog** | Only if key is password-protected |
| **SSLProtocol** | `+TLSv1.2` (keep) |
| **Hue Load Balancer Port** | `8889` (default) |

### 6.3 ssl_cacerts — correct change (do not use A1-only)

| Before (typical) | After (required) |
|------------------|------------------|
| `/etc/certificate/ra-admin-truststore.pem` | **`/etc/cloudera/security/hue/hue-trust-combined.pem`** |

Do **not** set `ssl_cacerts` to `/etc/cloudera/security/hue/root.pem` alone.

`ssl_cacerts` is Hue’s outbound trust for **Hive/Impala**, not only the UI CA.

After restart, confirm deployed config:

```bash
CONF=$(ls -td /var/run/cloudera-scm-agent/process/*-hue-HUE_SERVER | head -1)
grep -E 'ssl_certificate|ssl_private_key|ssl_cacerts' "$CONF/hue.ini"
# expect ssl_cacerts=.../hue-trust-combined.pem
# expect ssl_certificate and ssl_private_key present
```

> **PROD lesson:** Paths were filled in CM while **Enable TLS/SSL for Hue** stayed unchecked → deployed `hue.ini` had only `ssl_cacerts` (no `ssl_certificate` / `ssl_private_key`) → `https://...:8889` returned `ERR_SSL_PROTOCOL_ERROR`. Always verify the checkbox **and** `grep ssl_` after restart.

### 6.4 Safety Valve (optional)

**Hue Service Advanced Configuration Snippet** (`hue_safety_valve.ini`):

```ini
[desktop]
ssl_certificate_chain=/etc/cloudera/security/hue/hue-fullchain.pem
```

### 6.5 Do NOT change

| Setting | Leave as-is |
|---------|-------------|
| **Enable LDAP TLS** | Unchanged (LDAP only) |
| CM `cm-ui.jks` | CM / Queue Manager only |
| `keystore-kafka.jks` | Cluster services only |

---

## 7. Apply and restart

1. **Save** Hue configuration in CM
2. **Deploy client configuration** (if prompted)
3. **Hue → Actions → Rolling Restart**
   - ✓ Restart roles with stale configuration only
   - ✓ **Hue Server** (required for `ssl_cacerts` / Hive trust)
   - ✓ **Load Balancer** (if TLS enable or cert/key changed)
   - Kerberos Ticket Renewer optional (clears “outdated” banner only)
4. Wait until **Hue Server** and **Load Balancer** on cdhmng02/03 are **Started / Good**

```bash
# On each Hue host — verify listener
ss -tlnp | grep -E '8888|8889'
```

---

## 8. Validation

### 8.1 OpenSSL (from any host)

```bash
# Load Balancer HTTPS (primary)
echo | openssl s_client -connect prod-01-cdhmng02.prod.corp.amdocs.azr:8889 \
  -servername hue.prod.corp.amdocs.azr 2>&1 | head -35

echo | openssl s_client -connect prod-01-cdhmng03.prod.corp.amdocs.azr:8889 \
  -servername hue.prod.corp.amdocs.azr 2>&1 | head -35
```

**Expected:**

- `CONNECTED`
- Issuer: `A1-Telekom-Austria-AG-IssuingCA01-Silver`
- Subject/SAN includes `hue.prod.corp.amdocs.azr` or `prod-01-cdhmng02`

### 8.2 Browser

| URL | Expected |
|-----|----------|
| `https://prod-01-cdhmng02.prod.corp.amdocs.azr:8889/hue/` | Padlock, login page |
| `https://prod-01-cdhmng03.prod.corp.amdocs.azr:8889/hue/` | Padlock, login page |
| `http://...:8888/hue/` | Do not use (non-optimized / HTTP) |

### 8.3 Hue → Hive (mandatory after ssl_cacerts change)

1. Log into Hue → **Hive** editor
2. Left pane must list databases (not **No databases found**)
3. Run a simple query, e.g. `SHOW DATABASES;` or `SELECT 1;`

If login works but Hive fails with `NoneType` / `settimeout` / `id`:

- Re-check `ssl_cacerts` points to **`hue-trust-combined.pem`** on **both** hosts
- Confirm combined file contains Amdocs Internal CA (`grep -c BEGIN` ≥ 2)
- Rolling-restart **Hue Server** again after fixing the path

### 8.4 Hue logs (if failure)

```bash
grep -iE "ssl|tls|certificate|hive|NoneType|error" /var/log/hue/*.log | tail -40
```

### 8.5 CM role health

**Hue → Instances** — all Hue Server and Load Balancer roles **Good**.

---

## 9. User communication

After cutover, document:

```text
Hue PROD URL: https://prod-01-cdhmng02.prod.corp.amdocs.azr:8889/hue/
```

- Use **8889** (Load Balancer), not 8888
- Use **https**, not http
- Import **A1 Root CA** on VDI if browser shows warning (same as CM)

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Still HTTP on 8889 / `ERR_SSL_PROTOCOL_ERROR` | TLS not enabled on Hue/LB, or not restarted | Check **Enable TLS/SSL for Hue**; restart Hue Server + LB; use `https://` not `http://` |
| Login OK; Hive **No databases** / `NoneType`…`settimeout` | `ssl_cacerts` = A1 `root.pem` only | Use **`hue-trust-combined.pem`**; restart Hue Server |
| Hue role won't start; `REQUESTS_CA_BUNDLE does not exist` | Parent dir blocks traverse (`/etc/cloudera/security` is `root:root` 750) | `chmod 755 /etc/cloudera /etc/cloudera/security`; verify `sudo -u hue test -r ...` |
| Hue role won't start | PEM file permissions | `chown hue:hue`, `chmod 644/600` on files under `hue/` |
| `hue.ini` has only `ssl_cacerts` | `ssl_enable` unchecked | Check Enable TLS; save; restart; confirm `ssl_certificate` + `ssl_private_key` in `hue.ini` |
| Banner “non-optimized Hue” on `:8888` | Direct Hue Server HTTP URL | Use `https://host:8889/hue/` (Load Balancer) |
| `certificate verify failed` | Wrong chain order | Rebuild `hue-fullchain.pem` (server → issuing → root) |
| Browser name mismatch | Wrong SAN on cert | Re-issue A1 cert with mng02/mng03 SANs |
| `File not found` on one host | Cert only on one host | Deploy PEM to **both** cdhmng02 and cdhmng03 |
| LDAP login fails after TLS | Unrelated LDAP TLS setting | Check LDAP config separately |
| Query reaches Tez then Snappy fails | `/tmp` `noexec` (not Hue cert) | Set `-Djava.io.tmpdir=` to exec-capable path on YARN/Tez hosts |

---

## 11. Rollback

1. **Hue → Configuration → TLS**
2. Uncheck **Enable TLS/SSL for Hue** and Load Balancer TLS  
   **or** set `ssl_cacerts` back to `/etc/certificate/ra-admin-truststore.pem` if only Hive trust must be restored quickly
3. Save → Rolling restart **Hue Server** (+ LB if TLS disabled)
4. Users revert to `http://...:8889/hue/` if TLS fully disabled

---

## 12. Relationship to other TLS work

| Service | Cert | Host | Status |
|---------|------|------|--------|
| CM UI | `cm-ui.jks` | cdhmng01 | Done |
| YARN Queue Manager | `cm-ui.jks` | cdhmng01 | Done |
| Hue | `hue-fullchain.pem` + `hue-trust-combined.pem` | cdhmng02, cdhmng03 | **This runbook** |
| Agents | `keystore-kafka` client | all hosts | Done |
| Kafka / ZK | `keystore-kafka.jks` | cluster | Unchanged |

---

## 13. Execution checklist

- [ ] A1 Hue certificate issued with mng02/mng03/hue.prod SANs
- [ ] `hue-fullchain.pem` + `hue-prod.key` + `root.pem` built on Jenkins
- [ ] Files deployed to `/etc/cloudera/security/hue/` on **cdhmng02** and **cdhmng03**
- [ ] Permissions: `hue:hue`, key `600`, certs `644`
- [ ] Parent dirs `/etc/cloudera` + `/etc/cloudera/security` are `755`; `sudo -u hue test -r` OK
- [ ] **`hue-trust-combined.pem`** = A1 `root.pem` + `ra-admin-truststore.pem` (Amdocs Internal CA)
- [ ] CM: **Enable TLS/SSL for Hue** checked (not only PEM paths)
- [ ] CM: Enable TLS for **Load Balancer** (if shown) + PEM paths
- [ ] CM: **`ssl_cacerts` = hue-trust-combined.pem`** (not A1 root alone)
- [ ] After restart: `hue.ini` contains `ssl_certificate` + `ssl_private_key` + combined `ssl_cacerts`
- [ ] HTTPS on 8889 works (openssl + browser)
- [ ] **Hive editor lists databases** and can run a simple query
- [ ] Safety valve `ssl_certificate_chain` added (optional)
- [ ] User URL documented

---

## Document history

| Date | Change |
|------|--------|
| 2026-06-14 | Initial PROD Hue HTTPS permanent fix runbook |
| 2026-07-23 | PROD rollout lessons: parent-dir `755` for hue traverse; `ssl_enable` mandatory; troubleshooting for REQUESTS_CA_BUNDLE / ERR_SSL_PROTOCOL_ERROR |
| 2026-07-28 | Full align with INT: `ssl_cacerts` → `hue-trust-combined.pem` (A1 + Amdocs Internal CA); §5.1 Hue→Hive; Hive validation; rolling-restart guidance; Snappy note |

*Reference: [Cloudera Hue TLS with CM](https://docs.cloudera.com/runtime/7.2.18/securing-hue/topics/hue-tls-ssl-server-config-with-cm.html), `CM_INT_HUE_HTTPS_RUNBOOK.md`, `CM_PROD_HTTPS_SAML_RUNBOOK.md`*
