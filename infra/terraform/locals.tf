locals {
  cluster_name                = "${var.project_name}-fargate"
  load_balancer_service_name  = "${var.project_name}-ecs"
  backend_a_service_name      = "${var.project_name}-backend-a-ecs"
  backend_b_service_name      = "${var.project_name}-backend-b-ecs"
  alb_name                    = "${var.project_name}-ecs-alb"
  target_group_name           = substr("${var.project_name}-ecs-tg", 0, 32)
  alb_security_group_name     = "${var.project_name}-ecs-alb-sg"
  load_balancer_security_name = "${var.project_name}-ecs-lb-sg"
  backend_security_group_name = "${var.project_name}-ecs-backend-sg"
  route53_zone_name           = trimsuffix(coalesce(var.route53_zone_name, var.domain_name), ".")
  namespace_name              = coalesce(var.service_discovery_namespace_name, "${var.project_name}.internal")
  execution_role_name         = coalesce(var.execution_role_name, "${var.project_name}-ecs-task-execution-role")
  execution_role_arn          = var.existing_execution_role_arn != null ? var.existing_execution_role_arn : aws_iam_role.ecs_task_execution[0].arn
  certificate_arn             = var.existing_acm_certificate_arn != null ? var.existing_acm_certificate_arn : aws_acm_certificate.site[0].arn
  cloudfront_custom_domain    = var.frontend_hosting_provider == "cloudfront"
  cloudfront_comment          = "${var.project_name}-ecs-frontdoor"
  sns_topic_name              = "${var.project_name}-alerts"
  dashboard_name              = "${var.project_name}-ecs-ops"
  backend_a_dns_name          = "${local.backend_a_service_name}.${local.namespace_name}"
  backend_b_dns_name          = "${local.backend_b_service_name}.${local.namespace_name}"
  load_balancer_backends = join(",", [
    "http://${local.backend_a_dns_name}:${var.container_port}",
    "http://${local.backend_b_dns_name}:${var.container_port}",
  ])

  common_tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "terraform"
    },
    var.tags,
  )

  load_balancer_environment = [
    { name = "STRATEGY", value = var.load_balancer_strategy },
    { name = "PROXY_PREFIX", value = var.proxy_prefix },
    { name = "ENABLE_FRONTEND", value = tostring(var.load_balancer_enable_frontend) },
    { name = "MODE", value = "load_balancer" },
    { name = "BACKENDS", value = local.load_balancer_backends },
    { name = "HEALTH_PATH", value = var.load_balancer_health_path_env },
  ]

  backend_a_environment = [
    { name = "BACKEND_NAME", value = replace(local.backend_a_service_name, "-ecs", "") },
    { name = "STRATEGY", value = var.load_balancer_strategy },
    { name = "PROXY_PREFIX", value = var.proxy_prefix },
    { name = "ENABLE_FRONTEND", value = "false" },
    { name = "MODE", value = "backend_demo" },
    { name = "HEALTH_PATH", value = var.backend_health_path_env },
  ]

  backend_b_environment = [
    { name = "BACKEND_NAME", value = replace(local.backend_b_service_name, "-ecs", "") },
    { name = "STRATEGY", value = var.load_balancer_strategy },
    { name = "PROXY_PREFIX", value = var.proxy_prefix },
    { name = "ENABLE_FRONTEND", value = "false" },
    { name = "MODE", value = "backend_demo" },
    { name = "HEALTH_PATH", value = var.backend_health_path_env },
  ]

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ECS Service CPU Utilization"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.load_balancer.name],
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.backend_a.name],
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.backend_b.name],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ECS Service Memory Utilization"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.load_balancer.name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.backend_a.name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.backend_b.name],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ALB Request Volume and 5xx"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.this.arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, "TargetGroup", aws_lb_target_group.load_balancer.arn_suffix],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ALB Latency and Healthy Hosts"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.this.arn_suffix, "TargetGroup", aws_lb_target_group.load_balancer.arn_suffix, { stat = "p95", label = "TargetResponseTime p95" }],
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.this.arn_suffix, "TargetGroup", aws_lb_target_group.load_balancer.arn_suffix, { stat = "Minimum", label = "HealthyHostCount" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          title  = "CloudFront Edge Requests and Error Rates"
          region = "us-east-1"
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/CloudFront", "Requests", "DistributionId", aws_cloudfront_distribution.frontdoor.id, "Region", "Global", { stat = "Sum" }],
            ["AWS/CloudFront", "4xxErrorRate", "DistributionId", aws_cloudfront_distribution.frontdoor.id, "Region", "Global", { stat = "Average" }],
            ["AWS/CloudFront", "5xxErrorRate", "DistributionId", aws_cloudfront_distribution.frontdoor.id, "Region", "Global", { stat = "Average" }],
            ["AWS/CloudFront", "BytesDownloaded", "DistributionId", aws_cloudfront_distribution.frontdoor.id, "Region", "Global", { stat = "Sum", yAxis = "right" }],
          ]
        }
      },
    ]
  })
}
