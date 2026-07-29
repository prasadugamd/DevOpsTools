# INT — Hue HTTPS Only (Do Not Change cm-ui.jks)

| Field | Value |
|-------|-------|
| **Scope** | Hue Web UI + Load Balancer on INT only |
| **Out of scope** | `/etc/cloudera-scm-server/ssl/cm-ui.jks` — **do not replace** |
| **Hue hosts** | `int-01-cdhmng02`, `int-01-cdhmng03` |
| **Target URL** | `https://int-01-cdhmng02.int.corp.amdocs.azr:8889/hue/` |
| **Jenkins path** | `/pciuser/tools/jenkins/jenkins-production/int-corp-amdocs/CM/INT-FULL-SAN` |

---

## 1. Strategy

CM (`cm-ui.jks` on cdhmng01) and Hue use **separate certificate deployments**:

| Component | Certificate | Location |
|-----------|-------------|----------|
| CM UI / Queue Manager | Existing `cm-ui.jks` | cdhmng01 — **unchanged** |
| Hue Server + LB | **Hue-only PEM** | cdhmng02, cdhmng03 |

---

## 2. Certificate options

### Option A — Use existing `cm-int-mng123` for Hue only (recommended)

You already have a signed cert with Hue SANs:

```text
DNS: int-01-cdhmng02.int.corp.amdocs.azr
DNS: int-01-cdhmng03.int.corp.amdocs.azr
DNS: hue.int.corp.amdocs.azr
```

Deploy **PEM only** to Hue hosts. **Do not** build or copy `cm-ui.jks` from this cert to cdhmng01.

### Option B — New Hue-only PKI request (separate key)

Use if policy requires a dedicated Hue key/cert (not shared with `cm-int-mng123`).

**CSR CN:** `hue.int.corp.amdocs.azr`

**SANs:**

```text
DNS: int-01-cdhmng02
DNS: int-01-cdhmng02.int.corp.amdocs.azr
DNS: int-01-cdhmng03
DNS: int-01-cdhmng03.int.corp.amdocs.azr
DNS: hue.int.corp.amdocs.azr
```

**CSR config (`hue_int_csr.conf`):**

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
CN = hue.int.corp.amdocs.azr

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = int-01-cdhmng02
DNS.2 = int-01-cdhmng02.int.corp.amdocs.azr
DNS.3 = int-01-cdhmng03
DNS.4 = int-01-cdhmng03.int.corp.amdocs.azr
DNS.5 = hue.int.corp.amdocs.azr
```

```bash
openssl genrsa -out hue-int.key 4096
openssl req -new -key hue-int.key -out hue-int.csr -config hue_int_csr.conf
openssl req -in hue-int.csr -noout -text | grep -A5 "Subject Alternative Name"
```

Submit `hue-int.csr` to A1 PKI → receive `hue-int.cer` + chain.

---

## 3. Build Hue PEM files (Jenkins)

### Option A — from `cm-int-mng123` (already signed)

```bash
cd /pciuser/tools/jenkins/jenkins-production/int-corp-amdocs/CM/INT-FULL-SAN

cp cm-int-mng123.cer cm-int-mng123.pem
cp A1-Telekom-Austria-AG-IssuingCA01-Silver.cer issuing.pem
cp A1-Telekom-Austria-AG-RootCA-Silver.cer root.pem

# Verify (must show cdhmng02/03 + hue.int SANs)
openssl x509 -in cm-int-mng123.pem -noout -subject -ext subjectAltName
openssl verify -CAfile root.pem -untrusted issuing.pem cm-int-mng123.pem

# Requires cm-int-mng123.key from original CSR
ls -l cm-int-mng123.key

# Hue artifacts (NOT cm-ui.jks)
cat cm-int-mng123.pem issuing.pem root.pem > hue-fullchain.pem
cp cm-int-mng123.key hue-int.key

# Package for deploy
tar czf hue-int-pem-bundle.tar.gz hue-fullchain.pem hue-int.key root.pem
ls -l hue-fullchain.pem hue-int.key root.pem
grep -c "BEGIN CERTIFICATE" hue-fullchain.pem   # expect 3
```

### Option B — from new `hue-int.cer`

```bash
cp hue-int.cer hue-int.pem
cat hue-int.pem issuing.pem root.pem > hue-fullchain.pem
# hue-int.key = key used for CSR
openssl verify -CAfile root.pem -untrusted issuing.pem hue-int.pem
```

---

## 4. Deploy to Hue hosts only

Run on **int-01-cdhmng02** and **int-01-cdhmng03**:

```bash
sudo mkdir -p /etc/cloudera/security/hue
sudo cp hue-fullchain.pem hue-int.key root.pem /etc/cloudera/security/hue/

# Parent dirs must allow hue to traverse (trap: security/ often root:root 750)
sudo chmod 755 /etc/cloudera /etc/cloudera/security

# Combined trust for Hue→Hive (see §4.1) — do this on BOTH hosts
cat /etc/cloudera/security/hue/root.pem \
    /etc/certificate/ra-admin-truststore.pem \
  > /etc/cloudera/security/hue/hue-trust-combined.pem

