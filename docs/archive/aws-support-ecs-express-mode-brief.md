# AWS Support Brief: ECS Express Mode Migration Failure

Date: 2026-04-01
Account: `194191749520`
Region: `us-east-1`
Project: `mini-load-balancer`

## Summary

We attempted to migrate three Amazon App Runner services to Amazon ECS Express Mode in `us-east-1` and were unable to get any Express service to reach healthy running tasks.

Affected App Runner services:

- `arn:aws:apprunner:us-east-1:194191749520:service/mini-load-balancer-backend-a/f967a656457845f6a33f9aa3ad85199e`
- `arn:aws:apprunner:us-east-1:194191749520:service/mini-load-balancer-backend-b/845e84ec34eb4b149fe55c45be2dfa56`
- `arn:aws:apprunner:us-east-1:194191749520:service/mini-load-balancer/3a9e9bac11a3471d90fbe874379f609e`

The original App Runner services remained healthy during the migration attempts:

- `https://42mtnmhqya.us-east-1.awsapprunner.com/healthz` returned `200`
- `https://42mtnmhqya.us-east-1.awsapprunner.com/proxy/whoami` returned `200`

The failed ECS Express services created during testing were deleted after verification to avoid leaving billable broken resources behind.

## Migration Attempts

We created the required Express Mode IAM roles:

- `ecsTaskExecutionRole`
- `ecsInfrastructureRoleForExpressServices`

We then created ECS Express services in two configurations:

1. On existing cluster `np-lb-cluster-prod`
2. On dedicated cluster `mini-load-balancer-express` with `FARGATE` and `FARGATE_SPOT` capacity providers

We also created a control service with a public image to rule out private ECR image issues:

- Express service name: `ecs-express-default-smoke`
- Image: `public.ecr.aws/nginx/nginx:latest`
- Cluster: `default`

We also verified there is one existing live ECS Express service in the account:

- Service: `ai-system-shared-ai-platform-ecs`
- Cluster: `default`
- Working task size: `256 CPU`, `1024 MiB`
- This service uses the same roles:
  - `ecsTaskExecutionRole`
  - `ecsInfrastructureRoleForExpressServices`

## Observed Behavior

Across all three app services and the public `nginx` control service:

- `aws ecs create-express-gateway-service` succeeded
- `aws ecs describe-express-gateway-service` reported service status `ACTIVE`
- Managed resources such as ALB, target groups, security groups, listener, rule, ACM certificate, log group, and autoscaling resources were created successfully
- `aws ecs describe-services` showed deployments stuck `IN_PROGRESS`
- Services never reached healthy running tasks
- `runningCount` stayed `0`
- Endpoints returned `503 Service Temporarily Unavailable`, or TLS hostname mismatch during provisioning on some generated hostnames

On the `default` cluster retries for the three mini load balancer services:

- `desiredCount` stayed `1`
- service-level `desiredCount` was `1`, but deployment-level `desiredCount` and `requestedTaskCount` were `0`
- `events` were empty
- no tasks were launched at all

On the dedicated cluster attempt, `describe-tasks` showed tasks remaining in `PENDING` with no image pull start time and no application logs.

On the `default` cluster public `nginx` control test, the same failure pattern occurred:

- `desiredCount` was `1`
- `runningCount` stayed `0`
- `pendingCount` stayed `0`
- rollout reason remained `ECS deployment ... in progress`

This suggests the issue is not specific to the project image or application code.

## Diagnostic Evidence

Relevant AWS documentation used during troubleshooting:

- App Runner migration notice: `https://docs.aws.amazon.com/apprunner/latest/dg/apprunner-availability-change.html`
- ECS Express Mode overview: `https://docs.aws.amazon.com/AmazonECS/latest/developerguide/express-service-overview.html`
- ECS Express troubleshooting: `https://docs.aws.amazon.com/AmazonECS/latest/developerguide/express-service-troubleshooting.html`

Troubleshooting steps performed:

- Verified IAM roles existed and had the expected managed policies
- Verified App Runner source images and runtime environment variables
- Verified Fargate service quotas were not exhausted
- Tested with both private ECR images and a public `nginx` image
- Tested on an existing cluster, a dedicated Express cluster, and the `default` cluster
- Reduced task sizes from `1024 CPU / 2048 MiB` to `512 / 1024`, then `256 / 1024`
- Compared behavior against the existing live Express service `ai-system-shared-ai-platform-ecs`
- Cleaned up failed ECS Express services after testing to avoid leaving billable broken resources

Additional concrete signals observed from the existing live Express service during account troubleshooting:

- ECS service events reported `You’ve reached the limit on the number of vCPUs you can run concurrently`
- ECS service events also reported transient ECR connectivity timeouts during failed revisions

These signals suggest at least two contributing factors in this account:

1. Fargate vCPU pressure in `us-east-1`
2. An Express create-service behavior where newly created services can remain at deployment `requestedTaskCount = 0` with no tasks launched, even when a separate Express service in the same account is healthy

## What We Need From AWS Support

Please help identify why ECS Express Mode services in this account and region are not reaching healthy running tasks, even for a public `nginx` control service on the `default` cluster.

Specific questions:

1. Why do Express services report `ACTIVE` while ECS deployments remain `IN_PROGRESS` with `runningCount = 0`?
2. Why do some generated public endpoints present TLS hostname mismatches during provisioning?
3. Why do newly created Express services in this account sometimes remain at deployment `requestedTaskCount = 0` with no events and no tasks launched, while an existing Express service in the same cluster is healthy?
4. Is there an account-level, regional, subnet-level, or service-level prerequisite missing for ECS Express Mode in `us-east-1` for account `194191749520`?
5. Is this a known issue with ECS Express Mode service provisioning, ALB target registration, or default canary behavior for newly created small services?

## Repo Artifacts

Migration automation added during this investigation:

- `scripts/archive/migrations/migrate_apprunner_stack_to_ecs_express.sh`
