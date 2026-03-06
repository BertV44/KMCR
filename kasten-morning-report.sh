#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  Kasten K10 — Morning Coffee Report
#  Gathers cluster data via kubectl/K10 API and sends an HTML email summary.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
# Adjust these variables or export them before running the script.

KASTEN_NAMESPACE="${KASTEN_NAMESPACE:-kasten-io}"
KASTEN_RELEASE="${KASTEN_RELEASE:-k10}"

# Email settings
MAIL_TO="${MAIL_TO:-}"                          # recipient(s), comma-separated
MAIL_FROM="${MAIL_FROM:-kasten-report@$(hostname -f 2>/dev/null || echo 'localhost')}"
MAIL_SUBJECT="${MAIL_SUBJECT:-}"                # auto-generated if empty
MAIL_METHOD="${MAIL_METHOD:-smtp}"              # smtp | sendmail | mailx | file
SMTP_SERVER="${SMTP_SERVER:-localhost}"
SMTP_PORT="${SMTP_PORT:-25}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
SMTP_TLS="${SMTP_TLS:-false}"                   # true for STARTTLS

# Output
REPORT_DIR="${REPORT_DIR:-/tmp/kasten-reports}"
SAVE_HTML="${SAVE_HTML:-true}"                   # always keep a local copy

# Cluster identifier (auto-detected if empty)
CLUSTER_NAME="${CLUSTER_NAME:-}"
INSTANCE_ID="${INSTANCE_ID:-}"

# ─── Date helpers ─────────────────────────────────────────────────────────────
TODAY=$(date +"%Y-%m-%d")
TODAY_PRETTY=$(date +"%A, %B %d, %Y")
TIME_NOW=$(date +"%H:%M %Z")
REPORT_FILE="${REPORT_DIR}/kasten-report-${TODAY}.html"

mkdir -p "${REPORT_DIR}"

# ─── Logging ──────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*" >&2; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
kubectl cluster-info >/dev/null 2>&1 || die "Cannot connect to Kubernetes cluster"

log "Starting Kasten K10 Morning Coffee Report collection..."

# ─── Auto-detect cluster name ─────────────────────────────────────────────────
if [[ -z "${CLUSTER_NAME}" ]]; then
    CLUSTER_NAME=$(kubectl config current-context 2>/dev/null || echo "unknown-cluster")
