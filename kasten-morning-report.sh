#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  Kasten K10 — Morning Coffee Report
#  Gathers cluster data via oc/kubectl + K10 API and sends an HTML email.
#  Compatible: macOS (BSD bash 3.2+) + Linux, OpenShift (oc) + vanilla K8s
#
#  CHANGELOG (review 2026-05):
#    - OpenShift auto-detection (route.openshift.io + clusterversion probe).
#      If OCP cluster detected but 'oc' missing → exit error.
#    - SMTP heredoc hardened: quoted heredoc + os.environ (no shell injection).
#    - HTML escaping for all cluster-derived strings (policy names, errors,
#      customer name, license ID, service names).
#    - Single get for runactions in get_report_actions and get_policies
#      (was N+1 per policy / x3 per day).
#    - Normalized status matching (handles 'failed', 'error*', 'fail*').
#    - Robust import-policy detection via jq `any()`.
#    - Image tag extraction strips @sha256 before splitting on ':'.
#    - Dead app-license code removed (K10 licences nodes, not apps).
#    - Non-compliance + failed-policy alert banner added above overview.
#    - SMTP_PASS_FILE support (file with 0600 perms recommended).
#    - Optional retention cleanup (RETENTION_DAYS, default 30, set to 0 to disable).
# ═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
KASTEN_NAMESPACE="${KASTEN_NAMESPACE:-kasten-io}"
KASTEN_RELEASE="${KASTEN_RELEASE:-k10}"

MAIL_TO="${MAIL_TO:-}"
MAIL_FROM="${MAIL_FROM:-kasten-report@$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo 'localhost')}"
MAIL_SUBJECT="${MAIL_SUBJECT:-}"
MAIL_METHOD="${MAIL_METHOD:-smtp}"
SMTP_SERVER="${SMTP_SERVER:-localhost}"
SMTP_PORT="${SMTP_PORT:-25}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
SMTP_PASS_FILE="${SMTP_PASS_FILE:-}"
SMTP_TLS="${SMTP_TLS:-false}"

REPORT_DIR="${REPORT_DIR:-/tmp/kasten-reports}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
INSTANCE_ID="${INSTANCE_ID:-}"

# Resolve SMTP_PASS from file if SMTP_PASS_FILE is set
if [[ -n "${SMTP_PASS_FILE}" && -r "${SMTP_PASS_FILE}" ]]; then
    SMTP_PASS="$(cat "${SMTP_PASS_FILE}")"
fi

# ─── CLI selection: OpenShift-aware ───────────────────────────────────────────
detect_cli() {
    local has_oc=false has_kubectl=false
    command -v oc      >/dev/null 2>&1 && has_oc=true
    command -v kubectl >/dev/null 2>&1 && has_kubectl=true

    if ! ${has_oc} && ! ${has_kubectl}; then
        echo "ERROR: Neither 'oc' nor 'kubectl' found in PATH" >&2; exit 1
    fi

    # Probe with whichever CLI is available (oc preferred for the probe)
    local probe="kubectl"
    ${has_oc} && probe="oc"

    IS_OPENSHIFT=false
    if ${probe} api-resources --api-group=route.openshift.io >/dev/null 2>&1 \
       && ${probe} get clusterversion >/dev/null 2>&1; then
        IS_OPENSHIFT=true
    fi

    if ${IS_OPENSHIFT}; then
        if ! ${has_oc}; then
            echo "ERROR: OpenShift cluster detected but 'oc' is not installed." >&2
            echo "       Install 'oc' from https://access.redhat.com/downloads/content/290" >&2
            exit 1
        fi
        K="oc"
    else
        if ${has_kubectl}; then
            K="kubectl"
        else
            K="oc"
        fi
    fi
}

detect_cli

# ─── Portable helpers (macOS BSD + Linux GNU) ─────────────────────────────────
portable_date_fmt() {
    local input="$1" fmt="$2"
    date -d "${input}" +"${fmt}" 2>/dev/null \
        || date -jf "%Y-%m-%dT%H:%M:%SZ" "${input}" +"${fmt}" 2>/dev/null \
        || date -jf "%Y-%m-%dT%H:%M:%S%z" "${input}" +"${fmt}" 2>/dev/null \
        || date -jf "%Y-%m-%d" "${input}" +"${fmt}" 2>/dev/null \
        || echo "${input}"
}

portable_date_epoch() {
    local input="$1"
    date -d "${input}" +%s 2>/dev/null \
        || date -jf "%Y-%m-%dT%H:%M:%SZ" "${input}" +%s 2>/dev/null \
        || date -jf "%Y-%m-%dT%H:%M:%S%z" "${input}" +%s 2>/dev/null \
        || date -jf "%Y-%m-%d" "${input}" +%s 2>/dev/null \
        || echo "0"
}

date_ago_days() {
    local n="$1"
    date -d "${TODAY} -${n} days" +"%Y-%m-%d" 2>/dev/null \
        || date -v-${n}d +"%Y-%m-%d" 2>/dev/null \
        || echo "${TODAY}"
}

date_short_label() {
    local d="$1" result
    result=$(date -d "${d}" +"%b %-d" 2>/dev/null \
        || date -jf "%Y-%m-%d" "${d}" +"%b %e" 2>/dev/null \
        || echo "${d}")
    echo "${result}" | sed 's/  */ /g'
}

# Bash 3.2 safe lowercase
to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# HTML escaping for any cluster-derived string before injection into the HTML
html_escape() {
    local s="${1:-}"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&#39;}"
    printf '%s' "${s}"
}

# ─── Date constants ───────────────────────────────────────────────────────────
TODAY=$(date +"%Y-%m-%d")
TODAY_PRETTY=$(date +"%A, %B %d, %Y")
TIME_NOW=$(date +"%H:%M %Z")
REPORT_FILE="${REPORT_DIR}/kasten-report-${TODAY}.html"
JSON_FILE="${REPORT_DIR}/kasten-report-${TODAY}.json"

mkdir -p "${REPORT_DIR}"

# ─── Logging ──────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*" >&2; }

# ─── Pre-flight ───────────────────────────────────────────────────────────────
if ! ${K} cluster-info >/dev/null 2>&1 && ! ${K} whoami >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to cluster via ${K}" >&2; exit 1
fi

log "Starting Kasten K10 Morning Coffee Report collection..."
log "CLI: ${K} | OpenShift detected: ${IS_OPENSHIFT}"

if [[ -z "${CLUSTER_NAME}" ]]; then
    CLUSTER_NAME=$(${K} config current-context 2>/dev/null || echo "unknown-cluster")
