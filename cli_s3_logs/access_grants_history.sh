#!/usr/bin/env bash
# access_grants_history.sh — the AccessGrantsInventory Lambda as a bash script,
# writing to a LOCAL CSV file (nothing is uploaded to S3).
#
# Lists all grants of the S3 Access Grants instance and APPENDS changes to the
# CSV file, with the same logic as lambda/access_grants_history.py:
#
#   grant exists now, not active in the history  -> append a CREATED line
#   grant active in the history, gone now         -> append a DELETED line
#   nothing changed                               -> append nothing
#
# Existing lines are never changed or removed. On the first run (file missing
# or empty) the header line is written first.
#
# Same CSV format as the Lambda (all fields quoted, header on the first line):
#   observed_at, event, grant_id, grant_arn, grantee_type, grantee_identifier,
#   permission, grant_scope, location_id, created_at
#
# Configuration — environment variables (same names as manual_deployment.md
# step 0); if STORAGE_ACCOUNT_ID isn't set, .env next to this script is read:
#   REGION, STORAGE_PROFILE, STORAGE_ACCOUNT_ID
#
# Usage:
#   bash access_grants_history.sh                     # ./access_grants_history.csv
#   bash access_grants_history.sh /path/to/file.csv   # another file
#   DRY_RUN=1 bash access_grants_history.sh           # only show what would be appended
#
# Needs: AWS CLI v2, bash, awk.
# Permissions: s3:ListAccessGrants on the Access Grants instance.
set -euo pipefail

if [ -z "${STORAGE_ACCOUNT_ID:-}" ] && [ -f "$(dirname "$0")/.env" ]; then
  set -a; source "$(dirname "$0")/.env"; set +a
fi
for v in REGION STORAGE_PROFILE STORAGE_ACCOUNT_ID; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v is not set" >&2; exit 1; }
done
case "$STORAGE_ACCOUNT_ID" in *222222222222*) echo "ERROR: set STORAGE_ACCOUNT_ID (or edit .env)" >&2; exit 1;; esac

FILE="${1:-./access_grants_history.csv}"
AWS=(--region "$REGION" --profile "$STORAGE_PROFILE")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
HEADER='"observed_at","event","grant_id","grant_arn","grantee_type","grantee_identifier","permission","grant_scope","location_id","created_at"'

# --- 1. Read the existing history (a missing file = first run) ----------------
if [ -f "$FILE" ]; then tr -d '\r' < "$FILE" > "$TMP/history.lf"; else : > "$TMP/history.lf"; fi

# --- 2. List all current grants (follows NextToken) ---------------------------
# One line per grant, tab-separated, in CSV column order from grant_id on.
: > "$TMP/current.tsv"
token=""
while :; do
  page=(aws s3control list-access-grants --account-id "$STORAGE_ACCOUNT_ID" --max-results 1000 "${AWS[@]}" --output text
        --query '[[NextToken || `"END"`], AccessGrantsList[].[AccessGrantId, AccessGrantArn, Grantee.GranteeType, Grantee.GranteeIdentifier, Permission, GrantScope || `""`, AccessGrantsLocationId || `""`, CreatedAt]][]')
  [ -n "$token" ] && page+=(--next-token "$token")
  "${page[@]}" > "$TMP/page.tsv"
  token=$(head -n 1 "$TMP/page.tsv")
  tail -n +2 "$TMP/page.tsv" >> "$TMP/current.tsv"
  [ "$token" = "END" ] && break
done

# --- 3. Compare and build the new lines ----------------------------------------
# Active grants = grants whose last line in the history is CREATED. The history
# is parsed as written by this script / the Lambda: every field in quotes,
# separated by ","; values (ARNs, IDs, dates) contain no quotes or commas.
NOW=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
awk -v now="$NOW" '
  function q(s) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
  FILENAME == ARGV[1] && FNR > 1 && NF {           # history.lf (skip header)
    line = $0; sub(/^"/, "", line); sub(/"$/, "", line)
    n = split(line, f, /","/)
    if (n >= 10) { last[f[3]] = line; ev[f[3]] = f[2] }
    next
  }
  FILENAME == ARGV[2] && NF {                       # current.tsv
    split($0, g, "\t"); cur[g[1]] = $0; next
  }
  END {
    for (id in cur) if (!(id in ev) || ev[id] != "CREATED") {
      split(cur[id], g, "\t")
      out = q(now) "," q("CREATED")
      for (i = 1; i <= 8; i++) out = out "," q(g[i])
      print "C\t" id "\t" out
    }
    for (id in ev) if (ev[id] == "CREATED" && !(id in cur)) {
      split(last[id], f, /","/)                     # keep the details of the CREATED line
      out = q(now) "," q("DELETED")
      for (i = 3; i <= 10; i++) out = out "," q(f[i])
      print "D\t" id "\t" out
    }
  }' "$TMP/history.lf" "$TMP/current.tsv" | sort -t "$(printf '\t')" -k1,1 -k2,2 > "$TMP/new.tsv"

CURRENT=$(grep -c . "$TMP/current.tsv" || true)
CREATED=$(grep -c '^C' "$TMP/new.tsv" || true)
DELETED=$(grep -c '^D' "$TMP/new.tsv" || true)
APPENDED=$((CREATED + DELETED))

# --- 4. Append to the local file ------------------------------------------------
if [ "$APPENDED" -gt 0 ]; then
  if [ -n "${DRY_RUN:-}" ]; then
    echo "DRY_RUN: would append to ${FILE}:" >&2
    cut -f 3- "$TMP/new.tsv" >&2
  else
    if [ ! -s "$FILE" ]; then
      echo "$HEADER" > "$FILE"                            # new file: header first
    elif [ -n "$(tail -c 1 "$FILE")" ]; then
      echo >> "$FILE"                                     # file didn't end with a newline
    fi
    cut -f 3- "$TMP/new.tsv" >> "$FILE"
  fi
fi

# Same summary as the Lambda
printf '{"current_grants": %d, "appended": %d, "created": %d, "deleted": %d, "file": "%s"}\n' \
  "$CURRENT" "$APPENDED" "$CREATED" "$DELETED" "$FILE"
