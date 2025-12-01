#!/bin/bash
set -e
cd "$(dirname "$0")"

REGION=us-east-1
IDP=cwcf-idp
DELIVERY=cwcf-delivery
COGNITO=cwcf-users
EDGE=cwcf-edge
CLEANUP=cwcf-cleanup

# Stand-in external OIDC provider: a second Cognito pool with one known user
aws cloudformation deploy \
  --region $REGION \
  --stack-name $IDP \
  --template-file idp.yaml

IDP_POOL=$(aws cloudformation describe-stacks --region $REGION --stack-name $IDP \
  --query 'Stacks[0].Outputs[?OutputKey==`IdpPoolId`].OutputValue' --output text)

IDP_CLIENT=$(aws cloudformation describe-stacks --region $REGION --stack-name $IDP \
  --query 'Stacks[0].Outputs[?OutputKey==`IdpClientId`].OutputValue' --output text)

IDP_SECRET=$(aws cognito-idp describe-user-pool-client \
  --region $REGION --user-pool-id $IDP_POOL --client-id $IDP_CLIENT \
  --query 'UserPoolClient.ClientSecret' --output text)

aws cognito-idp admin-set-user-password --region $REGION \
  --user-pool-id $IDP_POOL --username alice --password Alice-pass-123 --permanent

# Pass 1: delivery stack — establishes the CloudFront domain Cognito needs for callback URLs
aws cloudformation deploy \
  --region $REGION \
  --stack-name $DELIVERY \
  --template-file template.yaml

DOMAIN=$(aws cloudformation describe-stacks --region $REGION --stack-name $DELIVERY \
  --query 'Stacks[0].Outputs[?OutputKey==`DistributionDomain`].OutputValue' --output text)

BUCKET=$(aws cloudformation describe-stacks --region $REGION --stack-name $DELIVERY \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text)

aws cloudformation deploy \
  --region $REGION \
  --stack-name $COGNITO \
  --template-file cognito.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    CloudFrontDomain=$DOMAIN \
    OidcIssuerUrl=https://cognito-idp.$REGION.amazonaws.com/$IDP_POOL \
    OidcClientId=$IDP_CLIENT \
    OidcClientSecret=$IDP_SECRET

POOL=$(aws cloudformation describe-stacks --region $REGION --stack-name $COGNITO \
  --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' --output text)

CLIENT=$(aws cloudformation describe-stacks --region $REGION --stack-name $COGNITO \
  --query 'Stacks[0].Outputs[?OutputKey==`AppClientId`].OutputValue' --output text)

HOSTED_UI=$(aws cloudformation describe-stacks --region $REGION --stack-name $COGNITO \
  --query 'Stacks[0].Outputs[?OutputKey==`HostedUiDomain`].OutputValue' --output text)

# Client secret is not a stack output; fetch directly
SECRET=$(aws cognito-idp describe-user-pool-client \
  --region $REGION --user-pool-id $POOL --client-id $CLIENT \
  --query 'UserPoolClient.ClientSecret' --output text)

aws cloudformation deploy \
  --region $REGION \
  --stack-name $EDGE \
  --template-file edge-auth.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    UserPoolId=$POOL \
    ClientId=$CLIENT \
    ClientSecret=$SECRET \
    HostedUiDomain=$HOSTED_UI \
    CloudFrontDomain=$DOMAIN

LAMBDA_ARN=$(aws cloudformation describe-stacks --region $REGION --stack-name $EDGE \
  --query 'Stacks[0].Outputs[?OutputKey==`LambdaVersionArn`].OutputValue' --output text)

# Pass 2: delivery stack — wires the Lambda@Edge ARN into the CloudFront distribution
aws cloudformation deploy \
  --region $REGION \
  --stack-name $DELIVERY \
  --template-file template.yaml \
  --parameter-overrides LambdaEdgeArn=$LAMBDA_ARN

aws cloudformation deploy \
  --region $REGION \
  --stack-name $CLEANUP \
  --template-file cleanup.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides UserPoolId=$POOL

aws s3 cp index.html "s3://$BUCKET/"

echo ""
echo "site: https://$DOMAIN"
echo "user: alice / Alice-pass-123"
