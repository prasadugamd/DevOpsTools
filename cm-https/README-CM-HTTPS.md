# CM HTTPS documentation pack

Stakeholder package for Cloudera Manager **A1 Silver HTTPS** (CM UI, agents, Queue Manager, Hue, Hue→Hive).

## Start here

| Audience | Read first |
|----------|------------|
| INT / PROD / PET multi-node ops | [`CM_MULTI_NODE_HTTPS_E2E_RUNBOOK.md`](CM_MULTI_NODE_HTTPS_E2E_RUNBOOK.md) |
| UAT / standalone | [`CM_STANDALONE_HTTPS_RUNBOOK.md`](CM_STANDALONE_HTTPS_RUNBOOK.md) (§15 for co-located Hue/QM) |
| CAB / checklist only | E2E runbook **§13 Master checklist** |

## Full set

| File | Purpose |
|------|---------|
| `CM_MULTI_NODE_HTTPS_E2E_RUNBOOK.md` | End-to-end multi-node (CM → QM → Hue → Hive) |
| `CM_STANDALONE_HTTPS_RUNBOOK.md` | Standalone CM + agents + §15 Hue/Hive |
| `CM_PROD_HTTPS_SAML_RUNBOOK.md` | PROD CM HTTPS + Ping SAML |
| `CM_PROD_HUE_HTTPS_RUNBOOK.md` | PROD Hue deep dive |
| `CM_INT_HUE_HTTPS_RUNBOOK.md` | INT Hue-only |
| `scripts/build_standalone_cm_keystores.sh` | UAT01–UAT06 JKS/PEM build |
| `SKILL.md` | Cursor / agent routing skill (mirrors Innoverse prompt) |
| `INNOVERSE_CM_HTTPS_AGENT_PROMPT.md` | System prompt to paste into Innoverse agent |

Repo layout: this pack lives under **`cm-https/`**. Jenkins TLS is under **`../jenkins-tls/`**.

## Critical rule (Hue → Hive)

`ssl_cacerts` = **`hue-trust-combined.pem`** (A1 root + `ra-admin-truststore.pem` / Amdocs Internal CA).  
**Never** set `ssl_cacerts` to A1 `root.pem` alone.

## Firehose

Keep Firehose on **`/etc/certificate/keystore-kafka.jks`** — never `cm-ui.jks`.
