#!/bin/bash
# Grant the app's service principal access to every downstream resource the
# supervisor passes the caller identity through to. Idempotent and safe to
# re-run. Does NOT use `set -e` so one failed grant doesn't hide the rest —
# each line prints OK or FAIL with the error.
#
# Usage:  bash grant_app_sp.sh
# Config: reads 6-app/grants.env (ENDPOINTS, GENIE_SPACE_IDS, WAREHOUSE_ID,
#         CATALOG, SCHEMA) and app.yaml (SUPERVISOR_ENDPOINT).

HERE="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${PROFILE:-fe-vm-fevm-serverless-stable-rzi4t6}"
APP_NAME="${APP_NAME:-utility-ops-supervisor}"

# shellcheck disable=SC1091
[ -f "$HERE/grants.env" ] && source "$HERE/grants.env"

# Pull the supervisor endpoint from app.yaml and merge into the endpoint list.
SUP=$(grep -A1 SUPERVISOR_ENDPOINT "$HERE/app.yaml" | grep value | sed -E 's/.*"([^"]+)".*/\1/')
ENDPOINTS="$SUP $ENDPOINTS"

# Discover the app's service principal client id.
SP=$(databricks apps get "$APP_NAME" --profile="$PROFILE" --output=json \
     | python3 -c "import json,sys;print(json.load(sys.stdin)['service_principal_client_id'])")
echo "App SP: $SP"

grant_endpoint() {  # $1 = endpoint name
  local name="$1" eid
  eid=$(databricks serving-endpoints get "$name" --profile="$PROFILE" --output=json 2>/dev/null \
        | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])" 2>/dev/null)
  [ -z "$eid" ] && { echo "SKIP endpoint $name (not found)"; return; }
  if databricks api patch "/api/2.0/permissions/serving-endpoints/$eid" --profile="$PROFILE" \
       --json "{\"access_control_list\":[{\"service_principal_name\":\"$SP\",\"permission_level\":\"CAN_QUERY\"}]}" >/dev/null 2>&1
  then echo "OK   CAN_QUERY endpoint $name"; else echo "FAIL CAN_QUERY endpoint $name"; fi
}

# 1. Serving endpoints (supervisor + KA), de-duplicated.
for ep in $(echo "$ENDPOINTS" | tr ' ' '\n' | awk 'NF && !seen[$0]++'); do grant_endpoint "$ep"; done

# 2. Genie spaces.
for sid in $GENIE_SPACE_IDS; do
  if databricks api patch "/api/2.0/permissions/genie/$sid" --profile="$PROFILE" \
       --json "{\"access_control_list\":[{\"service_principal_name\":\"$SP\",\"permission_level\":\"CAN_RUN\"}]}" >/dev/null 2>&1
  then echo "OK   CAN_RUN genie $sid"; else echo "FAIL CAN_RUN genie $sid"; fi
done

# 3. SQL warehouse.
if [ -n "$WAREHOUSE_ID" ]; then
  if databricks api patch "/api/2.0/permissions/warehouses/$WAREHOUSE_ID" --profile="$PROFILE" \
       --json "{\"access_control_list\":[{\"service_principal_name\":\"$SP\",\"permission_level\":\"CAN_USE\"}]}" >/dev/null 2>&1
  then echo "OK   CAN_USE warehouse $WAREHOUSE_ID"; else echo "FAIL CAN_USE warehouse $WAREHOUSE_ID"; fi
fi

# 4. Unity Catalog data access (SELECT on schema cascades to all tables + metric views).
if [ -n "$CATALOG" ]; then
  if databricks api patch "/api/2.1/unity-catalog/permissions/catalog/$CATALOG" --profile="$PROFILE" \
       --json "{\"changes\":[{\"principal\":\"$SP\",\"add\":[\"USE_CATALOG\",\"USE_SCHEMA\",\"SELECT\",\"READ_VOLUME\",\"EXECUTE\"]}]}" >/dev/null 2>&1
  then echo "OK   UC grants on catalog $CATALOG"; else echo "FAIL UC grants on catalog $CATALOG"; fi
  if [ -n "$SCHEMA" ]; then
    if databricks api patch "/api/2.1/unity-catalog/permissions/schema/$CATALOG.$SCHEMA" --profile="$PROFILE" \
         --json "{\"changes\":[{\"principal\":\"$SP\",\"add\":[\"USE_SCHEMA\",\"SELECT\",\"READ_VOLUME\",\"EXECUTE\"]}]}" >/dev/null 2>&1
    then echo "OK   UC grants on schema $CATALOG.$SCHEMA"; else echo "FAIL UC grants on schema $CATALOG.$SCHEMA"; fi
  fi
fi

echo "Grants complete for app SP $SP"
