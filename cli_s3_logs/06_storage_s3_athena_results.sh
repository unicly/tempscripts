#!/usr/bin/env bash
# 06 — Storage: bucket for Athena query results.
source "$(dirname "$0")/lib.sh"

make_bucket "$STORAGE_PROFILE" "$ATHENA_RESULTS_BUCKET"

log "done: ${ATHENA_RESULTS_BUCKET}"