fi
if [[ -z "${INSTANCE_ID}" ]]; then
    INSTANCE_ID=$(kubectl get ns "${KASTEN_NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "N/A")
fi

log "Cluster: ${CLUSTER_NAME} | Namespace: ${KASTEN_NAMESPACE}"

# ═══════════════════════════════════════════════════════════════════════════════
#  DATA COLLECTION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Kasten version ───────────────────────────────────────────────────────────
get_kasten_version() {
    local version
    # Try from deployment image tag first
    version=$(kubectl get deploy -n "${KASTEN_NAMESPACE}" -l app="${KASTEN_RELEASE}" \
        -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null \
        | grep -oP ':\K[^@]+' || true)
    if [[ -z "${version}" ]]; then
        # Fallback: check any K10 deployment
        version=$(kubectl get deploy -n "${KASTEN_NAMESPACE}" \
            -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null \
            | grep -oP ':\K[^@]+' || echo "N/A")
    fi
    echo "${version}"
}

# ─── Applications ─────────────────────────────────────────────────────────────
get_applications() {
    # Fetch all K10 application CRs
    local apps_json
    apps_json=$(kubectl get apps.applications.kio.kasten.io -n "${KASTEN_NAMESPACE}" -o json 2>/dev/null || \
                kubectl get apps -n "${KASTEN_NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')

    TOTAL_APPS=$(echo "${apps_json}" | jq '.items | length' 2>/dev/null || echo "0")

    # If no CRs found, count namespaces as a proxy
    if [[ "${TOTAL_APPS}" == "0" ]]; then
        TOTAL_APPS=$(kubectl get ns --no-headers 2>/dev/null | wc -l | tr -d ' ')
    fi

    # Compliance from restorepoints
    COMPLIANT_APPS=$(echo "${apps_json}" | jq '[.items[] | select(.status.status=="compliant" or .status.status=="Compliant")] | length' 2>/dev/null || echo "0")
    NONCOMPLIANT_APPS=$(echo "${apps_json}" | jq '[.items[] | select(.status.status=="non-compliant" or .status.status=="NonCompliant")] | length' 2>/dev/null || echo "0")
    UNMANAGED_APPS=$(( TOTAL_APPS - COMPLIANT_APPS - NONCOMPLIANT_APPS ))
    [[ "${UNMANAGED_APPS}" -lt 0 ]] && UNMANAGED_APPS=0
}

# ─── Policies ─────────────────────────────────────────────────────────────────
get_policies() {
    local policies_json
    policies_json=$(kubectl get policies.config.kio.kasten.io -n "${KASTEN_NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')

    TOTAL_POLICIES=$(echo "${policies_json}" | jq '.items | length' 2>/dev/null || echo "0")
    BACKUP_POLICIES=$(echo "${policies_json}" | jq '[.items[] | select(.spec.actions[]?.action=="backup")] | length' 2>/dev/null || echo "0")
    IMPORT_POLICIES=$(echo "${policies_json}" | jq '[.items[] | select(.spec.actions[]?.action=="import")] | length' 2>/dev/null || echo "0")
    SYSTEM_POLICIES=$(echo "${policies_json}" | jq '[.items[] | select(.metadata.labels["k10.kasten.io/isSystemPolicy"]=="true")] | length' 2>/dev/null || echo "0")

    # Store policy names and details for the Last Policy Status section
    POLICY_NAMES=()
    POLICY_TYPES=()
    POLICY_STATUSES=()
    POLICY_LAST_RUN=()
    POLICY_DETAILS=()

    local count
    count=$(echo "${policies_json}" | jq '.items | length')
    for i in $(seq 0 $((count - 1))); do
        local name type_val
        name=$(echo "${policies_json}" | jq -r ".items[${i}].metadata.name")
        type_val=$(echo "${policies_json}" | jq -r "
            if .items[${i}].metadata.labels[\"k10.kasten.io/isSystemPolicy\"] == \"true\" then \"System\"
            elif (.items[${i}].spec.actions[]?.action // \"\" ) == \"import\" then \"Import\"
            else \"Backup\"
            end" 2>/dev/null || echo "Backup")

        POLICY_NAMES+=("${name}")
        POLICY_TYPES+=("${type_val}")

        # Get last run action for this policy
        local run_json last_status last_time action_count error_msg
        run_json=$(kubectl get runactions.actions.kio.kasten.io -n "${KASTEN_NAMESPACE}" \
            -l "k10.kasten.io/policyName=${name}" \
            --sort-by='.metadata.creationTimestamp' \
            -o json 2>/dev/null || echo '{"items":[]}')

        local run_count
        run_count=$(echo "${run_json}" | jq '.items | length')
        if [[ "${run_count}" -gt 0 ]]; then
            last_status=$(echo "${run_json}" | jq -r '.items[-1].status.state // "Unknown"')
            last_time=$(echo "${run_json}" | jq -r '.items[-1].status.endTime // .items[-1].metadata.creationTimestamp // "N/A"')
            action_count=$(echo "${run_json}" | jq -r '.items[-1].status.actions // 0')
            error_msg=$(echo "${run_json}" | jq -r '.items[-1].status.error // ""')

            # Normalize status
            case "${last_status,,}" in
                complete*|success*) last_status="Success" ;;
                fail*|error*)       last_status="Failed"  ;;
                running*)           last_status="Running" ;;
                *)                  last_status="Unknown" ;;
            esac

            # Format timestamp
            if [[ "${last_time}" != "N/A" ]]; then
                last_time=$(date -d "${last_time}" +"%b %d, %H:%M" 2>/dev/null || echo "${last_time}")
            fi

            local detail="${action_count} actions"
            [[ -n "${error_msg}" && "${error_msg}" != "null" ]] && detail="${error_msg}"

            POLICY_STATUSES+=("${last_status}")
            POLICY_LAST_RUN+=("${last_time}")
            POLICY_DETAILS+=("${detail}")
        else
            POLICY_STATUSES+=("No runs")
            POLICY_LAST_RUN+=("N/A")
            POLICY_DETAILS+=("No run actions found")
        fi
    done
}

# ─── Actions / Report data ────────────────────────────────────────────────────
get_report_actions() {
    # Fetch recent report actions (last 3 days)
    REPORT_ROWS=""
    for days_ago in 0 1 2; do
        local start_date end_date start_label end_label
        start_date=$(date -d "${TODAY} -$((days_ago + 1)) days" +"%Y-%m-%d" 2>/dev/null || \
                     date -v-$((days_ago + 1))d +"%Y-%m-%d" 2>/dev/null)
        end_date=$(date -d "${TODAY} -${days_ago} days" +"%Y-%m-%d" 2>/dev/null || \
                   date -v-${days_ago}d +"%Y-%m-%d" 2>/dev/null)
        start_label=$(date -d "${start_date}" +"%b %-d" 2>/dev/null || echo "${start_date}")
        end_label=$(date -d "${end_date}" +"%b %-d" 2>/dev/null || echo "${end_date}")

        # Count actions in the time window
        local actions_json total_actions error_actions
        actions_json=$(kubectl get runactions.actions.kio.kasten.io -n "${KASTEN_NAMESPACE}" \
            --sort-by='.metadata.creationTimestamp' -o json 2>/dev/null || echo '{"items":[]}')

        total_actions=$(echo "${actions_json}" | jq --arg s "${start_date}T00:00:00Z" --arg e "${end_date}T23:59:59Z" \
            '[.items[] | select(.metadata.creationTimestamp >= $s and .metadata.creationTimestamp <= $e)] | length' 2>/dev/null || echo "0")

        error_actions=$(echo "${actions_json}" | jq --arg s "${start_date}T00:00:00Z" --arg e "${end_date}T23:59:59Z" \
            '[.items[] | select(.metadata.creationTimestamp >= $s and .metadata.creationTimestamp <= $e) | select(.status.state=="Failed" or .status.state=="failed")] | length' 2>/dev/null || echo "0")

        local error_color="#27AE60"
        [[ "${error_actions}" -gt 0 ]] && error_color="#E74C3C"

        local row_bg=""
        [[ $((days_ago % 2)) -eq 1 ]] && row_bg=' style="background-color:#F7F9FC;"'

        REPORT_ROWS+="
        <tr${row_bg}>
            <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;font-weight:600;'>${start_label} – ${end_label}</td>
            <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;'>${total_actions}</td>
            <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;color:${error_color};font-weight:600;'>${error_actions}</td>
        </tr>"
    done
}

# ─── Storage ──────────────────────────────────────────────────────────────────
get_storage_info() {
    # Try to get storage stats from K10 catalog or PVCs
    SNAPSHOT_SIZE="N/A"
    OBJECT_STORAGE="N/A"
    TOTAL_BACKUP_DATA="N/A"

    # Attempt: get backup storage stats from K10 report CR
    local report_json
    report_json=$(kubectl get clusterreports.reporting.kio.kasten.io -n "${KASTEN_NAMESPACE}" \
        --sort-by='.metadata.creationTimestamp' -o json 2>/dev/null || echo '{"items":[]}')

    local report_count
    report_count=$(echo "${report_json}" | jq '.items | length')

    if [[ "${report_count}" -gt 0 ]]; then
        SNAPSHOT_SIZE=$(echo "${report_json}" | jq -r '.items[-1].status.stats.snapshotSize // "N/A"' 2>/dev/null)
        OBJECT_STORAGE=$(echo "${report_json}" | jq -r '.items[-1].status.stats.objectStorageSize // "N/A"' 2>/dev/null)
        TOTAL_BACKUP_DATA=$(echo "${report_json}" | jq -r '.items[-1].status.stats.totalBackupDataSize // "N/A"' 2>/dev/null)
    fi

    # Fallback: check PVC usage in kasten namespace
    if [[ "${TOTAL_BACKUP_DATA}" == "N/A" || "${TOTAL_BACKUP_DATA}" == "null" ]]; then
        TOTAL_BACKUP_DATA=$(kubectl get pvc -n "${KASTEN_NAMESPACE}" -o json 2>/dev/null \
            | jq -r '[.items[].status.capacity.storage // "0"] | join(", ")' 2>/dev/null || echo "N/A")
    fi
}

# ─── K10 Services health ─────────────────────────────────────────────────────
get_services_status() {
    SERVICE_NAMES=()
    SERVICE_STATUSES=()
    ALL_HEALTHY=true

    local deploys
    deploys=$(kubectl get deploy -n "${KASTEN_NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')

    local count
    count=$(echo "${deploys}" | jq '.items | length')

    for i in $(seq 0 $((count - 1))); do
        local name ready replicas
        name=$(echo "${deploys}" | jq -r ".items[${i}].metadata.name")
        ready=$(echo "${deploys}" | jq -r ".items[${i}].status.readyReplicas // 0")
        replicas=$(echo "${deploys}" | jq -r ".items[${i}].status.replicas // 0")

        SERVICE_NAMES+=("${name}")
        if [[ "${ready}" -ge "${replicas}" && "${replicas}" -gt 0 ]]; then
            SERVICE_STATUSES+=("Healthy")
        else
            SERVICE_STATUSES+=("Degraded")
            ALL_HEALTHY=false
        fi
    done
}

# ─── License & Consumption ────────────────────────────────────────────────────
get_license_info() {
    # Defaults
    LIC_TYPE="N/A"
    LIC_PLATFORM="N/A"
    LIC_ID="N/A"
    LIC_ISSUED="N/A"
    LIC_EXPIRES="N/A"
    LIC_DAYS_LEFT="N/A"
    LIC_STATUS="Unknown"
    LIC_STATUS_COLOR="#999999"
    LIC_FEATURES=""

    # Consumption defaults
    LIC_NODE_LICENSED="N/A"
    LIC_NODE_USED="N/A"
    LIC_NODE_PCT="0"
    LIC_APP_LICENSED="N/A"
    LIC_APP_USED="N/A"
    LIC_APP_PCT="0"

    # ── Method 1: K10 license CRD (Kasten 7.x+) ──
    local lic_json
    lic_json=$(kubectl get licenses.vault.kio.kasten.io -n "${KASTEN_NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')
    local lic_count
    lic_count=$(echo "${lic_json}" | jq '.items | length')

    if [[ "${lic_count}" -eq 0 ]]; then
        # Fallback: try older CRD name
        lic_json=$(kubectl get licenses.licensing.kio.kasten.io -n "${KASTEN_NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')
        lic_count=$(echo "${lic_json}" | jq '.items | length')
    fi

    if [[ "${lic_count}" -gt 0 ]]; then
        # Use the first (or most recent) license
        LIC_TYPE=$(echo "${lic_json}" | jq -r '.items[0].spec.type // .items[0].status.type // "N/A"')
        LIC_PLATFORM=$(echo "${lic_json}" | jq -r '.items[0].spec.platform // .items[0].status.platform // "N/A"')
        LIC_ID=$(echo "${lic_json}" | jq -r '.items[0].spec.id // .items[0].metadata.name // "N/A"')
        LIC_ISSUED=$(echo "${lic_json}" | jq -r '.items[0].spec.issuedAt // .items[0].metadata.creationTimestamp // "N/A"')
        LIC_EXPIRES=$(echo "${lic_json}" | jq -r '.items[0].spec.expiresAt // .items[0].status.expiresAt // .items[0].spec.expiration // "N/A"')

        # Features / edition
        LIC_FEATURES=$(echo "${lic_json}" | jq -r '
            [.items[0].spec.features // .items[0].status.features // [] | .[]?] | join(", ")' 2>/dev/null || echo "")

        # Node limits
        LIC_NODE_LICENSED=$(echo "${lic_json}" | jq -r '.items[0].spec.maxNodes // .items[0].spec.nodeLimit // .items[0].status.maxNodes // "Unlimited"')
        LIC_APP_LICENSED=$(echo "${lic_json}" | jq -r '.items[0].spec.maxApplications // .items[0].spec.applicationLimit // .items[0].status.maxApplications // "Unlimited"')

        # Consumption from status
        LIC_NODE_USED=$(echo "${lic_json}" | jq -r '.items[0].status.currentNodes // .items[0].status.nodeCount // "N/A"')
        LIC_APP_USED=$(echo "${lic_json}" | jq -r '.items[0].status.currentApplications // .items[0].status.applicationCount // "N/A"')
    fi

    # ── Method 2: K10 configmap / secret fallback ──
    if [[ "${LIC_EXPIRES}" == "N/A" || "${LIC_EXPIRES}" == "null" ]]; then
        local lic_cm
        lic_cm=$(kubectl get configmap -n "${KASTEN_NAMESPACE}" -l "app.kubernetes.io/name=k10" -o json 2>/dev/null || echo '{"items":[]}')
        local exp_from_cm
        exp_from_cm=$(echo "${lic_cm}" | jq -r '[.items[].data | to_entries[] | select(.key | test("license|expir"; "i")) | .value] | first // empty' 2>/dev/null || true)
        [[ -n "${exp_from_cm}" ]] && LIC_EXPIRES="${exp_from_cm}"
    fi

    # ── Method 3: Count nodes directly if not from license CR ──
    if [[ "${LIC_NODE_USED}" == "N/A" || "${LIC_NODE_USED}" == "null" ]]; then
        LIC_NODE_USED=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    fi

    # ── Method 4: Count managed apps if not from license CR ──
    if [[ "${LIC_APP_USED}" == "N/A" || "${LIC_APP_USED}" == "null" ]]; then
        LIC_APP_USED="${TOTAL_APPS}"
    fi

    # ── Calculate days remaining ──
    if [[ "${LIC_EXPIRES}" != "N/A" && "${LIC_EXPIRES}" != "null" && "${LIC_EXPIRES}" != "" ]]; then
        local exp_epoch now_epoch
        exp_epoch=$(date -d "${LIC_EXPIRES}" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "${LIC_EXPIRES}" +%s 2>/dev/null || echo "0")
        now_epoch=$(date +%s)

        if [[ "${exp_epoch}" -gt 0 ]]; then
            LIC_DAYS_LEFT=$(( (exp_epoch - now_epoch) / 86400 ))

            # Format expiration date nicely
            LIC_EXPIRES=$(date -d "${LIC_EXPIRES}" +"%b %d, %Y" 2>/dev/null || echo "${LIC_EXPIRES}")

            if [[ "${LIC_DAYS_LEFT}" -le 0 ]]; then
                LIC_STATUS="EXPIRED"
                LIC_STATUS_COLOR="#E74C3C"
            elif [[ "${LIC_DAYS_LEFT}" -le 30 ]]; then
                LIC_STATUS="Expiring Soon"
                LIC_STATUS_COLOR="#E74C3C"
            elif [[ "${LIC_DAYS_LEFT}" -le 90 ]]; then
                LIC_STATUS="Attention"
                LIC_STATUS_COLOR="#F39C12"
            else
                LIC_STATUS="Valid"
                LIC_STATUS_COLOR="#27AE60"
            fi
        fi
    fi

    # ── Format issued date ──
    if [[ "${LIC_ISSUED}" != "N/A" && "${LIC_ISSUED}" != "null" ]]; then
        LIC_ISSUED=$(date -d "${LIC_ISSUED}" +"%b %d, %Y" 2>/dev/null || echo "${LIC_ISSUED}")
    fi

    # ── Calculate consumption percentages ──
    if [[ "${LIC_NODE_LICENSED}" =~ ^[0-9]+$ && "${LIC_NODE_USED}" =~ ^[0-9]+$ && "${LIC_NODE_LICENSED}" -gt 0 ]]; then
        LIC_NODE_PCT=$(( LIC_NODE_USED * 100 / LIC_NODE_LICENSED ))
    fi
    if [[ "${LIC_APP_LICENSED}" =~ ^[0-9]+$ && "${LIC_APP_USED}" =~ ^[0-9]+$ && "${LIC_APP_LICENSED}" -gt 0 ]]; then
        LIC_APP_PCT=$(( LIC_APP_USED * 100 / LIC_APP_LICENSED ))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  COLLECT ALL DATA
# ═══════════════════════════════════════════════════════════════════════════════
log "Gathering Kasten version..."
KASTEN_VERSION=$(get_kasten_version)

log "Gathering application data..."
get_applications

log "Gathering policy data..."
get_policies

log "Gathering report/action data..."
get_report_actions

log "Gathering storage info..."
get_storage_info

log "Gathering services status..."
get_services_status

log "Gathering license & consumption data..."
get_license_info

log "Data collection complete. Building report..."

# ═══════════════════════════════════════════════════════════════════════════════
#  BUILD HTML REPORT
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Policy rows ──────────────────────────────────────────────────────────────
POLICY_TABLE_ROWS=""
POLICY_ERROR_ROWS=""
for i in "${!POLICY_NAMES[@]}"; do
    local status_color status_icon row_bg
    case "${POLICY_STATUSES[$i]}" in
        Success) status_color="#27AE60"; status_icon="&#10003;" ;;
        Failed)  status_color="#E74C3C"; status_icon="&#10007;" ;;
        Running) status_color="#F39C12"; status_icon="&#9881;"  ;;
        *)       status_color="#999999"; status_icon="&#8212;"  ;;
    esac

    row_bg=""
    [[ $((i % 2)) -eq 1 ]] && row_bg=' style="background-color:#F7F9FC;"'

    POLICY_TABLE_ROWS+="
    <tr${row_bg}>
        <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;font-weight:600;'>${POLICY_NAMES[$i]}</td>
        <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;'>${POLICY_TYPES[$i]}</td>
        <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;'>${POLICY_LAST_RUN[$i]}</td>
        <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;color:${status_color};font-weight:700;'>${status_icon} ${POLICY_STATUSES[$i]}</td>
        <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;'>${POLICY_DETAILS[$i]}</td>
    </tr>"

    # Collect errors
    if [[ "${POLICY_STATUSES[$i]}" == "Failed" ]]; then
        POLICY_ERROR_ROWS+="
        <tr>
            <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;font-weight:600;'>${POLICY_NAMES[$i]}</td>
            <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;color:#E74C3C;'>${POLICY_DETAILS[$i]}</td>
        </tr>"
    fi
done

# ─── Service rows ─────────────────────────────────────────────────────────────
SERVICE_TABLE_ROWS=""
for i in "${!SERVICE_NAMES[@]}"; do
    local svc_color svc_icon row_bg
    if [[ "${SERVICE_STATUSES[$i]}" == "Healthy" ]]; then
        svc_color="#27AE60"; svc_icon="&#10003;"
    else
        svc_color="#E74C3C"; svc_icon="&#10007;"
    fi
    row_bg=""
    [[ $((i % 2)) -eq 1 ]] && row_bg=' style="background-color:#F7F9FC;"'

    SERVICE_TABLE_ROWS+="
    <tr${row_bg}>
        <td style='padding:8px 14px;border-bottom:1px solid #E8E8E8;'>${SERVICE_NAMES[$i]}</td>
        <td style='padding:8px 14px;border-bottom:1px solid #E8E8E8;text-align:center;color:${svc_color};font-weight:700;'>${svc_icon} ${SERVICE_STATUSES[$i]}</td>
    </tr>"
done

# ─── Overall health banner ────────────────────────────────────────────────────
if ${ALL_HEALTHY}; then
    HEALTH_BANNER="<div style='background:#27AE60;color:#fff;padding:12px 20px;border-radius:6px;font-weight:700;font-size:15px;margin-bottom:16px;'>&#10003; All services are operational</div>"
else
    HEALTH_BANNER="<div style='background:#E74C3C;color:#fff;padding:12px 20px;border-radius:6px;font-weight:700;font-size:15px;margin-bottom:16px;'>&#10007; Some services are degraded — review below</div>"
fi

# ─── Compliance colors ────────────────────────────────────────────────────────
NONCOMPLIANT_COLOR="#27AE60"
[[ "${NONCOMPLIANT_APPS}" -gt 0 ]] && NONCOMPLIANT_COLOR="#E74C3C"

# ─── License banner ──────────────────────────────────────────────────────────
LIC_BANNER_BG="${LIC_STATUS_COLOR}"
LIC_BANNER_ICON="&#10003;"
LIC_BANNER_TEXT="License valid — ${LIC_DAYS_LEFT} days remaining"

case "${LIC_STATUS}" in
    EXPIRED)
        LIC_BANNER_ICON="&#10007;"
        LIC_BANNER_TEXT="LICENSE EXPIRED — Renew immediately"
        ;;
    "Expiring Soon")
        LIC_BANNER_ICON="&#9888;"
        LIC_BANNER_TEXT="License expiring in ${LIC_DAYS_LEFT} days — Action required"
        ;;
    Attention)
        LIC_BANNER_ICON="&#9888;"
        LIC_BANNER_TEXT="License expires in ${LIC_DAYS_LEFT} days — Plan renewal"
        ;;
    Unknown)
        LIC_BANNER_ICON="&#8212;"
        LIC_BANNER_TEXT="License status could not be determined"
        LIC_BANNER_BG="#999999"
        ;;
