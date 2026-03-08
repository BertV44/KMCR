# Kasten K10 — Morning Coffee Report ☕

Automated bash script that queries your K10 cluster and sends a styled HTML email report.

## What it collects

| Section | Source |
|---|---|
| Applications & compliance | `applications.apps.kio.kasten.io` CRs |
| License validity & expiry | `k10-license` secret (YAML decoded) |
| Consumption (nodes & apps) | License secret + `oc get nodes` fallback |
| Policies (backup/import/system) | `policies.config.kio.kasten.io` CRs |
| Last policy run status & errors | `runactions.actions.kio.kasten.io` CRs |
| Daily action counts (3 days) | RunAction timestamps |
| Storage stats | `reports.reporting.kio.kasten.io` or PVCs |
| Services health | Deployment readiness in kasten-io namespace |

## Output files

Each run produces two files in `REPORT_DIR` (default `/tmp/kasten-reports`):

| File | Purpose |
|---|---|
| `kasten-report-YYYY-MM-DD.html` | Styled visual report |
| `kasten-report-YYYY-MM-DD.json` | Structured data for automation/dashboards |

When sending email, the HTML is the **email body** and the JSON is **attached** as a file.

### JSON structure

```json
{
  "reportDate": "2026-03-08",
  "reportTime": "08:00 CET",
  "cluster": { "name": "...", "instanceId": "...", "kastenVersion": "8.5.3" },
  "applications": { "total": 79, "compliant": 0, "nonCompliant": 0, "unmanaged": 79 },
  "policies": { "total": 3, "backup": 2, "import": 0, "system": 1, "details": [...] },
  "storage": { "totalBackupData": "90.9 MiB", "snapshotSize": "0 B", "objectStorage": "91 MiB" },
  "license": { "customer": "...", "product": "K10", "expires": "...", "daysLeft": 26962,
               "consumption": { "nodes": { "used": 3, "licensed": 10, "percent": 30 }, ... } },
  "services": { "allHealthy": true, "details": [...] }
}
```

## Quick start

```bash
# Switch to kasten-io project (OpenShift)
oc project kasten-io

# Minimal — just generate the HTML file locally
./kasten-morning-report.sh

# Send via SMTP
MAIL_TO="team@example.com" \
SMTP_SERVER="smtp.gmail.com" \
SMTP_PORT=587 \
SMTP_TLS=true \
SMTP_USER="you@gmail.com" \
SMTP_PASS="app-password" \
./kasten-morning-report.sh

# Send via sendmail
MAIL_TO="team@example.com" MAIL_METHOD=sendmail ./kasten-morning-report.sh

# Send via mailx
MAIL_TO="team@example.com" MAIL_METHOD=mailx ./kasten-morning-report.sh
```

## Configuration (env vars)

| Variable | Default | Description |
|---|---|---|
| `KASTEN_NAMESPACE` | `kasten-io` | K10 install namespace |
| `CLUSTER_NAME` | auto-detected | Friendly cluster name |
| `MAIL_TO` | *(empty — no email)* | Recipient(s), comma-separated |
| `MAIL_FROM` | `kasten-report@hostname` | Sender address |
| `MAIL_METHOD` | `smtp` | `smtp`, `sendmail`, `mailx`, or `file` |
| `SMTP_SERVER` | `localhost` | SMTP relay host |
| `SMTP_PORT` | `25` | SMTP port |
| `SMTP_USER` / `SMTP_PASS` | *(empty)* | Auth credentials |
| `SMTP_TLS` | `false` | Enable STARTTLS |
| `REPORT_DIR` | `/tmp/kasten-reports` | Where HTML files are saved |

## Cron schedule (daily at 8 AM)

```bash
0 8 * * * MAIL_TO="team@example.com" SMTP_SERVER="..." /opt/scripts/kasten-morning-report.sh >> /var/log/kasten-report.log 2>&1
```

## Multi-cluster

Run the script once per context/project:

```bash
# OpenShift
for ctx in cluster-prod cluster-staging cluster-dev; do
    oc login "$ctx" --token=...
    oc project kasten-io
    CLUSTER_NAME="$ctx" MAIL_TO="team@example.com" ./kasten-morning-report.sh
done

# Vanilla K8s
for ctx in cluster-prod cluster-staging cluster-dev; do
    kubectl config use-context "$ctx"
    CLUSTER_NAME="$ctx" MAIL_TO="team@example.com" ./kasten-morning-report.sh
done
```

## License & consumption alerts

The report applies color-coded alerts based on thresholds:

| Condition | Banner Color | Meaning |
|---|---|---|
| > 90 days remaining | Green | License valid |
| 31–90 days remaining | Orange | Plan renewal |
| ≤ 30 days remaining | Red | Expiring soon — action required |
| Past expiry date | Red | EXPIRED — renew immediately |
| Node/App usage ≥ 80% | Orange | Approaching limit |
| Node/App usage ≥ 95% | Red | Near or at capacity |

The script tries multiple CRDs in order: `licenses.vault.kio.kasten.io` (K10 7.x+), `licenses.licensing.kio.kasten.io` (older), then falls back to configmaps. Node count falls back to `kubectl get nodes` if not in the license CR.

## Requirements

- `oc` (OpenShift) or `kubectl` — auto-detected, `oc` preferred
- `jq` for JSON parsing
- `python3` (for SMTP email) or `sendmail`/`mailx`
- Works on **macOS** (BSD) and **Linux** (GNU) — no `grep -P` or GNU-only date flags
