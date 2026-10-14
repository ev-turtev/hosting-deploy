#!/usr/bin/env bash
# job.sh — помощни функции за Backup / Restore workflow-ите (зарежда се със
# `source .github/hosting/job.sh`). Генерира го setup-github.sh от
# infra/github-workflows-template/hosting/ — не се редактира в repo-то.
#
# Базата е частна: работата с нея става в dbinit job-а на приложението, вътре
# в мрежата, с подменена команда (скриптовете до този файл). Изисква: az
# (логнат), jq; env RG.

# Пуска job с ДРУГА команда и образ. Печата името на изпълнението в $JOB_EXECUTION.
#   $1 = job, $2 = образ, $3 = скрипт (файл; /bin/sh -c), $4 = доп. env (JSON масив, по избор)
job_run_script() {
  local job="$1" image="$2" script="$3" extra="${4:-[]}" sub tmpl body
  sub=$(az account show --query id -o tsv)
  tmpl=$(az containerapp job show --name "$job" --resource-group "$RG" --query "properties.template.containers[0]" -o json)
  body=$(jq -n --argjson c "$tmpl" --arg img "$image" --rawfile s "$script" --argjson extra "$extra" \
    '{containers: [{name: $c.name, image: $img, command: ["/bin/sh", "-c", $s], args: [], env: (($c.env // []) + $extra), resources: $c.resources}]}')
  JOB_EXECUTION=$(az rest --method post \
    --uri "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.App/jobs/${job}/start?api-version=2023-05-01" \
    --body "$body" --query name -o tsv 2>/dev/null || true)
  if [ -z "$JOB_EXECUTION" ]; then
    sleep 5
    JOB_EXECUTION=$(az containerapp job execution list --name "$job" --resource-group "$RG" \
      --query "sort_by(@, &properties.startTime)[-1].name" -o tsv)
  fi
  [ -n "$JOB_EXECUTION" ] || { echo "::error::$job не тръгна"; return 1; }
  echo "пуснат: $job ($JOB_EXECUTION)"
  job_wait "$job" "$JOB_EXECUTION"
}

# Пуска job с неговата нормална команда.
job_run() {
  local job="$1"
  JOB_EXECUTION=$(az containerapp job start --name "$job" --resource-group "$RG" --query name -o tsv)
  echo "пуснат: $job ($JOB_EXECUTION)"
  job_wait "$job" "$JOB_EXECUTION"
}

# Чака изпълнението (до 60 минути). 0 = Succeeded.
job_wait() {
  local job="$1" execution="$2" status="Unknown" i
  for i in $(seq 1 360); do # до 60 минути (= replicaTimeout на job-овете)
    status=$(az containerapp job execution show --name "$job" --resource-group "$RG" \
      --job-execution-name "$execution" --query properties.status -o tsv 2>/dev/null || echo "Unknown")
    case "$status" in
      Succeeded) echo "OK  $job"; return 0 ;;
      Failed|Stopped|Degraded) break ;;
    esac
    sleep 10
  done
  echo "::error::$job завърши със статус $status. Логове (Azure портал -> Log Analytics pshared-log -> Logs, след 2-5 минути): ContainerAppConsoleLogs_CL | where ContainerGroupName_s startswith '$execution' | project TimeGenerated, Log_s | order by TimeGenerated asc"
  return 1
}

# Stop / Start на Container App-а (REST — az CLI няма команда) и чакане на състоянието.
app_power() {
  local sub
  sub=$(az account show --query id -o tsv)
  az rest --method post --output none \
    --uri "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.App/containerApps/${APP}/$1?api-version=2025-01-01"
}
app_wait_status() {
  local i s
  for i in $(seq 1 36); do
    s=$(az containerapp show --name "$APP" --resource-group "$RG" --query properties.runningStatus -o tsv 2>/dev/null || true)
    [ "$s" = "$1" ] && return 0
    sleep 5
  done
  echo "::error::$APP не стигна до $1 за 3 минути (сега: $s)"
  return 1
}

# Storage на средата (за прехвърлянето на дъмпа между job-а и GitHub).
# Задава STORAGE и STORAGE_KEY (маскиран в логовете).
storage_init() {
  STORAGE=$(az storage account list --resource-group "$RG" --query "[0].name" -o tsv)
  [ -n "$STORAGE" ] || { echo "::error::няма Storage в $RG"; return 1; }
  STORAGE_KEY=$(az storage account keys list --resource-group "$RG" --account-name "$STORAGE" --query "[0].value" -o tsv)
  echo "::add-mask::$STORAGE_KEY"
}
# Временна връзка (1 час) към един blob. $1 = blob, $2 = права (r / cw).
# Задава SAS_URL и я маскира в логовете (workflow командите се четат от stdout,
# затова не е в $(...)).
storage_sas_url() {
  local sas
  sas=$(az storage blob generate-sas --account-name "$STORAGE" --account-key "$STORAGE_KEY" --container-name "$APP" \
    --name "$1" --permissions "$2" --https-only --expiry "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%MZ')" -o tsv)
  SAS_URL="https://${STORAGE}.blob.core.windows.net/${APP}/$1?${sas}"
  echo "::add-mask::$sas"
}
storage_delete() {
  az storage blob delete --account-name "$STORAGE" --account-key "$STORAGE_KEY" --container-name "$APP" \
    --name "$1" --only-show-errors --output none 2>/dev/null || true
}