esac

LICENSE_BANNER="<div style='background:${LIC_BANNER_BG};color:#fff;padding:12px 20px;border-radius:6px;font-weight:700;font-size:14px;margin-bottom:16px;'>${LIC_BANNER_ICON} ${LIC_BANNER_TEXT}</div>"

# ─── Consumption progress bar helper ─────────────────────────────────────────
# Usage: build_progress_bar <used> <licensed> <percent> <label>
build_progress_bar() {
    local used="$1" licensed="$2" pct="$3" label="$4"
    local bar_color="#27AE60"
    [[ "${pct}" -ge 80 ]] && bar_color="#F39C12"
    [[ "${pct}" -ge 95 ]] && bar_color="#E74C3C"

    # Cap at 100% for display
    local display_pct="${pct}"
    [[ "${display_pct}" -gt 100 ]] && display_pct=100

    cat <<BARHTML
    <div style="margin-bottom:14px;">
        <div style="display:flex;justify-content:space-between;margin-bottom:4px;">
            <span style="font-size:12px;font-weight:600;color:#333;">${label}</span>
            <span style="font-size:12px;color:#666;">${used} / ${licensed} <span style="color:${bar_color};font-weight:700;">(${pct}%)</span></span>
        </div>
        <div style="background:#E8E8E8;border-radius:6px;height:10px;overflow:hidden;">
            <div style="background:${bar_color};width:${display_pct}%;height:100%;border-radius:6px;"></div>
        </div>
    </div>
BARHTML
}

