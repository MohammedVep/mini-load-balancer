output "ecr_repository_url" {
  description = "ECR repository URL for publishing task images."
  value       = aws_ecr_repository.this.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "load_balancer_service_name" {
  description = "ECS service name for the public load balancer task."
  value       = aws_ecs_service.load_balancer.name
}

output "backend_service_names" {
  description = "ECS backend service names."
  value       = [aws_ecs_service.backend_a.name, aws_ecs_service.backend_b.name]
}

output "alb_dns_name" {
  description = "DNS name of the application load balancer."
  value       = aws_lb.this.dns_name
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name."
  value       = aws_cloudfront_distribution.frontdoor.domain_name
}

output "public_url" {
  description = "Primary public URL for the stack."
  value       = "https://${var.domain_name}"
}

output "sns_topic_arn" {
  description = "SNS topic ARN used by CloudWatch alarms."
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name for the stack."
  value       = aws_cloudwatch_dashboard.ops.dashboard_name
}
