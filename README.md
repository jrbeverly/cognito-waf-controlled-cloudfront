# Cognito WAF Controlled CloudFront

> [!WARNING]
> **AI-authored:** This change was autonomously planned and implemented by an AI software factory from a human-authored specification, with possible subsequent human review or modification.

Tests a private S3 site behind CloudFront with a WAF web ACL, a Lambda@Edge cookie gate that signs users in through a Cognito user pool federated to an OIDC provider (a second Cognito pool standing in for an external one), and a scheduled SSM Automation that deletes users whose `custom:last_login` is older than 30 days.

```bash
./deploy.sh
./observe.sh
```

yielding things like:

```
=== unauthenticated CloudFront (expect 302 to Cognito) ===
HTTP/2 302
location: https://cwcf-users-auth.auth.us-east-1.amazoncognito.com/oauth2/authorize?client_id=5ft0mgqfe815ki76018n4sdvos&response_type=code&scope=openid+email+profile&redirect_uri=https%3A%2F%2Fd1jlgs7lcdy3yl.cloudfront.net%2Fcallback

=== WAF XSS block (expect 403) ===
HTTP/2 403

=== security headers ===
x-frame-options: DENY
content-security-policy: default-src 'none'
x-content-type-options: nosniff
strict-transport-security: max-age=31536000; includeSubDomains

=== scripted sign-in as alice (expect 200 on / after the redirects, then 200 with cookies only) ===
200 https://d1jlgs7lcdy3yl.cloudfront.net/
200 cookies only

=== pool users before cleanup ===

stamped ExternalOidc_d4186498-b0b1-7020-6dc4-e84523839470 last_login=0 (stale)

cleanup execution: 2ba5994c-2589-4551-a1dc-67e05c921947
  InProgress
  Success

=== pool users after cleanup ===
```

## Notes

- substantial improvement over previous attempts
- CloudFormation stacks create a useful vending-machine style model
- fully AWS-managed; easier to provision/deploy consistently
- deployments could include an early pre-provisioning step
- possible provisioning hub/config layer populates required stack parameters
- especially useful for wiring deployments into shared auth components
- natural fit with CloudFormation hooks
- hooks could block unsafe patterns; e.g. CloudFront stacks with unauthenticated access in restricted environments
- potentially major win for structural guardrails
- Factory implementation of the core concept was very solid
- some post-generation fixes needed; mainly around making testing flows workable
- overall strong result; core architecture came through well