# Build the bars
NODE_BAR=""
APP_BAR=""
if [[ "${LIC_NODE_LICENSED}" =~ ^[0-9]+$ ]]; then
    NODE_BAR=$(build_progress_bar "${LIC_NODE_USED}" "${LIC_NODE_LICENSED}" "${LIC_NODE_PCT}" "Nodes")
else
    NODE_BAR=$(cat <<BARHTML
    <div style="margin-bottom:14px;">
        <div style="display:flex;justify-content:space-between;margin-bottom:4px;">
            <span style="font-size:12px;font-weight:600;color:#333;">Nodes</span>
            <span style="font-size:12px;color:#666;">${LIC_NODE_USED} used &bull; Unlimited</span>
        </div>
        <div style="background:#E8E8E8;border-radius:6px;height:10px;overflow:hidden;">
            <div style="background:#27AE60;width:100%;height:100%;border-radius:6px;opacity:0.3;"></div>
        </div>
    </div>
BARHTML
)
fi

if [[ "${LIC_APP_LICENSED}" =~ ^[0-9]+$ ]]; then
    APP_BAR=$(build_progress_bar "${LIC_APP_USED}" "${LIC_APP_LICENSED}" "${LIC_APP_PCT}" "Applications")
else
    APP_BAR=$(cat <<BARHTML
    <div style="margin-bottom:14px;">
        <div style="display:flex;justify-content:space-between;margin-bottom:4px;">
            <span style="font-size:12px;font-weight:600;color:#333;">Applications</span>
            <span style="font-size:12px;color:#666;">${LIC_APP_USED} used &bull; Unlimited</span>
        </div>
        <div style="background:#E8E8E8;border-radius:6px;height:10px;overflow:hidden;">
            <div style="background:#27AE60;width:100%;height:100%;border-radius:6px;opacity:0.3;"></div>
        </div>
    </div>
BARHTML
)
fi

