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

- The Go application cross-compiles successfully for `linux/arm64`.
- A multi-architecture image manifest is now published at tag `20260403085539`.
- The live ECS services now run on `ARM64` task definitions:
  - `mini-load-balancer-ecs:3`
  - `mini-load-balancer-backend-a-ecs:3`
  - `mini-load-balancer-backend-b-ecs:3`

### Conclusion

Graviton is worth it for this stack because the implementation cost is low once multi-arch publishing exists, and the live cutover is now complete. The absolute savings are modest, but the platform portability and cost discipline are both strong recruiter signals.

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

### What changed

1. Added a multi-stage Docker build that compiles for the target architecture.
2. Added [build_and_push_multiarch_image.sh](/Users/mohammedvepari/Documents/Mini%20Load%20Balancer-main-clean/scripts/build_and_push_multiarch_image.sh) to publish `linux/amd64` and `linux/arm64` in one manifest.
3. Added Terraform variables so backends and the public load balancer can switch architectures independently.
4. Rolled the backends to ARM first, then rolled the public load balancer after smoke checks.

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

That footprint is active:

- ECS service `ccee-api` is running at `desired=1`, `running=1`, with a public IP.
- ECS service `ccee-worker` is configured with autoscaling from `0` to `10`, `AssignPublicIp=DISABLED`, and no NAT gateway exists in that VPC.
- EventBridge rules `ccee-dlq-replay` and `ccee-dlq-replay-offpeak` launch Fargate tasks in the same subnets with `AssignPublicIp=DISABLED`.

Because the default VPC has no NAT gateways, those private-only tasks depend on the endpoint set for AWS API access.

### Highest-impact next action

Do not delete the `ccee` endpoints until that workload is retired or re-networked. The better savings decision is to review whether `ccee` should keep using the default VPC at all, or whether its private-only jobs should be redesigned around public IPs or a different egress pattern. The current endpoint charges are real, but immediate deletion would break active automation.

## Recommendation Order

1. Leave the current `7`-day retention in place.
2. Add multi-arch image publishing so this stack can move to Graviton.
3. Leave the `ccee` endpoint set alone unless that workload is being intentionally migrated or decommissioned.

## Sources

- AWS Fargate pricing: https://aws.amazon.com/fargate/pricing/
- AWS PrivateLink pricing: https://aws.amazon.com/privatelink/pricing/
- Amazon VPC pricing: https://aws.amazon.com/vpc/pricing/
