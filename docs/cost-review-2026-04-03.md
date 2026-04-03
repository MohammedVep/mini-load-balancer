# Cost Review - 2026-04-03

This review captures the current cost posture of the `mini-load-balancer` production stack and the highest-value next savings opportunities.

## Implemented

- Reduced ECS application log retention from `14` days to `7` days in Terraform.
- Applied the change to production log groups:
  - `/ecs/mini-load-balancer-ecs`
  - `/ecs/mini-load-balancer-backend-a-ecs`
  - `/ecs/mini-load-balancer-backend-b-ecs`

Current stored log volume is small:

- `/ecs/mini-load-balancer-ecs`: `6,849,171` bytes
- `/ecs/mini-load-balancer-backend-a-ecs`: `157` bytes
- `/ecs/mini-load-balancer-backend-b-ecs`: `158` bytes

This retention cut is valid operational hygiene, but it is not the primary cost lever for this stack.

## Graviton Evaluation

### Current state

- ECS task definitions are pinned to `cpu_architecture = "X86_64"` in [infra/terraform/ecs.tf](/Users/mohammedvepari/Documents/Mini%20Load%20Balancer-main-clean/infra/terraform/ecs.tf).
- The live load balancer image tag `20260308145006` is an OCI image index with only an `amd64` Linux manifest.
- The live backend image tag `20260307143411` is a single-architecture OCI image manifest.
- The Go application itself cross-compiles successfully for `linux/arm64`.

### Conclusion

Graviton is feasible for this stack, but not deployable yet. The blocker is image publication and task-definition configuration, not source compatibility.

### Estimated savings

Using the current right-sized production shape:

- load balancer: `0.5 vCPU / 1 GB`
- backend A: `0.25 vCPU / 0.5 GB`
- backend B: `0.25 vCPU / 0.5 GB`

That totals:

- `1.0 vCPU`
- `2.0 GB` memory

Using AWS Fargate US East (N. Virginia) published rates for a 30-day month:

- Linux/X86: about `$35.55`
- Linux/ARM: about `$28.44`
- projected compute savings: about `$7.11/month` or `20%`

### Required work before ARM cutover

1. Publish multi-architecture images that include `linux/arm64`.
2. Switch Terraform `runtime_platform.cpu_architecture` to `ARM64`.
3. Roll backend services first and smoke test them.
4. Roll the public load balancer service last.

## VPC Endpoint Audit

### What is driving the spend

AWS Cost Explorer for `2026-04-01` through `2026-04-04` shows:

- `USE1-VpcEndpoint-Hours`: `$15.12`
- `USE1-VpcEndpoint-Bytes`: `$0.0025575085`
- `USE1-PublicIPv4:InUseAddress`: `$5.76656527`

This means the VPC spend is dominated by endpoint-hour charges, not endpoint data processing.

### What exists in the account

There are `7` VPC endpoints in `us-east-1`, all in the default VPC `vpc-0ae2e116009b7ccbc` and tagged:

- `Project = ccee`
- `ManagedBy = terraform`

Services:

- `com.amazonaws.us-east-1.s3` (gateway)
- `com.amazonaws.us-east-1.logs`
- `com.amazonaws.us-east-1.ecr.api`
- `com.amazonaws.us-east-1.ecr.dkr`
- `com.amazonaws.us-east-1.ecs`
- `com.amazonaws.us-east-1.monitoring`
- `com.amazonaws.us-east-1.sts`

The live mini-load-balancer production VPC `vpc-01b8820eda6e42933` has `0` VPC endpoints.

### Conclusion

The broader account VPC endpoint spend is not coming from the live mini-load-balancer stack. It is coming from a separate default-VPC footprint tagged `ccee`.

### Highest-impact next action

If `Project=ccee` is not an active workload, deleting those interface endpoints is the strongest remaining cost reduction in the account. AWS PrivateLink pricing bills interface endpoints by hour for each endpoint ENI, while this account is currently showing negligible endpoint-byte charges. That is exactly the profile of idle but still-billable interface endpoints.

## Recommendation Order

1. Leave the current `7`-day retention in place.
2. Treat Graviton as a second-pass optimization after adding multi-arch image publishing.
3. Audit or remove the `ccee` default-VPC interface endpoints before spending more time tuning this stack.

## Sources

- AWS Fargate pricing: https://aws.amazon.com/fargate/pricing/
- AWS PrivateLink pricing: https://aws.amazon.com/privatelink/pricing/
- Amazon VPC pricing: https://aws.amazon.com/vpc/pricing/