# ─── Assemble full HTML ──────────────────────────────────────────────────────
cat > "${REPORT_FILE}" <<HTMLEOF
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>
<body style="margin:0;padding:0;background:#F4F5F7;font-family:Arial,Helvetica,sans-serif;color:#333;">
<div style="max-width:720px;margin:20px auto;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,0.08);">

<!-- ─── Header ─────────────────────────────────── -->
<div style="background:linear-gradient(135deg,#1B2A4A,#2E75B6);padding:30px 32px;">
    <h1 style="margin:0 0 4px;color:#fff;font-size:24px;">&#9749; Morning Coffee Report</h1>
    <p style="margin:0;color:rgba(255,255,255,0.75);font-size:13px;">
        ${TODAY_PRETTY} &nbsp;|&nbsp; ${TIME_NOW} &nbsp;|&nbsp; Kasten ${KASTEN_VERSION}
    </p>
    <p style="margin:8px 0 0;color:rgba(255,255,255,0.6);font-size:12px;">
        Cluster: <strong style="color:#fff;">${CLUSTER_NAME}</strong> &nbsp;&bull;&nbsp;
        Instance: <strong style="color:#fff;">${INSTANCE_ID}</strong>
    </p>
</div>

<div style="padding:24px 32px;">

<!-- ─── 1. Cluster Overview KPIs ───────────────── -->
<h2 style="margin:0 0 16px;font-size:17px;color:#1B2A4A;border-bottom:3px solid #2E75B6;padding-bottom:8px;">1. Cluster Overview</h2>

