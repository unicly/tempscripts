#!/usr/bin/env bash
# 09 — Storage + Feeder: share the Access Grants instance with the Feeder
# account through AWS RAM, and accept the invitation in Feeder.
# Without this, GetDataAccess from Feeder fails with AccessDenied.
# Same AWS Organization? You can share with the org/OU instead (no invitation).
# Do NOT also set a resource policy on the instance — RAM turns that into a
# second share (CREATED_FROM_POLICY).
source "$(dirname "$0")/lib.sh"

SHARE_ARN=$(aws ram get-resource-shares --resource-owner SELF --name "$RAM_SHARE_NAME" \
  --region "$REGION" --profile "$STORAGE_PROFILE" \
  --query "resourceShares[?status=='ACTIVE'].resourceShareArn | [0]" --output text)
if [ -z "$SHARE_ARN" ] || [ "$SHARE_ARN" = "None" ]; then
  log "creating RAM share ${RAM_SHARE_NAME}"
  SHARE_ARN=$(aws ram create-resource-share --region "$REGION" --profile "$STORAGE_PROFILE" \
    --name "$RAM_SHARE_NAME" --allow-external-principals \
    --resource-arns "$AG_INSTANCE_ARN" --principals "$FEEDER_ACCOUNT_ID" \
    --query resourceShare.resourceShareArn --output text)
  sleep 10
else
  log "RAM share exists: ${SHARE_ARN}"
fi

INVITE_ARN=$(aws ram get-resource-share-invitations --region "$REGION" --profile "$FEEDER_PROFILE" \
  --query "resourceShareInvitations[?resourceShareArn=='${SHARE_ARN}' && status=='PENDING'].resourceShareInvitationArn | [0]" \
  --output text)
if [ -n "$INVITE_ARN" ] && [ "$INVITE_ARN" != "None" ]; then
  log "accepting invitation in Feeder"
  aws ram accept-resource-share-invitation --region "$REGION" --profile "$FEEDER_PROFILE" \
    --resource-share-invitation-arn "$INVITE_ARN" >/dev/null
  sleep 10
fi

log "principal association (expect ${FEEDER_ACCOUNT_ID} ASSOCIATED):"
aws ram get-resource-share-associations --association-type PRINCIPAL --resource-share-arns "$SHARE_ARN" \
  --region "$REGION" --profile "$STORAGE_PROFILE" \
  --query 'resourceShareAssociations[].[associatedEntity,status]' --output text

log "done: ${SHARE_ARN}"
