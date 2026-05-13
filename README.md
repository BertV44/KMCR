# Kasten K10 — Morning Coffee Report ☕

Automated bash script that queries your K10 cluster and sends a styled HTML email report.

Tested on **K10 8.5.3** and **K10 8.5.8** on OpenShift and vanilla Kubernetes.

## What it collects

| Section | Source |
|---|---|
| Applications & compliance | `applications.apps.kio.kasten.io` CRs |
| License validity & expiry | `k10-license` secret (YAML decoded) |
| Consumption (nodes) | License secret + `oc get nodes` fallback |
| Policies (backup/import/system) | `policies.config.kio.kasten.io` CRs |
| Last policy run status & errors | `runactions.actions.kio.kasten.io` CRs |
| Daily action counts (3 days) | RunAction timestamps |
| Storage stats | `reports.reporting.kio.kasten.io` or PVCs |
| Services health | Deployment readiness in kasten-io namespace |

## CLI auto-detection

The script detects OpenShift automatically by probing `route.openshift.io` and `clusterversion`.

| Cluster type | Behaviour |
|---|---|
| OpenShift + `oc` installed | Uses `oc` |
| OpenShift + `oc` missing | **Exits with error** (install `oc`) |
| Vanilla K8s + `kubectl` | Uses `kubectl` |
| Vanilla K8s + only `oc` | Uses `oc` |

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
  "reportDate": "2026-05-13",
  "reportTime": "08:00 CET",
  "cluster": {
    "name": "...",
    "instanceId": "...",
    "kastenVersion": "8.5.8",
    "isOpenShift": true
  },
  "applications": { "total": 79, "compliant": 0, "nonCompliant": 0, "unmanaged": 79 },
  "policies": {
    "total": 3, "backup": 2, "import": 0, "system": 1, "failed": 0,
    "details": [...]
  },
  "storage": { "totalBackupData": "90.9 MiB", "snapshotSize": "0 B", "objectStorage": "91 MiB" },
  "license": {
    "customer": "...", "product": "K10", "expires": "...", "daysLeft": 358,
    "consumption": { "nodes": { "used": 3, "licensed": 10, "percent": 30 } }
  },
  "services": { "allHealthy": true, "details": [...] }
}
```

## Quick start

```bash
# OpenShift
oc project kasten-io

# Vanilla K8s
kubectl config use-context my-cluster

# Just generate the HTML/JSON locally
./kasten-morning-report.sh

# Send via SMTP — credentials in env (quick tests only)
MAIL_TO="team@example.com" \
SMTP_SERVER="smtp.gmail.com" \
SMTP_PORT=587 \
SMTP_TLS=true \
SMTP_USER="you@gmail.com" \
SMTP_PASS="app-password" \
./kasten-morning-report.sh

# Send via SMTP — password from file (recommended for cron / production)
echo -n "app-password" > /etc/kasten/smtp.pass
chmod 600 /etc/kasten/smtp.pass
MAIL_TO="team@example.com" \
SMTP_SERVER="smtp.gmail.com" SMTP_PORT=587 SMTP_TLS=true \
SMTP_USER="you@gmail.com" \
SMTP_PASS_FILE="/etc/kasten/smtp.pass" \
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
| `SMTP_USER` / `SMTP_PASS` | *(empty)* | Auth credentials (env var) |
| `SMTP_PASS_FILE` | *(empty)* | **Recommended:** path to a file containing the password (use `chmod 600`) |
| `SMTP_TLS` | `false` | Enable STARTTLS |
| `REPORT_DIR` | `/tmp/kasten-reports` | Where HTML/JSON files are saved |
| `RETENTION_DAYS` | `30` | Auto-delete old reports older than N days; `0` disables |

### Credentials handling

Three patterns, ordered by safety:

1. **`SMTP_PASS_FILE` pointing to a `chmod 600` file** — recommended. Password never appears in `ps`, history, or shell logs.
2. **`SMTP_PASS` env var** — acceptable for interactive testing. Visible in `/proc/$pid/environ` to anyone able to read it.
3. **CLI inline** (`SMTP_PASS=xxx ./script.sh`) — discouraged. Visible in shell history.

For production cron, use option 1. For Kubernetes deployment of this script, mount a Secret as file and point `SMTP_PASS_FILE` at the mount path.

## Cron schedule (daily at 8 AM)

```bash
0 8 * * * MAIL_TO="team@example.com" SMTP_PASS_FILE="/etc/kasten/smtp.pass" /opt/scripts/kasten-morning-report.sh >> /var/log/kasten-report.log 2>&1
```

## Multi-cluster

Run the script once per context:

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

## Alerts

The report applies color-coded alerts based on thresholds:

| Condition | Banner Color | Meaning |
|---|---|---|
| > 90 days remaining | Green | License valid |
| 31–90 days remaining | Orange | Plan renewal |
| ≤ 30 days remaining | Red | Expiring soon — action required |
| Past expiry date | Red | EXPIRED — renew immediately |
| Node usage ≥ 80% | Orange | Approaching limit |
| Node usage ≥ 95% | Red | Near or at capacity |
| Non-compliant apps > 0 OR failed policies > 0 | Red top banner | Action required |

The script tries multiple CRDs in order: `licenses.vault.kio.kasten.io` (K10 7.x+), `licenses.licensing.kio.kasten.io` (older), then falls back to the `k10-license` secret. Node count falls back to `oc get nodes` / `kubectl get nodes` if not in the license CR.

## Security & robustness notes

- **HTML escaping:** All cluster-derived strings (policy names, error messages, customer name, license ID, service names) are HTML-escaped before injection into the report.
- **SMTP heredoc:** The Python SMTP block uses a quoted heredoc and reads credentials/paths from `os.environ`, preventing shell injection through arbitrary input.
- **Run-action queries:** Run actions are fetched **once** per script run and reused for all per-policy/per-day filtering (O(1) API calls instead of O(N policies × 3 days)).
- **Retention:** Old reports are auto-deleted based on `RETENTION_DAYS` (default 30). Set to `0` to keep everything.

## Requirements

- `oc` (OpenShift) or `kubectl` — auto-detected, OCP detection forces `oc`
- `jq` for JSON parsing
- `python3` (for SMTP email) or `sendmail`/`mailx`
- Works on **macOS** (BSD) and **Linux** (GNU) — no `grep -P` or GNU-only date flags