<table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:8px;">
<tr>
    <td style="width:33%;padding:0 6px 0 0;vertical-align:top;">
        <div style="border-top:3px solid #27AE60;background:#F7F9FC;border-radius:0 0 6px 6px;padding:16px;">
            <div style="font-size:11px;color:#888;text-transform:uppercase;letter-spacing:0.5px;">Applications</div>
            <div style="font-size:30px;font-weight:700;color:#1A1A2E;margin:4px 0;">${TOTAL_APPS}</div>
            <div style="font-size:11px;color:#666;">${COMPLIANT_APPS} compliant &bull; <span style="color:${NONCOMPLIANT_COLOR};">${NONCOMPLIANT_APPS} non-compliant</span> &bull; ${UNMANAGED_APPS} unmanaged</div>
        </div>
    </td>
    <td style="width:33%;padding:0 3px;vertical-align:top;">
        <div style="border-top:3px solid #2E75B6;background:#F7F9FC;border-radius:0 0 6px 6px;padding:16px;">
            <div style="font-size:11px;color:#888;text-transform:uppercase;letter-spacing:0.5px;">Policies</div>
            <div style="font-size:30px;font-weight:700;color:#1A1A2E;margin:4px 0;">${TOTAL_POLICIES}</div>
            <div style="font-size:11px;color:#666;">${BACKUP_POLICIES} backup &bull; ${IMPORT_POLICIES} import &bull; ${SYSTEM_POLICIES} system</div>
        </div>
    </td>
    <td style="width:33%;padding:0 0 0 6px;vertical-align:top;">
        <div style="border-top:3px solid #F39C12;background:#F7F9FC;border-radius:0 0 6px 6px;padding:16px;">
            <div style="font-size:11px;color:#888;text-transform:uppercase;letter-spacing:0.5px;">Backup Data</div>
            <div style="font-size:30px;font-weight:700;color:#1A1A2E;margin:4px 0;">${TOTAL_BACKUP_DATA}</div>
            <div style="font-size:11px;color:#666;">Snap: ${SNAPSHOT_SIZE} &bull; Object: ${OBJECT_STORAGE}</div>
        </div>
    </td>