sudo chown -R hue:hue /etc/cloudera/security/hue
sudo chmod 755 /etc/cloudera/security/hue
sudo chmod 644 /etc/cloudera/security/hue/hue-fullchain.pem
sudo chmod 644 /etc/cloudera/security/hue/root.pem
sudo chmod 644 /etc/cloudera/security/hue/hue-trust-combined.pem
sudo chmod 600 /etc/cloudera/security/hue/hue-int.key

ls -la /etc/cloudera/security/hue/
grep -c "BEGIN CERTIFICATE" /etc/cloudera/security/hue/hue-trust-combined.pem   # expect >= 2

# Must succeed as hue
sudo -u hue test -r /etc/cloudera/security/hue/hue-fullchain.pem && echo OK_fullchain
sudo -u hue test -r /etc/cloudera/security/hue/hue-int.key && echo OK_key
sudo -u hue test -r /etc/cloudera/security/hue/hue-trust-combined.pem && echo OK_trust
```

### 4.1 Why `ssl_cacerts` must be a combined trust (Hue → Hive)

Hue **`ssl_cacerts`** is not only “Hue server CA.” CM maps it into Hue’s outbound trust (`REQUESTS_CA_BUNDLE`). Hue uses it when connecting to **HiveServer2**, Impala, and other TLS backends.

| CA in trust | Needed for |
|-------------|------------|
| A1 Silver Root (`root.pem`) | Trusting A1-signed material / consistency with Hue UI PKI |
| **Amdocs Internal CA** (`ra-admin-truststore.pem`) | Trusting **cluster TLS** (HiveServer2, etc.) |

On INT/PROD, `ra-admin-truststore.pem` is the Amdocs Internal CA:

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

**File map:**

| CM setting | Path on Hue hosts |
|------------|-------------------|
| `ssl_certificate` | `/etc/cloudera/security/hue/hue-fullchain.pem` |
| `ssl_private_key` | `/etc/cloudera/security/hue/hue-int.key` |
| **`ssl_cacerts`** | **`/etc/cloudera/security/hue/hue-trust-combined.pem`** |
| Load Balancer cert/key | Same fullchain + key as Hue Server |
| `root.pem` (A1 only) | Keep on disk for building chain / combined trust — **not** used alone as `ssl_cacerts` |

**Do not modify** on cdhmng01:

```text
/etc/cloudera-scm-server/ssl/cm-ui.jks
/etc/cloudera-scm-server/ssl/cm-ui-trust.jks
```

---

## 5. Cloudera Manager — Hue configuration only

**Hue → Configuration** → search `TLS` / `SSL`

### Hue Server (Default Group)

| Setting | Value |
|---------|--------|
| **Enable TLS/SSL for Hue** (`ssl_enable`) | ✓ **Checked** — mandatory; paths alone do nothing |
| **Hue TLS/SSL Server Certificate File** (`ssl_certificate`) | `/etc/cloudera/security/hue/hue-fullchain.pem` |
| **Hue TLS/SSL Server Private Key File** (`ssl_private_key`) | `/etc/cloudera/security/hue/hue-int.key` |
| **Hue TLS/SSL Server CA Certificate** (`ssl_cacerts`) | **`/etc/cloudera/security/hue/hue-trust-combined.pem`** |
| **Hue TLS/SSL Private Key Password** | Empty (unless key encrypted) |

### Hue Load Balancer (Default Group)

| Setting | Value |
|---------|--------|
| **Enable TLS/SSL for Hue Load Balancer** | ✓ Checked (if shown) |
| **LB Certificate File** | `/etc/cloudera/security/hue/hue-fullchain.pem` |
| **LB Private Key File** | `/etc/cloudera/security/hue/hue-int.key` |

### ssl_cacerts — correct change (do not use A1-only)

| Before (typical) | After (required) |
|------------------|------------------|
| `/etc/certificate/ra-admin-truststore.pem` | **`/etc/cloudera/security/hue/hue-trust-combined.pem`** |

Do **not** set `ssl_cacerts` to `/etc/cloudera/security/hue/root.pem` alone.

After restart, confirm deployed config:

```bash
CONF=$(ls -td /var/run/cloudera-scm-agent/process/*-hue-HUE_SERVER | head -1)
grep -E 'ssl_certificate|ssl_private_key|ssl_cacerts' "$CONF/hue.ini"
# expect ssl_cacerts=.../hue-trust-combined.pem
# expect ssl_certificate and ssl_private_key present
```

### Safety valve (optional)

**Hue Service Advanced Configuration Snippet** (`hue_safety_valve.ini`):

```ini
[desktop]
ssl_certificate_chain=/etc/cloudera/security/hue/hue-fullchain.pem
```

### Apply

1. **Save Changes**
2. Deploy client config if prompted
3. **Hue → Actions → Rolling Restart**
   - ✓ Restart roles with stale configuration only
   - ✓ **Hue Server** (required for `ssl_cacerts` / Hive trust)
   - ✓ **Load Balancer** (if TLS enable or cert/key changed)
   - Kerberos Ticket Renewer optional (banner only)

---

## 6. Validation

### 6.1 Hue HTTPS (browser / openssl)

```bash
# On cdhmng02
echo | openssl s_client -connect localhost:8889 \
  -servername int-01-cdhmng02.int.corp.amdocs.azr 2>&1 | head -30

# Check SAN on presented cert
echo | openssl s_client -connect int-01-cdhmng02.int.corp.amdocs.azr:8889 \
  -servername int-01-cdhmng02.int.corp.amdocs.azr 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
```

**Browser (use https on 8889 — not http on 8888):**

```text
https://int-01-cdhmng02.int.corp.amdocs.azr:8889/hue/
https://hue.int.corp.amdocs.azr:8889/hue/
```

### 6.2 Hue → Hive (mandatory after ssl_cacerts change)

1. Log into Hue → **Hive** editor
2. Left pane must list databases (not **No databases found**)
3. Run a simple query, e.g. `SHOW DATABASES;` or `SELECT 1;`

If login works but Hive fails with `NoneType` / `settimeout` / `id`:

- Re-check `ssl_cacerts` points to **`hue-trust-combined.pem`** on **both** hosts
- Confirm combined file contains Amdocs Internal CA (`grep -c BEGIN` ≥ 2)
- Rolling-restart **Hue Server** again after fixing the path

### 6.3 Confirm CM unchanged

```bash
# On cdhmng01 — fingerprint should match pre-change
keytool -list -v -keystore /etc/cloudera-scm-server/ssl/cm-ui.jks \
  -storepass changeit -alias cm-ui | grep SHA256
```

---

## 7. Rollback (Hue only)

1. Uncheck **Enable TLS/SSL for Hue** + Load Balancer TLS  
   **or** set `ssl_cacerts` back to `/etc/certificate/ra-admin-truststore.pem` if only Hive trust must be restored quickly
2. Restart Hue Servers (rolling)
3. Delete `/etc/cloudera/security/hue/` (optional)
4. `cm-ui.jks` never touched — no CM rollback needed

---

## 8. DNS (separate from cert)

VDI **DNS_FAIL** for cdhmng02 requires network/DNS fix — certificate deploy does not resolve that.

---

## 9. Troubleshooting (Hue TLS / Hive)

| Symptom | Cause | Fix |
|---------|-------|-----|
| Login OK; **No databases** / `NoneType`…`settimeout` | `ssl_cacerts` = A1 `root.pem` only | Use **`hue-trust-combined.pem`**; restart Hue Server |
| `ERR_SSL_PROTOCOL_ERROR` on `https://…:8889` | `ssl_enable` unchecked or LB still HTTP | Check **Enable TLS/SSL for Hue**; restart Hue Server + LB |
| Hue Server won't start; `REQUESTS_CA_BUNDLE does not exist` | Parent dir `750 root:root` | `chmod 755 /etc/cloudera /etc/cloudera/security` |
| Banner “non-optimized” on `:8888` | Direct Hue Server HTTP | Use `https://host:8889/hue/` |
| Query reaches Tez then Snappy fails | `/tmp` `noexec` (not Hue cert) | Set `-Djava.io.tmpdir=` to exec-capable path on YARN/Tez hosts |

---

## Checklist

- [ ] `cm-int-mng123.key` (or new `hue-int.key`) available
- [ ] `hue-fullchain.pem` built and verified (`openssl verify OK`)
- [ ] PEM deployed to cdhmng02 **and** cdhmng03
- [ ] Parent dirs `/etc/cloudera` + `/etc/cloudera/security` are `755`; `sudo -u hue test -r` OK
- [ ] **`hue-trust-combined.pem`** built = A1 `root.pem` + `ra-admin-truststore.pem` (Amdocs Internal CA)
- [ ] CM: **Enable TLS/SSL for Hue** checked
- [ ] CM: `ssl_certificate` / `ssl_private_key` = Hue PEMs
- [ ] CM: **`ssl_cacerts` = `hue-trust-combined.pem`** (not A1 `root.pem` alone)
- [ ] After restart: `hue.ini` shows all three ssl_* paths
- [ ] HTTPS on 8889 works
- [ ] **Hive editor lists databases** and can run a simple query
- [ ] `cm-ui.jks` on cdhmng01 **not modified**
- [ ] DNS for cdhmng02/03 from VDI (network ticket if needed)

---

## Document history

| Date | Change |
|------|--------|
| — | Initial INT Hue-only HTTPS (keep cm-ui.jks) |
| 2026-07-28 | Align `ssl_cacerts` with Hue→Hive: use `hue-trust-combined.pem` (A1 + Amdocs Internal CA); parent-dir perms; Hive validation; troubleshooting |

---

*Related: `CM_PROD_HUE_HTTPS_RUNBOOK.md` (same `ssl_cacerts` / combined-trust pattern)*
