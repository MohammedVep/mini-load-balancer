# Terraform: Mini Load Balancer AWS Stack

This directory contains a first-pass Terraform definition for the current production architecture:

- ECR repository and lifecycle policy
- ECS/Fargate cluster, task definitions, and services
- ALB, target group, listener, and security groups
- Cloud Map private DNS namespace for backend discovery
- ACM, CloudFront, and Route 53 wiring for the public domain
- CloudWatch dashboard and alarms backed by SNS

## What This Stack Assumes

- You already own the public domain in Route 53.
- You already build and push container images to ECR.
- You either let Terraform create a dedicated execution role and ACM certificate, or you pass the existing ARNs for the live stack.

## Files

- `versions.tf`: Terraform and provider constraints
- `variables.tf`: input surface for the stack
- `locals.tf`: derived names, env vars, and dashboard JSON
- `ecr.tf`: repository and lifecycle policy
- `iam.tf`: optional task execution role creation
- `networking.tf`: ALB and security groups
- `service_discovery.tf`: private DNS namespace and backend services
- `ecs.tf`: log groups, cluster, task definitions, and ECS services
- `cloudfront.tf`: ACM, validation records, CloudFront, and public DNS aliases
- `monitoring.tf`: SNS, CloudWatch dashboard, and alarms
- `outputs.tf`: stack outputs
- `terraform.tfvars.example`: starting values aligned with the current production stack

## Quick Start

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
```

Apply when the plan is correct:

```bash
terraform apply
```

## Current Production Adoption

The example variable file is intentionally aligned to the current production names and IDs.

Two safe ways to use this stack:

1. Greenfield: change names and domain values in `terraform.tfvars`, then apply into a new environment.
2. Adoption: keep the production names and import the existing AWS resources into Terraform state before the first apply.

Production adoption files now live here:

- `terraform.prod.tfvars.example`: live production values and external-resource wiring
- `imports.prod.tf.example`: import blocks for the current ECS, ALB, CloudFront, Route 53, Cloud Map, ECR, and CloudWatch resources
- `IMPORT.md`: step-by-step runbook for importing the live stack into Terraform state

This import flow intentionally keeps the existing ECS task execution role and ACM certificate external to the stack for the first adoption pass. That reduces blast radius and avoids replacing working shared resources during the initial state import.

## Remote Backend

This stack supports an S3 backend with DynamoDB state locking.

Tracked files:

- `backend.tf`: enables the S3 backend
- `backend.prod.hcl.example`: production backend settings template

Local-only file:

- `backend.prod.hcl`: copy from the example before running `terraform init`

Migration flow:

```bash
cd infra/terraform
cp backend.prod.hcl.example backend.prod.hcl
terraform init -reconfigure -migrate-state -backend-config=backend.prod.hcl
```

If Terraform cannot read your default `aws login` session for backend auth on a given machine, add an explicit shared profile in the local `backend.prod.hcl` file or run Terraform with `AWS_PROFILE=<profile>`.

## Notes

- CloudFront certificates must live in `us-east-1`; this stack uses a dedicated provider alias for that.
- The ALB origin remains HTTP-only because TLS terminates at CloudFront in the current production design.
- The backend services use Cloud Map A records so the load balancer task can resolve them internally by DNS name.
- The ALB listener models both `target_group_arn` and the nested `forward` block to match AWS import behavior and avoid a permanent diff after import.
