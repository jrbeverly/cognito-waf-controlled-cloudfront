#!/bin/bash
set -e
cd "$(dirname "$0")"

REGION=us-east-1
DELIVERY=cwcf-delivery
COGNITO=cwcf-users
CLEANUP=cwcf-cleanup

DOMAIN=$(aws cloudformation describe-stacks --region $REGION --stack-name $DELIVERY \
  --query 'Stacks[0].Outputs[?OutputKey==`DistributionDomain`].OutputValue' --output text)

BUCKET=$(aws cloudformation describe-stacks --region $REGION --stack-name $DELIVERY \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text)

POOL=$(aws cloudformation describe-stacks --region $REGION --stack-name $COGNITO \
  --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' --output text)

echo "=== direct S3 access (expect 403) ==="
curl -si "https://${BUCKET}.s3.${REGION}.amazonaws.com/index.html" | head -1

echo ""
echo "=== unauthenticated CloudFront (expect 302 to Cognito) ==="
curl -si "https://$DOMAIN/" | grep -E '^HTTP/|^location:'

echo ""
echo "=== WAF XSS block (expect 403) ==="
curl -si "https://$DOMAIN/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E" | head -1

echo ""
echo "=== security headers ==="
curl -si "https://$DOMAIN/" | grep -iE 'strict-transport|x-content-type|x-frame|content-security-policy'

echo ""
echo "=== scripted sign-in as alice (expect 200 on / after the redirects, then 200 with cookies only) ==="
JAR=$(mktemp)
PAGE=$(curl -s -L -c $JAR -b $JAR -w '\n%{url_effective}' "https://$DOMAIN/")
LOGIN_URL=$(tail -1 <<<"$PAGE")
CSRF=$(grep -oE 'name="_csrf" value="[^"]+"' <<<"$PAGE" | head -1 | sed -E 's/.*value="([^"]+)"/\1/')
curl -s -L -c $JAR -b $JAR -o /dev/null -w '%{http_code} %{url_effective}\n' \
  --data-urlencode "_csrf=$CSRF" \
  --data-urlencode "username=alice" \
  --data-urlencode "password=Alice-pass-123" \
  --data-urlencode "signInSubmitButton=Sign in" \
  "$LOGIN_URL"
curl -s -b $JAR -o /dev/null -w '%{http_code} cookies only\n' "https://$DOMAIN/"

echo ""
echo "=== pool users before cleanup ==="
aws cognito-idp list-users --region $REGION --user-pool-id $POOL \
  --query 'Users[*].[Username,Attributes[?Name==`custom:last_login`].Value|[0],UserStatus]' \
  --output table

# Stamp the first user as stale so cleanup has something to delete
FIRST_USER=$(aws cognito-idp list-users --region $REGION --user-pool-id $POOL \
  --query 'Users[0].Username' --output text 2>/dev/null)

if [ -n "$FIRST_USER" ] && [ "$FIRST_USER" != "None" ]; then
  aws cognito-idp admin-update-user-attributes --region $REGION \
    --user-pool-id $POOL --username "$FIRST_USER" \
    --user-attributes Name=custom:last_login,Value=0
  echo ""
  echo "stamped $FIRST_USER last_login=0 (stale)"
fi

DOC=$(aws cloudformation describe-stack-resources --region $REGION --stack-name $CLEANUP \
  --query 'StackResources[?LogicalResourceId==`CleanupDocument`].PhysicalResourceId' --output text)

ROLE=$(aws cloudformation describe-stack-resources --region $REGION --stack-name $CLEANUP \
  --query 'StackResources[?LogicalResourceId==`CleanupRole`].PhysicalResourceId' --output text)

ROLE_ARN=$(aws iam get-role --role-name $ROLE --query 'Role.Arn' --output text)

EXEC=$(aws ssm start-automation-execution --region $REGION \
  --document-name $DOC \
  --parameters UserPoolId=$POOL,AutomationAssumeRole=$ROLE_ARN \
  --query 'AutomationExecutionId' --output text)

echo ""
echo "cleanup execution: $EXEC"
for i in $(seq 1 18); do
  STATUS=$(aws ssm get-automation-execution --region $REGION \
    --automation-execution-id $EXEC \
    --query 'AutomationExecution.AutomationExecutionStatus' --output text)
  echo "  $STATUS"
  [ "$STATUS" = "Success" ] || [ "$STATUS" = "Failed" ] && break
  sleep 5
done

echo ""
echo "=== pool users after cleanup ==="
aws cognito-idp list-users --region $REGION --user-pool-id $POOL \
  --query 'Users[*].[Username,Attributes[?Name==`custom:last_login`].Value|[0],UserStatus]' \
  --output table
