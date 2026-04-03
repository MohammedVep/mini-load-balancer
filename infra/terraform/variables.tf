variable "aws_region" {
  description = "AWS region for regional resources such as ECS, ALB, and ECR."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Base name used across AWS resources."
  type        = string
  default     = "mini-load-balancer"
}

variable "domain_name" {
  description = "Public DNS name fronted by CloudFront, for example miniloadbalancer.io."
  type        = string
}

variable "route53_zone_name" {
  description = "Public Route 53 zone name that should contain the domain record. Defaults to domain_name."
  type        = string
  default     = null
}

variable "service_discovery_namespace_name" {
  description = "Private DNS namespace used by ECS backend services. Defaults to <project_name>.internal when null."
  type        = string
  default     = null
}

variable "vpc_id" {
  description = "VPC ID used by the ALB and ECS services."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs used by the ALB and Fargate tasks."
  type        = list(string)
}

variable "container_port" {
  description = "Application port exposed by each container."
  type        = number
  default     = 8080
}

variable "load_balancer_image" {
  description = "Full image URI for the load balancer task definition."
  type        = string
}

variable "backend_image" {
  description = "Full image URI for both backend demo task definitions."
  type        = string
}

variable "load_balancer_cpu" {
  description = "Fargate CPU units for the load balancer task."
  type        = number
  default     = 1024
}

variable "load_balancer_memory" {
  description = "Fargate memory (MiB) for the load balancer task."
  type        = number
  default     = 2048
}

variable "backend_cpu" {
  description = "Fargate CPU units for each backend task."
  type        = number
  default     = 1024
}

variable "backend_memory" {
  description = "Fargate memory (MiB) for each backend task."
  type        = number
  default     = 2048
}

variable "load_balancer_cpu_architecture" {
  description = "CPU architecture for the load balancer task definition."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.load_balancer_cpu_architecture)
    error_message = "load_balancer_cpu_architecture must be X86_64 or ARM64."
  }
}

variable "backend_cpu_architecture" {
  description = "CPU architecture for each backend task definition."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.backend_cpu_architecture)
    error_message = "backend_cpu_architecture must be X86_64 or ARM64."
  }
}

variable "load_balancer_desired_count" {
  description = "Desired number of load balancer tasks."
  type        = number
  default     = 1
}

variable "backend_desired_count" {
  description = "Desired number of tasks per backend service."
  type        = number
  default     = 1
}

variable "assign_public_ip" {
  description = "Whether ECS tasks should receive public IPs. Matches the current production stack."
  type        = bool
  default     = true
}

variable "load_balancer_strategy" {
  description = "Default routing strategy for the load balancer service."
  type        = string
  default     = "weighted"
}

variable "proxy_prefix" {
  description = "Proxy prefix exposed by the load balancer service."
  type        = string
  default     = "/proxy"
}

variable "load_balancer_health_path_env" {
  description = "Health path the load balancer uses when probing upstream backends."
  type        = string
  default     = "/health"
}

variable "backend_health_path_env" {
  description = "Health path exposed by backend demo services."
  type        = string
  default     = "/healthz"
}

variable "target_group_health_path" {
  description = "ALB target group health check path for the load balancer service."
  type        = string
  default     = "/healthz"
}

variable "existing_execution_role_arn" {
  description = "Optional existing ECS task execution role ARN. When null, Terraform creates a dedicated role."
  type        = string
  default     = null
}

variable "execution_role_name" {
  description = "Name for the execution role created by Terraform when existing_execution_role_arn is null."
  type        = string
  default     = null
}

variable "existing_acm_certificate_arn" {
  description = "Optional ACM certificate ARN in us-east-1 for CloudFront. When null, Terraform requests and validates one."
  type        = string
  default     = null
}

variable "cloudfront_price_class" {
  description = "CloudFront price class."
  type        = string
  default     = "PriceClass_100"
}

variable "cloudfront_cache_policy_id" {
  description = "Managed cache policy ID for the default CloudFront cache behavior."
  type        = string
  default     = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
}

variable "cloudfront_origin_request_policy_id" {
  description = "Managed origin request policy ID for the ALB origin."
  type        = string
  default     = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
}

variable "alert_email" {
  description = "Optional email address subscribed to the SNS alarm topic."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention in days for ECS application log groups."
  type        = number
  default     = 7
}

variable "ecr_scan_on_push" {
  description = "Whether to enable ECR enhanced scan-on-push behavior for the repository."
  type        = bool
  default     = false
}

variable "ecr_image_tag_mutability" {
  description = "ECR image tag mutability setting."
  type        = string
  default     = "MUTABLE"
}

variable "ecr_keep_tagged_image_count" {
  description = "How many timestamp-tagged images to keep in ECR."
  type        = number
  default     = 8
}

variable "ecr_untagged_expiry_days" {
  description = "How many days to retain untagged ECR images."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags applied to managed resources."
  type        = map(string)
  default     = {}
}