fi
if [[ -z "${INSTANCE_ID}" ]]; then
    INSTANCE_ID=$(${K} get ns "${KASTEN_NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "N/A")
fi

log "Cluster: ${CLUSTER_NAME} | Namespace: ${KASTEN_NAMESPACE}"

# ═══════════════════════════════════════════════════════════════════════════════
#  DATA COLLECTION
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Kasten version (from deployment label, not image tag) ────────────────────
get_kasten_version() {
    local version
    version=$(${K} get deploy -n "${KASTEN_NAMESPACE}" -l app="${KASTEN_RELEASE}" \
        -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true)

    if [[ -z "${version}" ]]; then
        version=$(${K} get deploy -n "${KASTEN_NAMESPACE}" -l app="${KASTEN_RELEASE}" \
            -o jsonpath='{.items[0].metadata.labels.helm\.sh/chart}' 2>/dev/null \
            | sed 's/^k10-//' || true)
    fi

    if [[ -z "${version}" ]]; then
        # Last resort: image tag. Strip @sha256 digest before splitting on ':'
        local img
        img=$(${K} get deploy -n "${KASTEN_NAMESPACE}" -l app="${KASTEN_RELEASE}" \
            -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)
        if [[ -n "${img}" ]]; then
            img="${img%@sha256:*}"   # remove digest suffix if present
            if echo "${img}" | grep -q ':'; then
                version=$(echo "${img}" | sed 's/.*://')
            fi
        fi
    fi

    echo "${version:-N/A}"
}

# ─── Applications ─────────────────────────────────────────────────────────────
get_applications() {
    local apps_json
    apps_json=$(${K} get applications.apps.kio.kasten.io --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')

    TOTAL_APPS=$(echo "${apps_json}" | jq '.items | length' 2>/dev/null || echo "0")

    if [[ "${TOTAL_APPS}" == "0" ]]; then
        TOTAL_APPS=$(${K} get ns --no-headers 2>/dev/null | wc -l | tr -d ' ')
    fi

    COMPLIANT_APPS=$(echo "${apps_json}" | jq '[.items[] | select(.status.status=="compliant" or .status.status=="Compliant")] | length' 2>/dev/null || echo "0")
    NONCOMPLIANT_APPS=$(echo "${apps_json}" | jq '[.items[] | select(.status.status=="non-compliant" or .status.status=="NonCompliant")] | length' 2>/dev/null || echo "0")
    UNMANAGED_APPS=$(( TOTAL_APPS - COMPLIANT_APPS - NONCOMPLIANT_APPS ))
    if [[ "${UNMANAGED_APPS}" -lt 0 ]]; then
        UNMANAGED_APPS=0
    fi
}

# ─── Shared jq helpers for K10 action errors ──────────────────────────────────
# K10 stores .status.error as a deeply nested object whose `cause` is itself a
# JSON-encoded string. Dumping it verbatim produced unreadable multi-KB blobs in
# the report. Single-quoted so jq's own $-variables are NOT expanded by bash.
#   deepmsg  -> the deepest human-readable `message` (prefers a brace-free leaf,
#               i.e. a clean sentence over an embedded-JSON string).
#   errappns -> the appNamespace buried in the error's `fields`, since policy-run
#               action CRs live in the K10 namespace, not the app namespace (#15).
JQ_ERR_HELPERS='
def deepmsg:
  . as $e
  | if $e == null then ""
    elif ($e|type) == "string" then $e
    elif ($e|type) == "object" then
      ( ($e.cause // null) | (if type == "string" then (try fromjson catch null) else . end) ) as $c
      | [ ($c // {}) | .. | objects | (.message? // empty) | select(type == "string" and (.|length > 0)) ] as $all
      | ( [ $all[] | select(test("[{}]") | not) ] ) as $clean
      | ( ($clean | last) // ($all | last) // $e.message // "" )
    else "" end;
def errappns:
  if (type == "object") then
    ( (.cause // null) | (if type == "string" then (try fromjson catch null) else . end) ) as $c
    | ( [ ($c // {}) | .. | objects | select(.name? == "appNamespace") | .value ] | last )
  else null end;
'

# ─── Run actions: single fetch, reused everywhere ─────────────────────────────
# Cached JSON of all runactions cluster-wide, sorted by creation timestamp.
# On K10 8.x, policy-driven action CRs are created in the source application
# namespace, NOT the K10 namespace. Fetching with `-n $KASTEN_NAMESPACE` made
# per-policy last-run status read "No runs" and under-counted failed policies on
# clusters with real failures. Fetch cluster-wide (-A); the policyName label
# filter downstream is namespace-agnostic. (Mirrors Kasten-Disco-Lite #15.)
RUNACTIONS_JSON=""
load_runactions() {
    RUNACTIONS_JSON=$(${K} get runactions.actions.kio.kasten.io -A \
        --sort-by='.metadata.creationTimestamp' -o json 2>/dev/null || echo '{"items":[]}')
}

# ─── K10 reports: single fetch, reused by storage + daily stats + license ─────
REPORTS_JSON=""
load_reports() {
    REPORTS_JSON=$(${K} get reports.reporting.kio.kasten.io -n "${KASTEN_NAMESPACE}" \
        --sort-by='.metadata.creationTimestamp' -o json 2>/dev/null || echo '{"items":[]}')
}

# ─── Export actions: single fetch for top-failed-exports table ────────────────
# Cluster-wide (-A): exportaction CRs live in the source application namespace,
# not the K10 namespace, so a namespace-scoped fetch made "Top failed/skipped
# exports" show empty despite real failures. (Mirrors Kasten-Disco-Lite #15.)
EXPORTACTIONS_JSON=""
load_exportactions() {
    EXPORTACTIONS_JSON=$(${K} get exportactions.actions.kio.kasten.io -A \
        -o json 2>/dev/null || echo '{"items":[]}')
}

# ─── Humanize a byte count to TiB/GiB/MiB/KiB/B ────────────────────────────────
humanize_bytes() {
    local b="${1:-0}"
    if ! [[ "${b}" =~ ^[0-9]+$ ]] || [[ "${b}" -eq 0 ]]; then
        echo "0 B"; return
    fi
    # LC_ALL=C forces a '.' decimal separator. Without it, fr_FR locales render
    # "85,4 MiB" (comma), breaking display and JSON numeric expectations (KDL 214ae61).
    if   [[ "${b}" -ge 1099511627776 ]]; then LC_ALL=C awk -v n="${b}" 'BEGIN{printf "%.1f TiB", n/1099511627776}'
    elif [[ "${b}" -ge 1073741824    ]]; then LC_ALL=C awk -v n="${b}" 'BEGIN{printf "%.1f GiB", n/1073741824}'
    elif [[ "${b}" -ge 1048576       ]]; then LC_ALL=C awk -v n="${b}" 'BEGIN{printf "%.1f MiB", n/1048576}'
    elif [[ "${b}" -ge 1024          ]]; then LC_ALL=C awk -v n="${b}" 'BEGIN{printf "%.1f KiB", n/1024}'
    else                                      echo "${b} B"
    fi
}

# ─── Policies ─────────────────────────────────────────────────────────────────
get_policies() {
    local policies_json
    policies_json=$(${K} get policies.config.kio.kasten.io -n "${KASTEN_NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')

    TOTAL_POLICIES=$(echo "${policies_json}" | jq '.items | length' 2>/dev/null || echo "0")
    BACKUP_POLICIES=$(echo "${policies_json}" | jq '[.items[] | select(any(.spec.actions[]?; .action == "backup"))] | length' 2>/dev/null || echo "0")
    IMPORT_POLICIES=$(echo "${policies_json}" | jq '[.items[] | select(any(.spec.actions[]?; .action == "import"))] | length' 2>/dev/null || echo "0")
    SYSTEM_POLICIES=$(echo "${policies_json}" | jq '[.items[] | select(.metadata.labels["k10.kasten.io/isSystemPolicy"]=="true")] | length' 2>/dev/null || echo "0")

    POLICY_NAMES=()
    POLICY_TYPES=()
    POLICY_STATUSES=()
    POLICY_LAST_RUN=()
    POLICY_DETAILS=()

    local count
    count=$(echo "${policies_json}" | jq '.items | length')

    local i
    for i in $(seq 0 $((count - 1))); do
        local name type_val
        name=$(echo "${policies_json}" | jq -r ".items[${i}].metadata.name")
        type_val=$(echo "${policies_json}" | jq -r "
            if .items[${i}].metadata.labels[\"k10.kasten.io/isSystemPolicy\"] == \"true\" then \"System\"
            elif any(.items[${i}].spec.actions[]?; .action == \"import\") then \"Import\"
            else \"Backup\"
            end" 2>/dev/null || echo "Backup")

        POLICY_NAMES+=("${name}")
        POLICY_TYPES+=("${type_val}")

        # Filter the cached runactions for this policy (no extra API call)
        local run_json last_status last_time action_count error_msg run_count
        run_json=$(echo "${RUNACTIONS_JSON}" | jq --arg p "${name}" \
            '{items: [.items[] | select(.metadata.labels["k10.kasten.io/policyName"] == $p)]}' 2>/dev/null \
            || echo '{"items":[]}')

        run_count=$(echo "${run_json}" | jq '.items | length')
        if [[ "${run_count}" -gt 0 ]]; then
            last_status=$(echo "${run_json}" | jq -r '.items[-1].status.state // "Unknown"')
            last_time=$(echo "${run_json}" | jq -r '.items[-1].status.endTime // .items[-1].metadata.creationTimestamp // "N/A"')
            action_count=$(echo "${run_json}" | jq -r '.items[-1].status.actions // 0')
            error_msg=$(echo "${run_json}" | jq -r "${JQ_ERR_HELPERS}"'.items[-1].status.error | deepmsg')

            local lower_status
            lower_status=$(to_lower "${last_status}")
            case "${lower_status}" in
                complete*|success*) last_status="Success" ;;
                fail*|error*)       last_status="Failed"  ;;
                running*)           last_status="Running" ;;
                *)                  last_status="Unknown" ;;
            esac

            if [[ "${last_time}" != "N/A" ]]; then
                last_time=$(portable_date_fmt "${last_time}" "%b %d, %H:%M")
            fi

            local detail="${action_count} actions"
            if [[ -n "${error_msg}" && "${error_msg}" != "null" ]]; then
                detail="${error_msg}"
            fi

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

# ─── Daily action stats (last 3 K10 scheduled reports) ───────────────────────
# Source: results.actions.countStats from reports.reporting.kio.kasten.io
# This is the AUTHORITATIVE source: K10 itself counts backup/export/import/
# restore/run separately, by completed/failed/cancelled/skipped.

# Render one cell of action stats. Input: "completed failed skipped cancelled"
render_action_cell() {
    local c f s cn
    read -r c f s cn <<<"$1"
    local total=$(( c + f + s + cn ))
    if [[ "${total}" -eq 0 ]]; then
        printf '<span style="color:#BBB;">&mdash;</span>'
        return
    fi
    local parts=""
    if [[ "${c}" -gt 0 ]]; then
        parts="<span style='color:#27AE60;font-weight:600;'>${c}&nbsp;&#10003;</span>"
    fi
    if [[ "${f}" -gt 0 ]]; then
        [[ -n "${parts}" ]] && parts="${parts}&nbsp;"
        parts="${parts}<span style='color:#E74C3C;font-weight:700;'>${f}&nbsp;&#10007;</span>"
    fi
    if [[ "${s}" -gt 0 ]]; then
        [[ -n "${parts}" ]] && parts="${parts}&nbsp;"
        parts="${parts}<span style='color:#F39C12;'>${s}&nbsp;skip</span>"
    fi
    if [[ "${cn}" -gt 0 ]]; then
        [[ -n "${parts}" ]] && parts="${parts}&nbsp;"
        parts="${parts}<span style='color:#888;'>${cn}&nbsp;cnl</span>"
    fi
    printf '%s' "${parts}"
}

# v3.1 fix (bug #2): countStats has 8 keys in K10 8.5.x (backup, backupCluster,
# export, import, report, restore, restoreCluster, run) — the previous 5-key
# hardcoded set silently dropped backupCluster/restoreCluster/report failures.
# This version iterates dynamically (forward-compatible) and groups results
# into 4 business categories + Run separately (excluded from total errors).
#   Backup  = backup + backupCluster
#   Restore = restore + restoreCluster
#   Export  = export
#   Autres  = import + report (+ any unknown future key)
#   Run     = run (separate row, NOT counted in total errors)
get_daily_action_stats() {
    REPORT_ROWS=""
    DAILY_FAILED_TOTAL=0
    DAILY_STATS_JSON="[]"

    local reports_subset count
    reports_subset=$(echo "${REPORTS_JSON}" | jq '
        [.items[] | select(.metadata.generateName? | tostring | startswith("scheduled-"))]
        | sort_by(.metadata.creationTimestamp) | reverse | .[0:3]
    ')
    count=$(echo "${reports_subset}" | jq 'length')

    if [[ "${count}" -eq 0 ]]; then
        REPORT_ROWS="<tr><td colspan='6' style='padding:12px;text-align:center;color:#888;font-style:italic;'>No scheduled K10 reports found</td></tr>"
        return
    fi

    # Build grouped stats in a single jq pass — covers any new key K10 might add.
    DAILY_STATS_JSON=$(echo "${reports_subset}" | jq '
        def group_of(k):
            if   k == "backup"  or k == "backupCluster"  then "Backup"
            elif k == "restore" or k == "restoreCluster" then "Restore"
            elif k == "export"                           then "Export"
            elif k == "run"                              then "Run"
            else                                              "Autres"
            end;
        def zero: {completed:0, failed:0, skipped:0, cancelled:0};
        [ .[] |
          (.results.actions.countStats // {}) as $cs |
          {
            date: (.spec.statsIntervalEndTimestamp // .spec.reportTimestamp // .metadata.creationTimestamp),
            grouped: (
              reduce ($cs | to_entries[]) as $e (
                { "Backup": zero, "Restore": zero, "Export": zero, "Autres": zero, "Run": zero };
                .[group_of($e.key)] |= {
                  completed: (.completed + ($e.value.completed // 0)),
                  failed:    (.failed    + ($e.value.failed    // 0)),
                  skipped:   (.skipped   + ($e.value.skipped   // 0)),
                  cancelled: (.cancelled + ($e.value.cancelled // 0))
                }
              )
            ),
            raw: $cs
          }
        ]
    ' 2>/dev/null || echo '[]')

    # Aggregated failed count for top alert banner — Run EXCLUDED to avoid
    # double-counting (a RunAction wraps backup/export sub-actions already counted).
    DAILY_FAILED_TOTAL=$(echo "${DAILY_STATS_JSON}" | jq '
        [ .[].grouped | (.Backup.failed + .Restore.failed + .Export.failed + .Autres.failed) ]
        | add // 0
    ')

    local i
    for i in $(seq 0 $((count - 1))); do
        local row report_date date_label row_bg
        row=$(echo "${DAILY_STATS_JSON}" | jq ".[${i}]")
        report_date=$(echo "${row}" | jq -r '.date // ""')
        date_label=$(portable_date_fmt "${report_date}" "%b %d")

        local backup_stats restore_stats export_stats autres_stats run_stats
        backup_stats=$( echo "${row}" | jq -r '.grouped.Backup  | "\(.completed) \(.failed) \(.skipped) \(.cancelled)"')
        restore_stats=$(echo "${row}" | jq -r '.grouped.Restore | "\(.completed) \(.failed) \(.skipped) \(.cancelled)"')
        export_stats=$( echo "${row}" | jq -r '.grouped.Export  | "\(.completed) \(.failed) \(.skipped) \(.cancelled)"')
        autres_stats=$( echo "${row}" | jq -r '.grouped.Autres  | "\(.completed) \(.failed) \(.skipped) \(.cancelled)"')
        run_stats=$(    echo "${row}" | jq -r '.grouped.Run     | "\(.completed) \(.failed) \(.skipped) \(.cancelled)"')

        row_bg=""
        if [[ $((i % 2)) -eq 1 ]]; then row_bg=' style="background-color:#F7F9FC;"'; fi

        REPORT_ROWS+="
        <tr${row_bg}>
            <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;font-weight:600;'>${date_label}</td>
            <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;'>$(render_action_cell "${backup_stats}")</td>
            <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;'>$(render_action_cell "${restore_stats}")</td>
            <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;'>$(render_action_cell "${export_stats}")</td>
            <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;'>$(render_action_cell "${autres_stats}")</td>
            <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;color:#888;'>$(render_action_cell "${run_stats}")</td>
        </tr>"
    done
}

# ─── Top failed/skipped exports (last 5) ──────────────────────────────────────
# Source: exportactions.actions.kio.kasten.io
# Labels:  k10.kasten.io/policyName, /policyNamespace, /actionSkipReason
# App namespace: extracted from status.exceptions[].fields[].value (subject JSON)
get_failed_exports() {
    FAILED_EXPORT_ROWS=""
    FAILED_EXPORT_COUNT=0

    local failed_json count
    # Filter Failed + Skipped, sort by endTime desc, top 5
    failed_json=$(echo "${EXPORTACTIONS_JSON}" | jq "${JQ_ERR_HELPERS}"'
        [.items[]
         | select(.status.state == "Failed" or .status.state == "Skipped")
         | {
             name:         .metadata.name,
             state:        .status.state,
             endTime:      (.status.endTime // .metadata.creationTimestamp),
             policyName:   (.metadata.labels["k10.kasten.io/policyName"]      // "—"),
             policyNs:     (.metadata.labels["k10.kasten.io/policyNamespace"] // "—"),
             skipReason:   (.metadata.labels["k10.kasten.io/actionSkipReason"] // ""),
             # Deepest human-readable cause, not the raw nested-JSON error object.
             errorMsg:     ((.status.error // .status.exceptions[0].message) | deepmsg),
             appNs: (
               # Try label first (some K10 versions populate it)
               .metadata.labels["k10.kasten.io/appNamespace"] //
               # Else parse the "subject" field from exceptions
               (try ((.status.exceptions // [])
                     | map(.fields // []) | flatten
                     | map(select(.name == "subject")) | .[0].value
                     | fromjson | .app.namespace.name) catch null) //
               # Else the appNamespace field buried in the error cause chain
               (.status.error | errappns) //
               # Else the namespace of the CR itself (cluster-wide fetch, #15)
               .metadata.namespace //
               "—"
             )
           }
        ]
        | sort_by(.endTime) | reverse | .[0:5]
    ' 2>/dev/null || echo '[]')

    count=$(echo "${failed_json}" | jq 'length')
    FAILED_EXPORT_COUNT="${count}"

    if [[ "${count}" -eq 0 ]]; then
        return
    fi

    local i
    for i in $(seq 0 $((count - 1))); do
        local entry name state endt policy policy_ns skip_reason error_msg app_ns
        entry=$(echo "${failed_json}" | jq ".[${i}]")
        name=$(echo       "${entry}" | jq -r '.name')
        state=$(echo      "${entry}" | jq -r '.state')
        endt=$(echo       "${entry}" | jq -r '.endTime')
        policy=$(echo     "${entry}" | jq -r '.policyName')
        policy_ns=$(echo  "${entry}" | jq -r '.policyNs')
        skip_reason=$(echo "${entry}" | jq -r '.skipReason')
        error_msg=$(echo  "${entry}" | jq -r '.errorMsg')
        app_ns=$(echo     "${entry}" | jq -r '.appNs')

        # Reason: for Skipped use skipReason label; for Failed use error_msg
        local reason=""
        if [[ "${state}" == "Skipped" && -n "${skip_reason}" && "${skip_reason}" != "null" ]]; then
            reason="${skip_reason}"
        elif [[ -n "${error_msg}" && "${error_msg}" != "null" ]]; then
            reason="${error_msg}"
        else
            reason="—"
        fi

        # Truncate very long reasons (keep email readable)
        if [[ ${#reason} -gt 120 ]]; then
            reason="${reason:0:117}..."
        fi

        local endt_pretty
        endt_pretty=$(portable_date_fmt "${endt}" "%b %d, %H:%M")

        local state_color="#E74C3C" state_icon="&#10007;"
        if [[ "${state}" == "Skipped" ]]; then
            state_color="#F39C12"; state_icon="&#9888;"
        fi

        local row_bg=""
        if [[ $((i % 2)) -eq 1 ]]; then row_bg=' style="background-color:#F7F9FC;"'; fi

        local h_policy h_policy_ns h_app_ns h_reason h_endt
        h_policy=$(html_escape    "${policy}")
        h_policy_ns=$(html_escape "${policy_ns}")
        h_app_ns=$(html_escape    "${app_ns}")
        h_reason=$(html_escape    "${reason}")
        h_endt=$(html_escape      "${endt_pretty}")

        FAILED_EXPORT_ROWS+="
        <tr${row_bg}>
            <td style='padding:8px 12px;border-bottom:1px solid #E8E8E8;text-align:center;color:${state_color};font-weight:700;'>${state_icon} ${state}</td>
            <td style='padding:8px 12px;border-bottom:1px solid #E8E8E8;'>${h_endt}</td>
            <td style='padding:8px 12px;border-bottom:1px solid #E8E8E8;font-weight:600;'>${h_policy}</td>
            <td style='padding:8px 12px;border-bottom:1px solid #E8E8E8;color:#666;'>${h_app_ns}</td>
            <td style='padding:8px 12px;border-bottom:1px solid #E8E8E8;color:#555;font-size:12px;'>${h_reason}</td>
        </tr>"
    done
}

# ─── Storage & Report Data ────────────────────────────────────────────────────
# Reads from REPORTS_JSON cache (loaded by load_reports).
# Schema (K10 8.5.x):
#   results.storage.objectStorage.{physicalBytes, logicalBytes, count}
#   results.storage.snapshotStorage.{physicalBytes, logicalBytes, count}
#   results.storage.pvcStats.{pvcBytes, pvcCount}
#   results.compliance.{applicationCount, compliantCount, nonCompliantCount, unmanagedCount}
#   results.general.k10Version
#   results.licensing.{nodeCount, nodeLimit, expiry, status, type}
get_storage_info() {
    SNAPSHOT_SIZE="N/A"
    OBJECT_STORAGE="N/A"
    TOTAL_BACKUP_DATA="N/A"

    REPORT_COMPLIANCE_APPS=""
    REPORT_COMPLIANCE_COMPLIANT=""
    REPORT_COMPLIANCE_NONCOMPLIANT=""
    REPORT_COMPLIANCE_UNMANAGED=""
    REPORT_K10_VERSION=""

    # License fields from report (used by get_license_info if available)
    REPORT_LIC_NODE_COUNT=""
    REPORT_LIC_NODE_LIMIT=""
    REPORT_LIC_EXPIRY=""
    REPORT_LIC_STATUS=""
    REPORT_LIC_TYPE=""

    local report_count
    report_count=$(echo "${REPORTS_JSON}" | jq '.items | length')

    if [[ "${report_count}" -gt 0 ]]; then
        local last_report
        last_report=$(echo "${REPORTS_JSON}" | jq '.items[-1]')

        # ── Storage (K10 8.5.x schema) ──
        local obj_phys snap_phys
        obj_phys=$(echo "${last_report}"  | jq -r '.results.storage.objectStorage.physicalBytes   // 0' 2>/dev/null || echo "0")
        snap_phys=$(echo "${last_report}" | jq -r '.results.storage.snapshotStorage.physicalBytes // 0' 2>/dev/null || echo "0")

        if [[ "${obj_phys}" =~ ^[0-9]+$ ]];  then OBJECT_STORAGE=$(humanize_bytes "${obj_phys}");  fi
        if [[ "${snap_phys}" =~ ^[0-9]+$ ]]; then SNAPSHOT_SIZE=$(humanize_bytes "${snap_phys}");  fi

        # Total = object storage physical + snapshot physical
        if [[ "${obj_phys}" =~ ^[0-9]+$ && "${snap_phys}" =~ ^[0-9]+$ ]]; then
            TOTAL_BACKUP_DATA=$(humanize_bytes $(( obj_phys + snap_phys )))
        fi

        # ── Older schema fallback (in case fields above are absent) ──
        if [[ "${TOTAL_BACKUP_DATA}" == "N/A" || "${TOTAL_BACKUP_DATA}" == "0 B" ]]; then
            local legacy
            legacy=$(echo "${last_report}" | jq -r '
                (.results.storage.totalBackupData //
                 .results.storage.totalSize //
                 .results.dataUsage.totalBackupData //
                 .results.dataUsage.total //
                 null)
            ' 2>/dev/null || true)
            if [[ -n "${legacy}" && "${legacy}" != "null" ]]; then
                TOTAL_BACKUP_DATA="${legacy}"
            fi
        fi

        # Compliance from report (authoritative)
        REPORT_COMPLIANCE_APPS=$(echo         "${last_report}" | jq -r '.results.compliance.applicationCount // empty' 2>/dev/null || true)
        REPORT_COMPLIANCE_COMPLIANT=$(echo    "${last_report}" | jq -r '.results.compliance.compliantCount    // empty' 2>/dev/null || true)
        REPORT_COMPLIANCE_NONCOMPLIANT=$(echo "${last_report}" | jq -r '.results.compliance.nonCompliantCount // empty' 2>/dev/null || true)
        REPORT_COMPLIANCE_UNMANAGED=$(echo    "${last_report}" | jq -r '.results.compliance.unmanagedCount    // empty' 2>/dev/null || true)
        REPORT_K10_VERSION=$(echo             "${last_report}" | jq -r '.results.general.k10Version           // empty' 2>/dev/null || true)

        # License fields (used by get_license_info)
        REPORT_LIC_NODE_COUNT=$(echo "${last_report}" | jq -r '.results.licensing.nodeCount // empty' 2>/dev/null || true)
        REPORT_LIC_NODE_LIMIT=$(echo "${last_report}" | jq -r '.results.licensing.nodeLimit // empty' 2>/dev/null || true)
        REPORT_LIC_EXPIRY=$(echo     "${last_report}" | jq -r '.results.licensing.expiry    // empty' 2>/dev/null || true)
        REPORT_LIC_STATUS=$(echo     "${last_report}" | jq -r '.results.licensing.status    // empty' 2>/dev/null || true)
        REPORT_LIC_TYPE=$(echo       "${last_report}" | jq -r '.results.licensing.type      // empty' 2>/dev/null || true)
    fi

    # Fallback if no report: sum PVCs (rough estimate)
    if [[ "${TOTAL_BACKUP_DATA}" == "N/A" ]]; then
        local pvc_json pvc_count total_bytes
        pvc_json=$(${K} get pvc -n "${KASTEN_NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')
        pvc_count=$(echo "${pvc_json}" | jq '.items | length' 2>/dev/null || echo "0")

        if [[ "${pvc_count}" -gt 0 ]]; then
            total_bytes=$(echo "${pvc_json}" | jq '
                [.items[].status.capacity.storage // "0" |
                 if endswith("Ti") then (rtrimstr("Ti") | tonumber * 1099511627776)
                 elif endswith("Gi") then (rtrimstr("Gi") | tonumber * 1073741824)
                 elif endswith("Mi") then (rtrimstr("Mi") | tonumber * 1048576)
                 elif endswith("Ki") then (rtrimstr("Ki") | tonumber * 1024)
                 else (rtrimstr("i") | tonumber) end
                ] | add
            ' 2>/dev/null || echo "0")

            if [[ -n "${total_bytes}" && "${total_bytes}" != "null" && "${total_bytes}" -gt 0 ]] 2>/dev/null; then
                TOTAL_BACKUP_DATA=$(humanize_bytes "${total_bytes}")
            fi
        fi
    fi
}

# ─── Services health ─────────────────────────────────────────────────────────
get_services_status() {
    SERVICE_NAMES=()
    SERVICE_STATUSES=()
    SERVICE_REPLICAS=()
    ALL_HEALTHY=true

    local deploys count
    deploys=$(${K} get deploy -n "${KASTEN_NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')
    count=$(echo "${deploys}" | jq '.items | length')

    local i
    for i in $(seq 0 $((count - 1))); do
        local name ready replicas
        name=$(echo "${deploys}" | jq -r ".items[${i}].metadata.name")
        ready=$(echo "${deploys}" | jq -r ".items[${i}].status.readyReplicas // 0")
        replicas=$(echo "${deploys}" | jq -r ".items[${i}].status.replicas // 0")

        SERVICE_NAMES+=("${name}")
        SERVICE_REPLICAS+=("${ready}/${replicas}")
        if [[ "${ready}" -ge "${replicas}" && "${replicas}" -gt 0 ]]; then
            SERVICE_STATUSES+=("Healthy")
        else
            SERVICE_STATUSES+=("Degraded")
            ALL_HEALTHY=false
        fi
    done
}

# ─── License & Consumption ────────────────────────────────────────────────────
# K10 license is stored in secret "k10-license" as YAML.
# Fields: customerName, dateEnd, dateStart, features, id, product, restrictions.nodes
# Key matching is CASE-INSENSITIVE: real K10 license secrets use lowercase keys
# (customername/dateend/datestart) while trial/starter payloads use camelCase
# (customerName/dateEnd). A case-sensitive match returned empty customer/dates
# and broke starter detection (the wrong license was then selected). The value
# is taken as everything after the first ':' so embedded colons (ISO dates) are
# preserved.
yaml_val() {
    local yaml="$1" key="$2"
    echo "${yaml}" \
      | grep -i -m1 "^[[:space:]]*${key}:" \
      | sed -E "s/^[[:space:]]*[^:]*:[[:space:]]*//" \
      | sed "s/^['\"]//;s/['\"]$//"
}

get_license_info() {
    LIC_TYPE="N/A"; LIC_PLATFORM="N/A"; LIC_ID="N/A"
    LIC_CUSTOMER="N/A"
    LIC_ISSUED="N/A"; LIC_EXPIRES="N/A"; LIC_DAYS_LEFT="N/A"
    LIC_STATUS="Unknown"; LIC_STATUS_COLOR="#999999"; LIC_FEATURES=""
    LIC_NODE_LICENSED="N/A"; LIC_NODE_USED="N/A"; LIC_NODE_PCT="0"

    # ── Enumerate every k10-license* secret and prefer the non-starter license ──
    # The built-in `k10-license` secret holds the starter license (customer
    # "starter-license", expiry ~2100). Enterprise/renewal licenses are installed
    # as additional k10-license* secrets. Reading only `k10-license` (old
    # behaviour) always surfaced the starter license — BUG-01. Enumerate every
    # k10-license* secret, parse each defensively, and select the non-starter one
    # with the nearest real expiry; fall back to the starter license with an
    # explicit flag when no enterprise license is present.
    local secret_names sname raw_b64 decoded
    local starter_decoded="" chosen_decoded="" chosen_exp_epoch=0

    secret_names=$(${K} get secrets -n "${KASTEN_NAMESPACE}" -o json 2>/dev/null \
        | jq -r '[.items[]? | select(.metadata.name | startswith("k10-license")) | .metadata.name] | .[]' 2>/dev/null || true)
    # Broaden to any *license* secret if the k10-license* prefix matched nothing.
    if [[ -z "${secret_names}" ]]; then
        secret_names=$(${K} get secrets -n "${KASTEN_NAMESPACE}" --no-headers 2>/dev/null \
            | grep -i license | awk '{print $1}' || true)
    fi

    for sname in ${secret_names}; do
        raw_b64=$(${K} get secret -n "${KASTEN_NAMESPACE}" "${sname}" -o jsonpath='{.data.license}' 2>/dev/null \
            || ${K} get secret -n "${KASTEN_NAMESPACE}" "${sname}" -o jsonpath='{.data.License}' 2>/dev/null || true)
        [[ -z "${raw_b64}" ]] && continue
        decoded=$(echo "${raw_b64}" | base64 -d 2>/dev/null || echo "${raw_b64}" | base64 -D 2>/dev/null || true)
        [[ -z "${decoded}" ]] && continue

        local c_customer c_id c_end is_starter exp_epoch
        c_customer=$(yaml_val "${decoded}" "customerName")
        c_id=$(yaml_val "${decoded}" "id")
        # Skip payloads with no recognisable license signature.
        [[ -z "${c_customer}" && -z "${c_id}" ]] && continue

        is_starter=false
        if [[ "${c_customer}" == "starter-license" || "${c_id}" == starter-* ]]; then
            is_starter=true
        fi

        if [[ "${is_starter}" == true ]]; then
            [[ -z "${starter_decoded}" ]] && starter_decoded="${decoded}"
            continue
        fi

        # Non-starter candidate: keep the one with the nearest (smallest) real expiry.
        c_end=$(yaml_val "${decoded}" "dateEnd")
        exp_epoch=0
        if [[ -n "${c_end}" && "${c_end}" != "null" ]]; then
            exp_epoch=$(portable_date_epoch "${c_end}")
        fi
        if [[ -z "${chosen_decoded}" ]]; then
            chosen_decoded="${decoded}"; chosen_exp_epoch="${exp_epoch}"
        elif [[ "${exp_epoch}" -gt 0 && ( "${chosen_exp_epoch}" -le 0 || "${exp_epoch}" -lt "${chosen_exp_epoch}" ) ]]; then
            chosen_decoded="${decoded}"; chosen_exp_epoch="${exp_epoch}"
        fi
    done

    # Fall back to the starter license (flagged) when no enterprise license found.
    local from_starter=false
    if [[ -z "${chosen_decoded}" && -n "${starter_decoded}" ]]; then
        chosen_decoded="${starter_decoded}"; from_starter=true
    fi

    if [[ -n "${chosen_decoded}" ]]; then
        decoded="${chosen_decoded}"
        LIC_CUSTOMER=$(yaml_val "${decoded}" "customerName")
        LIC_TYPE=$(yaml_val "${decoded}" "product")
        LIC_ID=$(yaml_val "${decoded}" "id")
        LIC_ISSUED=$(yaml_val "${decoded}" "dateStart")
        LIC_EXPIRES=$(yaml_val "${decoded}" "dateEnd")

        local features_val
        features_val=$(yaml_val "${decoded}" "features")
        if [[ -n "${features_val}" && "${features_val}" != "null" ]]; then
            LIC_FEATURES="${features_val}"
        fi

        LIC_NODE_LICENSED=$(echo "${decoded}" | grep -m1 "nodes:" | sed "s/.*nodes:[[:space:]]*//" | sed "s/^['\"]//;s/['\"]$//")
        if [[ -z "${LIC_NODE_LICENSED}" ]]; then
            LIC_NODE_LICENSED="Unlimited"
        fi

        LIC_PLATFORM="Kubernetes"

        # Make the fallback explicit so the report never silently shows the
        # built-in starter license as if it were the customer's real entitlement.
        if [[ "${from_starter}" == true ]]; then
            LIC_CUSTOMER="${LIC_CUSTOMER} [starter-license intégrée]"
        fi
    fi

    # Node count (live cluster)
    if [[ "${LIC_NODE_USED}" == "N/A" || "${LIC_NODE_USED}" == "null" || -z "${LIC_NODE_USED}" ]]; then
        LIC_NODE_USED=$(${K} get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    fi

    # ── Enrich/override with K10 report data (authoritative for nodes & expiry) ──
    # The K10 report exposes results.licensing.{nodeCount, nodeLimit, expiry, status}
    # which is K10's own view of the license. We prefer it over the YAML secret
    # for node accounting and expiry status.
    if [[ -n "${REPORT_LIC_NODE_COUNT}" ]]; then
        LIC_NODE_USED="${REPORT_LIC_NODE_COUNT}"
    fi
    if [[ -n "${REPORT_LIC_NODE_LIMIT}" ]]; then
        LIC_NODE_LICENSED="${REPORT_LIC_NODE_LIMIT}"
    fi
    if [[ -n "${REPORT_LIC_EXPIRY}" && "${REPORT_LIC_EXPIRY}" != "null" ]]; then
        LIC_EXPIRES="${REPORT_LIC_EXPIRY}"
    elif [[ -n "${REPORT_LIC_STATUS}" && "${REPORT_LIC_EXPIRY}" == "null" ]]; then
        # K10 reports expiry: null when license has no end date (e.g. permanent)
        LIC_EXPIRES="Permanent"
    fi

    # Days remaining
    if [[ "${LIC_EXPIRES}" == "Permanent" ]]; then
        LIC_DAYS_LEFT="∞"
        # If K10 report said status: Valid, trust it; else infer green
        if [[ -n "${REPORT_LIC_STATUS}" && "${REPORT_LIC_STATUS}" == "Valid" ]]; then
            LIC_STATUS="Valid"; LIC_STATUS_COLOR="#27AE60"
        else
            LIC_STATUS="Valid"; LIC_STATUS_COLOR="#27AE60"
        fi
    elif [[ "${LIC_EXPIRES}" != "N/A" && "${LIC_EXPIRES}" != "null" && -n "${LIC_EXPIRES}" ]]; then
        local exp_epoch now_epoch
        exp_epoch=$(portable_date_epoch "${LIC_EXPIRES}")
        now_epoch=$(date +%s)
        if [[ "${exp_epoch}" -gt 0 ]]; then
            LIC_DAYS_LEFT=$(( (exp_epoch - now_epoch) / 86400 ))
            LIC_EXPIRES=$(portable_date_fmt "${LIC_EXPIRES}" "%b %d, %Y")
            if [[ "${LIC_DAYS_LEFT}" -le 0 ]]; then
                LIC_STATUS="EXPIRED"; LIC_STATUS_COLOR="#E74C3C"
            elif [[ "${LIC_DAYS_LEFT}" -le 30 ]]; then
                LIC_STATUS="Expiring Soon"; LIC_STATUS_COLOR="#E74C3C"
            elif [[ "${LIC_DAYS_LEFT}" -le 90 ]]; then
                LIC_STATUS="Attention"; LIC_STATUS_COLOR="#F39C12"
            else
                LIC_STATUS="Valid"; LIC_STATUS_COLOR="#27AE60"
            fi
        fi
    fi

    if [[ "${LIC_ISSUED}" != "N/A" && "${LIC_ISSUED}" != "null" && -n "${LIC_ISSUED}" ]]; then
        LIC_ISSUED=$(portable_date_fmt "${LIC_ISSUED}" "%b %d, %Y")
    fi

    # Node consumption %
    if [[ "${LIC_NODE_LICENSED}" =~ ^[0-9]+$ && "${LIC_NODE_USED}" =~ ^[0-9]+$ ]]; then
        if [[ "${LIC_NODE_LICENSED}" -gt 0 ]]; then
            LIC_NODE_PCT=$(( LIC_NODE_USED * 100 / LIC_NODE_LICENSED ))
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  COLLECT
# ═══════════════════════════════════════════════════════════════════════════════
log "Gathering Kasten version..."
KASTEN_VERSION=$(get_kasten_version)
log "  → Version: ${KASTEN_VERSION}"

log "Gathering application data..."
get_applications
log "  → ${TOTAL_APPS} apps (${COMPLIANT_APPS} compliant, ${NONCOMPLIANT_APPS} non-compliant, ${UNMANAGED_APPS} unmanaged)"

log "Loading runactions (single fetch, reused)..."
load_runactions
log "  → $(echo "${RUNACTIONS_JSON}" | jq '.items | length') runactions loaded"

log "Loading K10 reports (single fetch, reused)..."
load_reports
log "  → $(echo "${REPORTS_JSON}" | jq '.items | length') K10 reports loaded"

log "Loading export actions (single fetch)..."
load_exportactions
log "  → $(echo "${EXPORTACTIONS_JSON}" | jq '.items | length') export actions loaded"

log "Gathering policy data..."
get_policies
log "  → ${TOTAL_POLICIES} policies (${#POLICY_NAMES[@]} enumerated)"

log "Computing daily action stats (from K10 reports countStats)..."
get_daily_action_stats

log "Identifying top failed/skipped exports..."
get_failed_exports
log "  → ${FAILED_EXPORT_COUNT} failed/skipped export(s) in top-5"

log "Gathering storage info..."
get_storage_info
log "  → Backup data: ${TOTAL_BACKUP_DATA} | Snapshot: ${SNAPSHOT_SIZE} | Object: ${OBJECT_STORAGE}"

# Enrich from K10 report when available
if [[ -n "${REPORT_COMPLIANCE_APPS}" ]]; then
    TOTAL_APPS="${REPORT_COMPLIANCE_APPS}"
    COMPLIANT_APPS="${REPORT_COMPLIANCE_COMPLIANT:-0}"
    NONCOMPLIANT_APPS="${REPORT_COMPLIANCE_NONCOMPLIANT:-0}"
    UNMANAGED_APPS="${REPORT_COMPLIANCE_UNMANAGED:-0}"
    log "  → Compliance (from report): ${TOTAL_APPS} apps, ${COMPLIANT_APPS} compliant, ${NONCOMPLIANT_APPS} non-compliant, ${UNMANAGED_APPS} unmanaged"
fi
if [[ -n "${REPORT_K10_VERSION}" ]]; then
    KASTEN_VERSION="${REPORT_K10_VERSION}"
    log "  → Version (from report): ${KASTEN_VERSION}"
fi

log "Gathering services status..."
get_services_status
log "  → ${#SERVICE_NAMES[@]} deployments"

log "Gathering license & consumption data..."
get_license_info
log "  → License: ${LIC_CUSTOMER} | ${LIC_TYPE} | Status: ${LIC_STATUS} | Expires: ${LIC_EXPIRES} | Nodes: ${LIC_NODE_USED}/${LIC_NODE_LICENSED}"

# Count failed policies (used by alert banner)
FAILED_POLICY_COUNT=0
for s in "${POLICY_STATUSES[@]:-}"; do
    if [[ "${s}" == "Failed" ]]; then
        FAILED_POLICY_COUNT=$(( FAILED_POLICY_COUNT + 1 ))
    fi
done

log "Data collection complete. Building reports..."

# ═══════════════════════════════════════════════════════════════════════════════
#  JSON REPORT
# ═══════════════════════════════════════════════════════════════════════════════
generate_json() {
    local policy_array="[]"
    if [[ ${#POLICY_NAMES[@]} -gt 0 ]]; then
        for i in "${!POLICY_NAMES[@]}"; do
            policy_array=$(echo "${policy_array}" | jq \
                --arg name    "${POLICY_NAMES[$i]}" \
                --arg type    "${POLICY_TYPES[$i]}" \
                --arg lastRun "${POLICY_LAST_RUN[$i]}" \
                --arg status  "${POLICY_STATUSES[$i]}" \
                --arg details "${POLICY_DETAILS[$i]}" \
                '. + [{"name":$name,"type":$type,"lastRun":$lastRun,"status":$status,"details":$details}]')
        done
    fi

    local service_array="[]"
    if [[ ${#SERVICE_NAMES[@]} -gt 0 ]]; then
        for i in "${!SERVICE_NAMES[@]}"; do
            service_array=$(echo "${service_array}" | jq \
                --arg name     "${SERVICE_NAMES[$i]}" \
                --arg replicas "${SERVICE_REPLICAS[$i]}" \
                --arg status   "${SERVICE_STATUSES[$i]}" \
                '. + [{"name":$name,"replicas":$replicas,"status":$status}]')
        done
    fi

    # Build dailyStats array from the last 3 scheduled K10 reports.
    # v3.1: ventilation B (Backup/Restore/Export/Autres + Run separated) +
    # raw countStats kept for forward compatibility and debugging.
    local daily_stats_array
    daily_stats_array=$(echo "${REPORTS_JSON}" | jq '
        def group_of(k):
            if   k == "backup"  or k == "backupCluster"  then "Backup"
            elif k == "restore" or k == "restoreCluster" then "Restore"
            elif k == "export"                           then "Export"
            elif k == "run"                              then "Run"
            else                                              "Autres"
            end;
        def zero: {completed:0, failed:0, skipped:0, cancelled:0};
        [.items[] | select(.metadata.generateName? | tostring | startswith("scheduled-"))]
        | sort_by(.metadata.creationTimestamp) | reverse | .[0:3]
        | map(
            (.results.actions.countStats // {}) as $cs |
            {
              date: (.spec.statsIntervalEndTimestamp // .spec.reportTimestamp // .metadata.creationTimestamp),
              grouped: (
                reduce ($cs | to_entries[]) as $e (
                  { "Backup":zero, "Restore":zero, "Export":zero, "Autres":zero, "Run":zero };
                  .[group_of($e.key)] |= {
                    completed: (.completed + ($e.value.completed // 0)),
                    failed:    (.failed    + ($e.value.failed    // 0)),
                    skipped:   (.skipped   + ($e.value.skipped   // 0)),
                    cancelled: (.cancelled + ($e.value.cancelled // 0))
                  }
                )
              ),
              raw: $cs
            }
          )
    ' 2>/dev/null || echo '[]')

    # Build failedExports array (top 5)
    local failed_exports_array
    failed_exports_array=$(echo "${EXPORTACTIONS_JSON}" | jq "${JQ_ERR_HELPERS}"'
        [.items[]
         | select(.status.state == "Failed" or .status.state == "Skipped")
         | {
             name:       .metadata.name,
             state:      .status.state,
             endTime:    (.status.endTime // .metadata.creationTimestamp),
             policyName: (.metadata.labels["k10.kasten.io/policyName"]      // null),
             policyNamespace: (.metadata.labels["k10.kasten.io/policyNamespace"] // null),
             appNamespace: (
               .metadata.labels["k10.kasten.io/appNamespace"] //
               (try ((.status.exceptions // [])
                     | map(.fields // []) | flatten
                     | map(select(.name == "subject")) | .[0].value
                     | fromjson | .app.namespace.name) catch null) //
               (.status.error | errappns) //
               .metadata.namespace
             ),
             skipReason: (.metadata.labels["k10.kasten.io/actionSkipReason"] // null),
             error:      ((.status.error // .status.exceptions[0].message) | deepmsg)
           }
        ]
        | sort_by(.endTime) | reverse | .[0:5]
    ' 2>/dev/null || echo '[]')

    jq -n \
        --arg date "${TODAY}" \
        --arg time "${TIME_NOW}" \
        --arg cluster "${CLUSTER_NAME}" \
        --arg instance "${INSTANCE_ID}" \
        --arg version "${KASTEN_VERSION}" \
        --arg is_openshift "${IS_OPENSHIFT}" \
        --arg total_apps "${TOTAL_APPS}" \
        --arg compliant "${COMPLIANT_APPS}" \
        --arg noncompliant "${NONCOMPLIANT_APPS}" \
        --arg unmanaged "${UNMANAGED_APPS}" \
        --arg total_policies "${TOTAL_POLICIES}" \
        --arg backup_policies "${BACKUP_POLICIES}" \
        --arg import_policies "${IMPORT_POLICIES}" \
        --arg system_policies "${SYSTEM_POLICIES}" \
        --arg failed_policies "${FAILED_POLICY_COUNT}" \
        --arg backup_data "${TOTAL_BACKUP_DATA}" \
        --arg snapshot_size "${SNAPSHOT_SIZE}" \
        --arg object_storage "${OBJECT_STORAGE}" \
        --arg lic_customer "${LIC_CUSTOMER}" \
        --arg lic_type "${LIC_TYPE}" \
        --arg lic_id "${LIC_ID}" \
        --arg lic_platform "${LIC_PLATFORM}" \
        --arg lic_issued "${LIC_ISSUED}" \
        --arg lic_expires "${LIC_EXPIRES}" \
        --arg lic_days_left "${LIC_DAYS_LEFT}" \
        --arg lic_status "${LIC_STATUS}" \
        --arg lic_node_licensed "${LIC_NODE_LICENSED}" \
        --arg lic_node_used "${LIC_NODE_USED}" \
        --arg lic_node_pct "${LIC_NODE_PCT}" \
        --arg lic_features "${LIC_FEATURES}" \
        --arg all_healthy "${ALL_HEALTHY}" \
        --argjson policies "${policy_array}" \
        --argjson services "${service_array}" \
        --argjson daily_stats "${daily_stats_array}" \
        --argjson failed_exports "${failed_exports_array}" \
        '{
            "reportDate": $date,
            "reportTime": $time,
            "cluster": {
                "name": $cluster,
                "instanceId": $instance,
                "kastenVersion": $version,
                "isOpenShift": ($is_openshift == "true")
            },
            "applications": {
                "total": ($total_apps | tonumber),
                "compliant": ($compliant | tonumber),
                "nonCompliant": ($noncompliant | tonumber),
                "unmanaged": ($unmanaged | tonumber)
            },
            "policies": {
                "total": ($total_policies | tonumber),
                "backup": ($backup_policies | tonumber),
                "import": ($import_policies | tonumber),
                "system": ($system_policies | tonumber),
                "failed": ($failed_policies | tonumber),
                "details": $policies
            },
            "storage": {
                "totalBackupData": $backup_data,
                "snapshotSize": $snapshot_size,
                "objectStorage": $object_storage
            },
            "license": {
                "customer": $lic_customer,
                "product": $lic_type,
                "id": $lic_id,
                "platform": $lic_platform,
                "issued": $lic_issued,
                "expires": $lic_expires,
                "daysLeft": ($lic_days_left | tonumber? // $lic_days_left),
                "status": $lic_status,
                "features": $lic_features,
                "consumption": {
                    "nodes": {
                        "used": ($lic_node_used | tonumber? // $lic_node_used),
                        "licensed": ($lic_node_licensed | tonumber? // $lic_node_licensed),
                        "percent": ($lic_node_pct | tonumber)
                    }
                }
            },
            "services": {
                "allHealthy": ($all_healthy == "true"),
                "details": $services
            },
            "dailyStats": $daily_stats,
            "failedExports": $failed_exports
        }' > "${JSON_FILE}" 2>/tmp/kasten-json-error.log

    if [[ -s "${JSON_FILE}" ]]; then
        log "JSON report saved to: ${JSON_FILE} ($(wc -c < "${JSON_FILE}" | tr -d ' ') bytes)"
    else
        warn "JSON generation failed. Check /tmp/kasten-json-error.log"
        cat /tmp/kasten-json-error.log >&2 2>/dev/null || true
    fi
}

generate_json

# ═══════════════════════════════════════════════════════════════════════════════
#  HTML REPORT
# ═══════════════════════════════════════════════════════════════════════════════

# Pre-escape values that will be injected verbatim into HTML
H_CLUSTER_NAME=$(html_escape "${CLUSTER_NAME}")
H_INSTANCE_ID=$(html_escape "${INSTANCE_ID}")
H_KASTEN_VERSION=$(html_escape "${KASTEN_VERSION}")
H_LIC_CUSTOMER=$(html_escape "${LIC_CUSTOMER}")
H_LIC_TYPE=$(html_escape "${LIC_TYPE}")
H_LIC_ID=$(html_escape "${LIC_ID}")
H_LIC_ISSUED=$(html_escape "${LIC_ISSUED}")
H_LIC_EXPIRES=$(html_escape "${LIC_EXPIRES}")
H_LIC_FEATURES=$(html_escape "${LIC_FEATURES}")

# Policy rows (escape every cluster-derived value)
POLICY_TABLE_ROWS=""
POLICY_ERROR_ROWS=""
for i in "${!POLICY_NAMES[@]}"; do
    status_color="#999999"; status_icon="&#8212;"
    case "${POLICY_STATUSES[$i]}" in
        Success) status_color="#27AE60"; status_icon="&#10003;" ;;
        Failed)  status_color="#E74C3C"; status_icon="&#10007;" ;;
        Running) status_color="#F39C12"; status_icon="&#9881;"  ;;
    esac
    row_bg=""
    if [[ $((i % 2)) -eq 1 ]]; then row_bg=' style="background-color:#F7F9FC;"'; fi

    pname_h=$(html_escape   "${POLICY_NAMES[$i]}")
    ptype_h=$(html_escape   "${POLICY_TYPES[$i]}")
    plast_h=$(html_escape   "${POLICY_LAST_RUN[$i]}")
    pstat_h=$(html_escape   "${POLICY_STATUSES[$i]}")
    pdet_h=$(html_escape    "${POLICY_DETAILS[$i]}")

    POLICY_TABLE_ROWS+="
    <tr${row_bg}>
        <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;font-weight:600;'>${pname_h}</td>
        <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;'>${ptype_h}</td>
        <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;'>${plast_h}</td>
        <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;text-align:center;color:${status_color};font-weight:700;'>${status_icon} ${pstat_h}</td>
        <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;'>${pdet_h}</td>
    </tr>"
    if [[ "${POLICY_STATUSES[$i]}" == "Failed" ]]; then
        POLICY_ERROR_ROWS+="
        <tr><td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;font-weight:600;'>${pname_h}</td>
        <td style='padding:10px 14px;border-bottom:1px solid #E8E8E8;color:#E74C3C;'>${pdet_h}</td></tr>"
    fi
done

# Service rows (escape names)
SERVICE_TABLE_ROWS=""
for i in "${!SERVICE_NAMES[@]}"; do
    svc_color="#27AE60"; svc_icon="&#10003;"
    if [[ "${SERVICE_STATUSES[$i]}" != "Healthy" ]]; then
        svc_color="#E74C3C"; svc_icon="&#10007;"
    fi
    row_bg=""
    if [[ $((i % 2)) -eq 1 ]]; then row_bg=' style="background-color:#F7F9FC;"'; fi

    sname_h=$(html_escape "${SERVICE_NAMES[$i]}")
    srep_h=$(html_escape  "${SERVICE_REPLICAS[$i]}")
    sstat_h=$(html_escape "${SERVICE_STATUSES[$i]}")

    SERVICE_TABLE_ROWS+="
    <tr${row_bg}>
        <td style='padding:8px 14px;border-bottom:1px solid #E8E8E8;'>${sname_h}</td>
        <td style='padding:8px 14px;border-bottom:1px solid #E8E8E8;text-align:center;'>${srep_h}</td>
        <td style='padding:8px 14px;border-bottom:1px solid #E8E8E8;text-align:center;color:${svc_color};font-weight:700;'>${svc_icon} ${sstat_h}</td>
    </tr>"
done

# Top-of-report alert banner (non-compliance + failed policies + failed actions)
# v3.1: DAILY_FAILED_TOTAL aggregates failed counts across Backup/Restore/Export/
# Autres groups in the last 3 K10 reports (Run excluded — see get_daily_action_stats).
ALERT_BANNER=""
DAILY_FAILED_TOTAL="${DAILY_FAILED_TOTAL:-0}"
if [[ "${NONCOMPLIANT_APPS}" -gt 0 || "${FAILED_POLICY_COUNT}" -gt 0 || "${DAILY_FAILED_TOTAL}" -gt 0 ]]; then
    alert_parts=""
    if [[ "${NONCOMPLIANT_APPS}" -gt 0 ]]; then
        alert_parts="${NONCOMPLIANT_APPS} non-compliant application(s)"
    fi
    if [[ "${FAILED_POLICY_COUNT}" -gt 0 ]]; then
        if [[ -n "${alert_parts}" ]]; then alert_parts="${alert_parts} &bull; "; fi
        alert_parts="${alert_parts}${FAILED_POLICY_COUNT} failed polic$(if [[ ${FAILED_POLICY_COUNT} -eq 1 ]]; then echo y; else echo ies; fi)"
    fi
    if [[ "${DAILY_FAILED_TOTAL}" -gt 0 ]]; then
        if [[ -n "${alert_parts}" ]]; then alert_parts="${alert_parts} &bull; "; fi
        alert_parts="${alert_parts}${DAILY_FAILED_TOTAL} failed action(s) in last 3 reports"
    fi
    ALERT_BANNER="<div style='background:#E74C3C;color:#fff;padding:12px 20px;border-radius:6px;font-weight:700;font-size:15px;margin-bottom:16px;'>&#9888; Action required &mdash; ${alert_parts}</div>"
fi

# Service health banner
if ${ALL_HEALTHY}; then
    HEALTH_BANNER="<div style='background:#27AE60;color:#fff;padding:12px 20px;border-radius:6px;font-weight:700;font-size:15px;margin-bottom:16px;'>&#10003; All services are operational</div>"
else
    HEALTH_BANNER="<div style='background:#E74C3C;color:#fff;padding:12px 20px;border-radius:6px;font-weight:700;font-size:15px;margin-bottom:16px;'>&#10007; Some services are degraded</div>"
fi

NONCOMPLIANT_COLOR="#27AE60"
if [[ "${NONCOMPLIANT_APPS}" -gt 0 ]]; then NONCOMPLIANT_COLOR="#E74C3C"; fi

# License banner
LIC_BANNER_BG="${LIC_STATUS_COLOR}"; LIC_BANNER_ICON="&#10003;"; LIC_BANNER_TEXT="License valid &mdash; ${LIC_DAYS_LEFT} days remaining"
case "${LIC_STATUS}" in
    EXPIRED)         LIC_BANNER_ICON="&#10007;"; LIC_BANNER_TEXT="LICENSE EXPIRED &mdash; Renew immediately" ;;
    "Expiring Soon") LIC_BANNER_ICON="&#9888;";  LIC_BANNER_TEXT="License expiring in ${LIC_DAYS_LEFT} days &mdash; Action required" ;;
    Attention)       LIC_BANNER_ICON="&#9888;";  LIC_BANNER_TEXT="License expires in ${LIC_DAYS_LEFT} days &mdash; Plan renewal" ;;
    Unknown)         LIC_BANNER_ICON="&#8212;";  LIC_BANNER_TEXT="License status could not be determined"; LIC_BANNER_BG="#999999" ;;
esac
LICENSE_BANNER="<div style='background:${LIC_BANNER_BG};color:#fff;padding:12px 20px;border-radius:6px;font-weight:700;font-size:14px;margin-bottom:16px;'>${LIC_BANNER_ICON} ${LIC_BANNER_TEXT}</div>"

# Consumption bars
build_progress_bar() {
    local used="$1" licensed="$2" pct="$3" label="$4" bar_color="#27AE60"
    if [[ "${pct}" -ge 95 ]]; then bar_color="#E74C3C"
    elif [[ "${pct}" -ge 80 ]]; then bar_color="#F39C12"
    fi
    local dp="${pct}"
    if [[ "${dp}" -gt 100 ]]; then dp=100; fi
    printf '<div style="margin-bottom:14px;"><div style="display:flex;justify-content:space-between;margin-bottom:4px;"><span style="font-size:12px;font-weight:600;color:#333;">%s</span><span style="font-size:12px;color:#666;">%s / %s <span style="color:%s;font-weight:700;">(%s%%)</span></span></div><div style="background:#E8E8E8;border-radius:6px;height:10px;overflow:hidden;"><div style="background:%s;width:%s%%;height:100%%;border-radius:6px;"></div></div></div>' \
        "${label}" "${used}" "${licensed}" "${bar_color}" "${pct}" "${bar_color}" "${dp}"
}

build_unlimited_bar() {
    local used="$1" label="$2"
    printf '<div style="margin-bottom:14px;"><div style="display:flex;justify-content:space-between;margin-bottom:4px;"><span style="font-size:12px;font-weight:600;color:#333;">%s</span><span style="font-size:12px;color:#666;">%s used &bull; Unlimited</span></div><div style="background:#E8E8E8;border-radius:6px;height:10px;overflow:hidden;"><div style="background:#27AE60;width:100%%;height:100%%;border-radius:6px;opacity:0.3;"></div></div></div>' \
        "${label}" "${used}"
}

NODE_BAR=""
if [[ "${LIC_NODE_LICENSED}" =~ ^[0-9]+$ ]]; then
    NODE_BAR=$(build_progress_bar "${LIC_NODE_USED}" "${LIC_NODE_LICENSED}" "${LIC_NODE_PCT}" "Nodes")
else
    NODE_BAR=$(build_unlimited_bar "${LIC_NODE_USED}" "Nodes")
fi

FEATURES_LINE="Feature details not available"
if [[ -n "${LIC_FEATURES}" && "${LIC_FEATURES}" != "null" ]]; then
    FEATURES_LINE="Features: <span style='color:#666;'>${H_LIC_FEATURES}</span>"
fi

OCP_BADGE=""
if ${IS_OPENSHIFT}; then
    OCP_BADGE=" &bull; <span style='background:rgba(255,255,255,0.15);padding:2px 8px;border-radius:10px;font-size:11px;'>OpenShift</span>"
fi

cat > "${REPORT_FILE}" <<HTMLEOF
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>
<body style="margin:0;padding:0;background:#F4F5F7;font-family:Arial,Helvetica,sans-serif;color:#333;">
<div style="max-width:720px;margin:20px auto;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,0.08);">

<div style="background:linear-gradient(135deg,#1B2A4A,#2E75B6);padding:30px 32px;">
    <h1 style="margin:0 0 4px;color:#fff;font-size:24px;">&#9749; Morning Coffee Report</h1>
    <p style="margin:0;color:rgba(255,255,255,0.75);font-size:13px;">${TODAY_PRETTY} &nbsp;|&nbsp; ${TIME_NOW} &nbsp;|&nbsp; Kasten ${H_KASTEN_VERSION}${OCP_BADGE}</p>
    <p style="margin:8px 0 0;color:rgba(255,255,255,0.6);font-size:12px;">Cluster: <strong style="color:#fff;">${H_CLUSTER_NAME}</strong> &nbsp;&bull;&nbsp; Instance: <strong style="color:#fff;">${H_INSTANCE_ID}</strong></p>
</div>

<div style="padding:24px 32px;">

${ALERT_BANNER}

<h2 style="margin:0 0 16px;font-size:17px;color:#1B2A4A;border-bottom:3px solid #2E75B6;padding-bottom:8px;">1. Cluster Overview</h2>
<table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:8px;"><tr>
    <td style="width:33%;padding:0 6px 0 0;vertical-align:top;"><div style="border-top:3px solid #27AE60;background:#F7F9FC;border-radius:0 0 6px 6px;padding:16px;"><div style="font-size:11px;color:#888;text-transform:uppercase;">Applications</div><div style="font-size:30px;font-weight:700;color:#1A1A2E;margin:4px 0;">${TOTAL_APPS}</div><div style="font-size:11px;color:#666;">${COMPLIANT_APPS} compliant &bull; <span style="color:${NONCOMPLIANT_COLOR};">${NONCOMPLIANT_APPS} non-compliant</span> &bull; ${UNMANAGED_APPS} unmanaged</div></div></td>
    <td style="width:33%;padding:0 3px;vertical-align:top;"><div style="border-top:3px solid #2E75B6;background:#F7F9FC;border-radius:0 0 6px 6px;padding:16px;"><div style="font-size:11px;color:#888;text-transform:uppercase;">Policies</div><div style="font-size:30px;font-weight:700;color:#1A1A2E;margin:4px 0;">${TOTAL_POLICIES}</div><div style="font-size:11px;color:#666;">${BACKUP_POLICIES} backup &bull; ${IMPORT_POLICIES} import &bull; ${SYSTEM_POLICIES} system</div></div></td>
    <td style="width:33%;padding:0 0 0 6px;vertical-align:top;"><div style="border-top:3px solid #F39C12;background:#F7F9FC;border-radius:0 0 6px 6px;padding:16px;"><div style="font-size:11px;color:#888;text-transform:uppercase;">Backup Data</div><div style="font-size:30px;font-weight:700;color:#1A1A2E;margin:4px 0;">${TOTAL_BACKUP_DATA}</div><div style="font-size:11px;color:#666;">Snap: ${SNAPSHOT_SIZE} &bull; Object: ${OBJECT_STORAGE}</div></div></td>
</tr></table>

<h2 style="margin:24px 0 16px;font-size:17px;color:#1B2A4A;border-bottom:3px solid #2E75B6;padding-bottom:8px;">2. License &amp; Consumption</h2>
${LICENSE_BANNER}
<table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:16px;"><tr>
    <td style="width:50%;padding:0 8px 0 0;vertical-align:top;"><div style="background:#F7F9FC;border-radius:6px;padding:16px;border:1px solid #E8E8E8;"><div style="font-size:11px;color:#888;text-transform:uppercase;margin-bottom:10px;">License Details</div><table cellpadding="0" cellspacing="0" style="font-size:12px;width:100%;"><tr><td style="padding:3px 0;color:#888;width:90px;">Customer</td><td style="padding:3px 0;font-weight:600;">${H_LIC_CUSTOMER}</td></tr><tr><td style="padding:3px 0;color:#888;">Product</td><td style="padding:3px 0;font-weight:600;">${H_LIC_TYPE}</td></tr><tr><td style="padding:3px 0;color:#888;">License ID</td><td style="padding:3px 0;font-weight:600;font-size:10px;word-break:break-all;">${H_LIC_ID}</td></tr><tr><td style="padding:3px 0;color:#888;">Issued</td><td style="padding:3px 0;">${H_LIC_ISSUED}</td></tr><tr><td style="padding:3px 0;color:#888;">Expires</td><td style="padding:3px 0;font-weight:700;color:${LIC_STATUS_COLOR};">${H_LIC_EXPIRES}</td></tr><tr><td style="padding:3px 0;color:#888;">Days Left</td><td style="padding:3px 0;font-weight:700;color:${LIC_STATUS_COLOR};">${LIC_DAYS_LEFT}</td></tr></table></div></td>
    <td style="width:50%;padding:0 0 0 8px;vertical-align:top;"><div style="background:#F7F9FC;border-radius:6px;padding:16px;border:1px solid #E8E8E8;"><div style="font-size:11px;color:#888;text-transform:uppercase;margin-bottom:10px;">Consumption</div>${NODE_BAR}<div style="font-size:11px;color:#AAA;margin-top:8px;border-top:1px solid #E8E8E8;padding-top:8px;">${FEATURES_LINE}</div></div></td>
</tr></table>

<h2 style="margin:24px 0 16px;font-size:17px;color:#1B2A4A;border-bottom:3px solid #2E75B6;padding-bottom:8px;">3. Daily Action Stats (Last 3 K10 Reports)</h2>
<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px;">
<thead><tr style="background:#1B2A4A;">
    <th style="padding:10px 14px;color:#fff;text-align:left;">Date</th>
    <th style="padding:10px 14px;color:#fff;text-align:center;">Backup</th>
    <th style="padding:10px 14px;color:#fff;text-align:center;">Restore</th>
    <th style="padding:10px 14px;color:#fff;text-align:center;">Export</th>
    <th style="padding:10px 14px;color:#fff;text-align:center;">Autres</th>
    <th style="padding:10px 14px;color:#fff;text-align:center;color:#BBB;">Run</th>
</tr></thead>
<tbody>${REPORT_ROWS}</tbody></table>
<p style="margin:6px 2px 0;font-size:11px;color:#888;">
    Legend: <span style="color:#27AE60;font-weight:600;">N&nbsp;&#10003;</span> completed &nbsp;&bull;&nbsp; <span style="color:#E74C3C;font-weight:700;">N&nbsp;&#10007;</span> failed &nbsp;&bull;&nbsp; <span style="color:#F39C12;">N&nbsp;skip</span> skipped &nbsp;&bull;&nbsp; <span style="color:#888;">N&nbsp;cnl</span> cancelled<br/>
    <em>Backup</em> = backup + backupCluster &nbsp;&bull;&nbsp; <em>Restore</em> = restore + restoreCluster &nbsp;&bull;&nbsp; <em>Autres</em> = import + report &nbsp;&bull;&nbsp; <em>Run</em> = policy execution wrappers (excluded from total errors)
</p>

<h2 style="margin:24px 0 16px;font-size:17px;color:#1B2A4A;border-bottom:3px solid #2E75B6;padding-bottom:8px;">4. Last Policy Run Status</h2>
<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px;">
<thead><tr style="background:#1B2A4A;"><th style="padding:10px 14px;color:#fff;text-align:left;">Policy</th><th style="padding:10px 14px;color:#fff;text-align:center;">Type</th><th style="padding:10px 14px;color:#fff;text-align:center;">Last Run</th><th style="padding:10px 14px;color:#fff;text-align:center;">Status</th><th style="padding:10px 14px;color:#fff;text-align:left;">Details</th></tr></thead>
<tbody>${POLICY_TABLE_ROWS}</tbody></table>
$(if [[ -n "${POLICY_ERROR_ROWS}" ]]; then
echo '<h3 style="margin:16px 0 10px;font-size:14px;color:#E74C3C;">&#9888; Policy Errors</h3>'
echo '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px;border:1px solid #F5C6CB;">'
echo '<thead><tr style="background:#FDECEA;"><th style="padding:10px 14px;color:#E74C3C;text-align:left;">Policy</th><th style="padding:10px 14px;color:#E74C3C;text-align:left;">Error</th></tr></thead>'
echo "<tbody>${POLICY_ERROR_ROWS}</tbody></table>"
fi)

$(if [[ "${FAILED_EXPORT_COUNT}" -gt 0 ]]; then
cat <<TOPFAILEOF
<h2 style="margin:24px 0 16px;font-size:17px;color:#1B2A4A;border-bottom:3px solid #2E75B6;padding-bottom:8px;">5. Top 5 Failed / Skipped Exports</h2>
<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px;">
<thead><tr style="background:#1B2A4A;">
    <th style="padding:8px 12px;color:#fff;text-align:center;">State</th>
    <th style="padding:8px 12px;color:#fff;text-align:left;">When</th>
    <th style="padding:8px 12px;color:#fff;text-align:left;">Policy</th>
    <th style="padding:8px 12px;color:#fff;text-align:left;">App Namespace</th>
    <th style="padding:8px 12px;color:#fff;text-align:left;">Reason</th>
</tr></thead>
<tbody>${FAILED_EXPORT_ROWS}</tbody></table>
TOPFAILEOF
fi)

<h2 style="margin:24px 0 16px;font-size:17px;color:#1B2A4A;border-bottom:3px solid #2E75B6;padding-bottom:8px;">6. Services Status</h2>
${HEALTH_BANNER}
<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px;">
<thead><tr style="background:#1B2A4A;"><th style="padding:8px 14px;color:#fff;text-align:left;">Service</th><th style="padding:8px 14px;color:#fff;text-align:center;">Replicas</th><th style="padding:8px 14px;color:#fff;text-align:center;">Status</th></tr></thead>
<tbody>${SERVICE_TABLE_ROWS}</tbody></table>

<div style="margin-top:32px;padding-top:16px;border-top:1px solid #E8E8E8;font-size:11px;color:#AAA;text-align:center;">
    Generated on ${TODAY_PRETTY} at ${TIME_NOW} &bull; Kasten K10 ${H_KASTEN_VERSION} &bull; ${H_CLUSTER_NAME}
</div>
</div></div></body></html>
HTMLEOF

log "HTML report saved to: ${REPORT_FILE}"

# ═══════════════════════════════════════════════════════════════════════════════
#  RETENTION CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "${RETENTION_DAYS}" =~ ^[0-9]+$ && "${RETENTION_DAYS}" -gt 0 ]]; then
    deleted=$(find "${REPORT_DIR}" -maxdepth 1 -type f \
        \( -name 'kasten-report-*.html' -o -name 'kasten-report-*.json' \) \
        -mtime +${RETENTION_DAYS} -print -delete 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${deleted}" -gt 0 ]]; then
        log "Retention: deleted ${deleted} report file(s) older than ${RETENTION_DAYS} days"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  EMAIL DELIVERY
# ═══════════════════════════════════════════════════════════════════════════════
if [[ -z "${MAIL_SUBJECT}" ]]; then
    MAIL_SUBJECT="[Kasten] Morning Report — ${CLUSTER_NAME} — ${TODAY}"
fi

send_email() {
    if [[ -z "${MAIL_TO}" ]]; then
        warn "MAIL_TO is not set — skipping email. Report saved to: ${REPORT_FILE}"
        return 0
    fi
    log "Sending report to: ${MAIL_TO} (method: ${MAIL_METHOD})"
    log "  → HTML body + JSON attachment: $(basename "${JSON_FILE}")"
    case "${MAIL_METHOD}" in
        smtp)
            # Export everything Python needs; use a QUOTED heredoc so bash
            # does not expand $() or ${} inside the Python code (avoids
            # shell injection through SMTP_PASS, MAIL_SUBJECT, etc.).
            export _K_REPORT_FILE="${REPORT_FILE}"
            export _K_JSON_FILE="${JSON_FILE}"
            export _K_MAIL_SUBJECT="${MAIL_SUBJECT}"
            export _K_MAIL_FROM="${MAIL_FROM}"
            export _K_MAIL_TO="${MAIL_TO}"
            export _K_SMTP_SERVER="${SMTP_SERVER}"
            export _K_SMTP_PORT="${SMTP_PORT}"
            export _K_SMTP_USER="${SMTP_USER}"
            export _K_SMTP_PASS="${SMTP_PASS}"
            export _K_SMTP_TLS="${SMTP_TLS}"

            python3 - <<'PYEOF'
import os, smtplib, sys
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.mime.application import MIMEApplication

report_file  = os.environ["_K_REPORT_FILE"]
json_file    = os.environ["_K_JSON_FILE"]
mail_subject = os.environ["_K_MAIL_SUBJECT"]
mail_from    = os.environ["_K_MAIL_FROM"]
mail_to      = os.environ["_K_MAIL_TO"]
smtp_server  = os.environ["_K_SMTP_SERVER"]
smtp_port    = int(os.environ.get("_K_SMTP_PORT", "25"))
smtp_user    = os.environ.get("_K_SMTP_USER", "")
smtp_pass    = os.environ.get("_K_SMTP_PASS", "")
smtp_tls     = os.environ.get("_K_SMTP_TLS", "false").lower() == "true"

with open(report_file, "r", encoding="utf-8") as f:
    html_body = f.read()

msg = MIMEMultipart("mixed")
msg["Subject"] = mail_subject
msg["From"]    = mail_from
msg["To"]      = mail_to

body_part = MIMEMultipart("alternative")
body_part.attach(MIMEText("Kasten Morning Coffee Report. View in an HTML-capable client.", "plain"))
body_part.attach(MIMEText(html_body, "html"))
msg.attach(body_part)

if os.path.exists(json_file):
    with open(json_file, "r", encoding="utf-8") as jf:
        json_attachment = MIMEApplication(jf.read().encode("utf-8"), _subtype="json")
        json_attachment.add_header("Content-Disposition", "attachment",
                                   filename=os.path.basename(json_file))
        msg.attach(json_attachment)
    print(f"JSON attached: {os.path.basename(json_file)}")

try:
    server = smtplib.SMTP(smtp_server, smtp_port, timeout=30)
    server.ehlo()
    if smtp_tls:
        server.starttls(); server.ehlo()
    if smtp_user:
        server.login(smtp_user, smtp_pass)
    server.sendmail(mail_from, [r.strip() for r in mail_to.split(",") if r.strip()], msg.as_string())
    server.quit()
    print("Email sent successfully.")
except Exception as e:
    print(f"ERROR sending email: {e}", file=sys.stderr); sys.exit(1)
PYEOF
            # Clean up exported vars (best-effort)
            unset _K_REPORT_FILE _K_JSON_FILE _K_MAIL_SUBJECT _K_MAIL_FROM _K_MAIL_TO \
                  _K_SMTP_SERVER _K_SMTP_PORT _K_SMTP_USER _K_SMTP_PASS _K_SMTP_TLS
            ;;
        sendmail)
            local boundary="kasten-report-$$-$(date +%s)"
            {
                echo "From: ${MAIL_FROM}"
                echo "To: ${MAIL_TO}"
                echo "Subject: ${MAIL_SUBJECT}"
                echo "MIME-Version: 1.0"
                echo "Content-Type: multipart/mixed; boundary=\"${boundary}\""
                echo ""
                echo "--${boundary}"
                echo "Content-Type: text/html; charset=utf-8"
                echo ""
                cat "${REPORT_FILE}"
                echo ""
                echo "--${boundary}"
                echo "Content-Type: application/json; name=\"$(basename "${JSON_FILE}")\""
                echo "Content-Disposition: attachment; filename=\"$(basename "${JSON_FILE}")\""
                echo "Content-Transfer-Encoding: base64"
                echo ""
                base64 < "${JSON_FILE}" 2>/dev/null || base64 -i "${JSON_FILE}" 2>/dev/null
                echo ""
                echo "--${boundary}--"
            } | sendmail -t ;;
        mailx)
            if command -v mutt >/dev/null 2>&1; then
                echo "Kasten Morning Report" | mutt -e "set content_type=text/html" \
                    -s "${MAIL_SUBJECT}" -a "${JSON_FILE}" -- "${MAIL_TO}" < "${REPORT_FILE}"
            else
                mailx -a "Content-Type: text/html; charset=utf-8" \
                      -s "${MAIL_SUBJECT}" \
                      "${MAIL_TO}" < "${REPORT_FILE}"
                warn "mailx cannot attach files natively. JSON saved locally: ${JSON_FILE}"
            fi ;;
        file)
            log "MAIL_METHOD=file — reports saved to ${REPORT_FILE} and ${JSON_FILE}" ;;
        *)
            warn "Unknown MAIL_METHOD '${MAIL_METHOD}'. Reports at: ${REPORT_FILE} / ${JSON_FILE}" ;;
    esac
}
send_email

log "Morning Coffee Report complete!"
log "HTML : ${REPORT_FILE}"
log "JSON : ${JSON_FILE}"