</tr>
</table>

<!-- ─── 2. License & Consumption ────────────────── -->
<h2 style="margin:24px 0 16px;font-size:17px;color:#1B2A4A;border-bottom:3px solid #2E75B6;padding-bottom:8px;">2. License &amp; Consumption</h2>

${LICENSE_BANNER}

<table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:16px;">
<tr>
    <td style="width:50%;padding:0 8px 0 0;vertical-align:top;">
        <div style="background:#F7F9FC;border-radius:6px;padding:16px;border:1px solid #E8E8E8;">
            <div style="font-size:11px;color:#888;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:10px;">License Details</div>
            <table cellpadding="0" cellspacing="0" style="font-size:12px;width:100%;">
                <tr><td style="padding:3px 0;color:#888;width:90px;">Type</td><td style="padding:3px 0;font-weight:600;">${LIC_TYPE}</td></tr>
                <tr><td style="padding:3px 0;color:#888;">Platform</td><td style="padding:3px 0;font-weight:600;">${LIC_PLATFORM}</td></tr>
                <tr><td style="padding:3px 0;color:#888;">License ID</td><td style="padding:3px 0;font-weight:600;font-size:11px;word-break:break-all;">${LIC_ID}</td></tr>
                <tr><td style="padding:3px 0;color:#888;">Issued</td><td style="padding:3px 0;">${LIC_ISSUED}</td></tr>
                <tr><td style="padding:3px 0;color:#888;">Expires</td><td style="padding:3px 0;font-weight:700;color:${LIC_STATUS_COLOR};">${LIC_EXPIRES}</td></tr>
                <tr><td style="padding:3px 0;color:#888;">Days Left</td><td style="padding:3px 0;font-weight:700;color:${LIC_STATUS_COLOR};">${LIC_DAYS_LEFT}</td></tr>
            </table>
        </div>
    </td>
    <td style="width:50%;padding:0 0 0 8px;vertical-align:top;">
        <div style="background:#F7F9FC;border-radius:6px;padding:16px;border:1px solid #E8E8E8;">
            <div style="font-size:11px;color:#888;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:10px;">Consumption</div>
            ${NODE_BAR}
            ${APP_BAR}
            <div style="font-size:11px;color:#AAA;margin-top:8px;border-top:1px solid #E8E8E8;padding-top:8px;">
                $(if [[ -n "${LIC_FEATURES}" && "${LIC_FEATURES}" != "null" ]]; then
                    echo "Features: <span style='color:#666;'>${LIC_FEATURES}</span>"
                else
                    echo "Feature details not available from license CR"
                fi)
            </div>
        </div>
    </td>
</tr>
</table>

<!-- ─── 3. Daily Reports ───────────────────────── -->
<h2 style="margin:24px 0 16px;font-size:17px;color:#1B2A4A;border-bottom:3px solid #2E75B6;padding-bottom:8px;">3. Daily Reports (Last 3 Days)</h2>

<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px;">
<thead>
<tr style="background:#1B2A4A;">
    <th style="padding:10px 14px;color:#fff;text-align:left;font-weight:600;">Date Range</th>
    <th style="padding:10px 14px;color:#fff;text-align:center;font-weight:600;">Total Actions</th>
    <th style="padding:10px 14px;color:#fff;text-align:center;font-weight:600;">Errors</th>
</tr>
</thead>
<tbody>${REPORT_ROWS}</tbody>
</table>

<!-- ─── 4. Last Policy Status ──────────────────── -->
<h2 style="margin:24px 0 16px;font-size:17px;color:#1B2A4A;border-bottom:3px solid #2E75B6;padding-bottom:8px;">4. Last Policy Run Status</h2>

<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px;">
<thead>
<tr style="background:#1B2A4A;">
    <th style="padding:10px 14px;color:#fff;text-align:left;font-weight:600;">Policy</th>
    <th style="padding:10px 14px;color:#fff;text-align:center;font-weight:600;">Type</th>
    <th style="padding:10px 14px;color:#fff;text-align:center;font-weight:600;">Last Run</th>
    <th style="padding:10px 14px;color:#fff;text-align:center;font-weight:600;">Status</th>
    <th style="padding:10px 14px;color:#fff;text-align:left;font-weight:600;">Details</th>
