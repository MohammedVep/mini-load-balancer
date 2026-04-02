# Importing The Live Production Stack

This runbook adopts the current live AWS stack into Terraform state without changing the live front door first.

## Scope Of The First Import Pass

Imported into Terraform state:

- ECR repository and lifecycle policy
- ECS cluster, task definitions, services, and log groups
- ALB, target group, listener, and ECS security groups
- Cloud Map namespace and backend service registrations
- CloudFront distribution and Route 53 apex alias records
- SNS topic, CloudWatch dashboard, and CloudWatch alarms

Intentionally left external for the first pass:

- ECS task execution role `ecsTaskExecutionRole`
- ACM certificate `arn:aws:acm:us-east-1:194191749520:certificate/7164b721-640c-4854-ac2b-435aafdbf21b`
- Any SNS email subscription

Those are already working and shared enough that taking ownership of them in the first import pass adds risk without improving production behavior.

## Preconditions

1. Reauthenticate AWS CLI first. The last validation attempt failed because the local AWS session had expired.
2. Use the production account and `us-east-1`.
3. Run this from `infra/terraform`.
4. Do not run `terraform apply` until the import plan and the first post-import plan both look correct.

## Files To Prepare

```bash
cd infra/terraform
cp terraform.prod.tfvars.example terraform.prod.tfvars
cp imports.prod.tf.example imports.prod.tf
terraform init
```

## Import Workflow

1. Dry-run the import plan:

```bash
terraform plan -var-file=terraform.prod.tfvars
```

2. If the plan shows only imports plus expected config alignment changes, execute the import:

```bash
terraform apply -var-file=terraform.prod.tfvars
```

3. Remove the import blocks after the import succeeds:

```bash
rm imports.prod.tf
```

4. Run a normal plan to see remaining drift:

```bash
terraform plan -var-file=terraform.prod.tfvars
```

## Expected First-Plan Changes After Import

Some drift is expected on the first normal plan after the import because Terraform now models details that were created imperatively:

- `ManagedBy=terraform` and `Project=mini-load-balancer` tags may be added to imported resources
- ECS services may show task definition normalization if a newer revision is registered later outside Terraform
- CloudFront and dashboard JSON can show minor normalization differences even when behavior matches

The config already includes the two biggest import-alignment fixes:

- ECS task definitions now declare `runtime_platform` for Linux `X86_64`
- The ALB listener models both `target_group_arn` and the nested `forward` block

The load balancer ECS service also models the existing `health_check_grace_period_seconds = 60` so Terraform does not try to rewrite it after import.

## Live Resource IDs Encoded In `imports.prod.tf.example`

- ECS cluster: `mini-load-balancer-fargate`
- ALB: `arn:aws:elasticloadbalancing:us-east-1:194191749520:loadbalancer/app/mini-load-balancer-ecs-alb/fd311a2cab94d122`
- Target group: `arn:aws:elasticloadbalancing:us-east-1:194191749520:targetgroup/mini-load-balancer-ecs-tg/e699156c6846f539`
- Listener: `arn:aws:elasticloadbalancing:us-east-1:194191749520:listener/app/mini-load-balancer-ecs-alb/fd311a2cab94d122/6f29cc3e1284fa2d`
- CloudFront distribution: `E1BF6B0VQTLRKS`
- Hosted zone: `Z0393609T8LQ897NYPHK`
- Cloud Map namespace: `ns-ds56tjw5q5vn2m4q`

## Verification After Apply

Re-run smoke tests against the live front door:

```bash
curl -fsS https://miniloadbalancer.io/healthz
curl -fsS https://miniloadbalancer.io/metrics >/dev/null
curl -fsS https://miniloadbalancer.io/admin/backends
curl -fsS https://miniloadbalancer.io/proxy/whoami
```

Then confirm Terraform sees no unexpected destructive change:

```bash
terraform plan -var-file=terraform.prod.tfvars
```
