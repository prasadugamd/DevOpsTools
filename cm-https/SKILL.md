---
name: cm-https-runbooks
description: >-
  Routes Cloudera Manager A1 HTTPS work to the correct runbook (standalone vs
  multi-node) and enforces Hue→Hive ssl_cacerts combined-trust rules. Use when
  the user mentions CM HTTPS, cm-ui.jks, Hue TLS, Hue Load Balancer, ssl_cacerts,
  hue-trust-combined, Queue Manager TLS, agent verify_cert_dir, INT/PROD/PET/UAT
  Cloudera TLS, or Firehose keystore vs cm-ui.jks.
---

# CM HTTPS Runbooks

## Instructions

1. **Read the matching runbook before inventing steps.** Do not invent agent greenfield install; these docs cover TLS cutover on existing clusters.
2. **Pick the doc** using the table below, then follow it. Prefer quoting paths and CM UI labels from the runbook.
3. **Enforce hard rules** in every Hue / agent / Firehose answer (see below).

## Which document to use

| Scenario | Primary document |
|----------|------------------|
| Standalone / single CM node / UAT01–UAT06 | `CM_STANDALONE_HTTPS_RUNBOOK.md` (Hue/QM co-located → **§15**) |
| Multi-node INT / PROD / PET (cdhmng01 + Hue on 02/03) | `CM_MULTI_NODE_HTTPS_E2E_RUNBOOK.md` |
| PROD CM + Ping SAML detail | `CM_PROD_HTTPS_SAML_RUNBOOK.md` |
| INT Hue-only (keep existing `cm-ui.jks`) | `CM_INT_HUE_HTTPS_RUNBOOK.md` |
| PROD Hue deep dive | `CM_PROD_HUE_HTTPS_RUNBOOK.md` |
| UAT JKS build script | `scripts/build_standalone_cm_keystores.sh` |

**Paths:** In DevOpsTools, files live under `cm-https/` (this folder). In the `CDH_CM` Cursor workspace, the same filenames are at the workspace root (skill at `.cursor/skills/cm-https-runbooks/`).

## Hard rules (never violate)

| Topic | Rule |
|-------|------|
| Hue `ssl_cacerts` | Use **`hue-trust-combined.pem`** = A1 `root.pem` + `/etc/certificate/ra-admin-truststore.pem` (Amdocs Internal CA). **Never** A1 `root.pem` alone. |
| Hue Enable TLS | `ssl_enable` must be **checked**; cert paths alone do nothing. |
| Hue files | Owner **`hue:hue`**; PEMs `644`; key `600`; parent `/etc/cloudera` + `/etc/cloudera/security` = `755`. |
| Hue URL | Users use `https://<host>:8889/hue/` — not `http://…:8888`. |
| Firehose | Keep **`/etc/certificate/keystore-kafka.jks`** — never `cm-ui.jks`. |
| Agents (TLS cutover) | `verify_cert_dir=/opt/cloudera/security/CAcerts` **and** uncommented `client_*` (`keystore-kafka.key/.pem`, `agentkey.pw`). |
| CM UI TLS | Admin → Settings → TLS must point to `cm-ui.jks` / `cm-ui-trust.jks` (overrides properties). |
| Queue Manager | Reuses **`cm-ui.jks`** when on CM host; not Hue PEMs. |
| New agent install | Out of scope — these runbooks reconfigure existing agents only. |

## Symptom → likely fix

| Symptom | Fix pointer |
|---------|-------------|
| Login OK; Hive No databases / `NoneType`…`settimeout` | Combined `ssl_cacerts`; restart Hue Server |
| `ERR_SSL_PROTOCOL_ERROR` on `:8889` | Enable TLS + LB; use `https://` |
| `REQUESTS_CA_BUNDLE does not exist` | Parent dir `755`; `sudo -u hue test -r` |
| `sslv3 alert bad certificate` (agents) | Uncomment `client_*` + A1 in CAcerts |
| 7183 shows `CN=username` | Admin TLS still on `keystore-kafka.jks` |
| Tez Snappy / `/tmp` noexec | Not Hue cert — `java.io.tmpdir` on YARN/Tez |

## Response style

- Name the runbook and section you are following.
- Give env-specific hostnames only after clarifying INT / PROD / PET / UAT.
- Prefer rolling restart for Hue on multi-node; stale-config-only when applicable.
- For full E2E order on multi-node: CM+agents → Queue Manager → Hue PEMs → Hue→Hive trust → validate.

## Examples

**User:** "Enable Hue HTTPS on PROD and fix Hive."  
→ Open `CM_MULTI_NODE_HTTPS_E2E_RUNBOOK.md` (Phases 4–5) or `CM_PROD_HUE_HTTPS_RUNBOOK.md`; set `ssl_cacerts` to `hue-trust-combined.pem`.

**User:** "UAT-05 CM HTTPS agents."  
→ Open `CM_STANDALONE_HTTPS_RUNBOOK.md` §8; use `build_standalone_cm_keystores.sh --uat 05` if building JKS.

**User:** "Create a new CM agent on a blank host."  
→ Say runbooks are TLS cutover only; point to Cloudera Add Host / existing client-cert process — do not invent from HTTPS docs alone.