</tr>
</thead>
<tbody>${POLICY_TABLE_ROWS}</tbody>
</table>

$(if [[ -n "${POLICY_ERROR_ROWS}" ]]; then
cat <<ERRTBL
<h3 style="margin:16px 0 10px;font-size:14px;color:#E74C3C;">&#9888; Policy Errors</h3>
<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px;border:1px solid #F5C6CB;border-radius:4px;">
<thead>
<tr style="background:#FDECEA;">
    <th style="padding:10px 14px;color:#E74C3C;text-align:left;font-weight:600;">Policy</th>
    <th style="padding:10px 14px;color:#E74C3C;text-align:left;font-weight:600;">Error</th>
</tr>
</thead>
<tbody>${POLICY_ERROR_ROWS}</tbody>
</table>
ERRTBL
fi)

<!-- ─── 5. Services Status ─────────────────────── -->
<h2 style="margin:24px 0 16px;font-size:17px;color:#1B2A4A;border-bottom:3px solid #2E75B6;padding-bottom:8px;">5. Services Status</h2>

${HEALTH_BANNER}

<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px;">
<thead>
<tr style="background:#1B2A4A;">
    <th style="padding:8px 14px;color:#fff;text-align:left;font-weight:600;">Service</th>
    <th style="padding:8px 14px;color:#fff;text-align:center;font-weight:600;">Status</th>
</tr>
</thead>
<tbody>${SERVICE_TABLE_ROWS}</tbody>
</table>

<!-- ─── Footer ─────────────────────────────────── -->
<div style="margin-top:32px;padding-top:16px;border-top:1px solid #E8E8E8;font-size:11px;color:#AAA;text-align:center;">
    Generated on ${TODAY_PRETTY} at ${TIME_NOW} &bull; Kasten K10 ${KASTEN_VERSION} &bull; ${CLUSTER_NAME}
</div>

</div>
</div>
</body>
</html>
HTMLEOF

log "HTML report saved to: ${REPORT_FILE}"

# ═══════════════════════════════════════════════════════════════════════════════
#  EMAIL DELIVERY
# ═══════════════════════════════════════════════════════════════════════════════

[[ -z "${MAIL_SUBJECT}" ]] && MAIL_SUBJECT="[Kasten] ☕ Morning Report — ${CLUSTER_NAME} — ${TODAY}"

send_email() {
    if [[ -z "${MAIL_TO}" ]]; then
        warn "MAIL_TO is not set — skipping email delivery. Report saved to: ${REPORT_FILE}"
        return 0
    fi

    log "Sending report to: ${MAIL_TO} (method: ${MAIL_METHOD})"

    case "${MAIL_METHOD}" in

        smtp)
            # Use Python for portable SMTP support (TLS, auth, HTML)
            python3 - <<PYEOF
import smtplib, sys
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

with open("${REPORT_FILE}", "r") as f:
    html_body = f.read()

msg = MIMEMultipart("alternative")
msg["Subject"] = """${MAIL_SUBJECT}"""
msg["From"]    = "${MAIL_FROM}"
msg["To"]      = "${MAIL_TO}"

plain = "This is an HTML email report. Please view in an HTML-capable client."
msg.attach(MIMEText(plain, "plain"))
msg.attach(MIMEText(html_body, "html"))

try:
    server = smtplib.SMTP("${SMTP_SERVER}", ${SMTP_PORT}, timeout=30)
    server.ehlo()
    if "${SMTP_TLS}" == "true":
        server.starttls()
        server.ehlo()
    if "${SMTP_USER}":
        server.login("${SMTP_USER}", "${SMTP_PASS}")
    server.sendmail("${MAIL_FROM}", "${MAIL_TO}".split(","), msg.as_string())
    server.quit()
    print("Email sent successfully.")
except Exception as e:
    print(f"ERROR sending email: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
            ;;

        sendmail)
            {
                echo "From: ${MAIL_FROM}"
                echo "To: ${MAIL_TO}"
                echo "Subject: ${MAIL_SUBJECT}"
                echo "MIME-Version: 1.0"
                echo "Content-Type: text/html; charset=utf-8"
                echo ""
                cat "${REPORT_FILE}"
            } | sendmail -t
            ;;

        mailx)
            mailx -a "Content-Type: text/html; charset=utf-8" \
                  -s "${MAIL_SUBJECT}" \
                  "${MAIL_TO}" < "${REPORT_FILE}"
            ;;

        file)
            log "MAIL_METHOD=file — report saved to ${REPORT_FILE} (no email sent)"
            ;;

        *)
            warn "Unknown MAIL_METHOD '${MAIL_METHOD}'. Report saved to: ${REPORT_FILE}"
            ;;
    esac
}

send_email

# ═══════════════════════════════════════════════════════════════════════════════
#  DONE
# ═══════════════════════════════════════════════════════════════════════════════
log "Morning Coffee Report complete! ☕"
log "Report: ${REPORT_FILE}"
echo ""
echo "Tip: Schedule with cron for daily delivery:"
echo "  0 8 * * * /path/to/kasten-morning-report.sh"
echo ""
