# Kasten K10 — Morning Coffee Report ☕

Automated bash script that queries your K10 cluster and sends a styled HTML email report.

## What it collects

| Section | Source |
|---|---|
| Applications & compliance | `apps.applications.kio.kasten.io` CRs |
| License validity & expiry | `licenses.vault.kio.kasten.io` / `licenses.licensing.kio.kasten.io` CRs |
| Consumption (nodes & apps) | License CR status + `kubectl get nodes` fallback |
| Policies (backup/import/system) | `policies.config.kio.kasten.io` CRs |
| Last policy run status & errors | `runactions.actions.kio.kasten.io` CRs |
| Daily action counts (3 days) | RunAction timestamps |
| Storage stats | `clusterreports.reporting.kio.kasten.io` or PVCs |
| Services health | Deployment readiness in kasten-io namespace |

## Quick start

```bash
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

Run the script once per kubeconfig context:

```bash
for ctx in cluster-prod cluster-staging cluster-dev; do
    KUBECONFIG=~/.kube/config \
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

- `kubectl` with access to the target cluster
- `jq` for JSON parsing
- `python3` (for SMTP email) or `sendmail`/`mailx`
