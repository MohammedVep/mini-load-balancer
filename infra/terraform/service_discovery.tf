resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = local.namespace_name
  description = "Private namespace for ${var.project_name} ECS services"
  vpc         = var.vpc_id

  tags = local.common_tags
}

resource "aws_service_discovery_service" "backend_a" {
  name = local.backend_a_service_name

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = local.common_tags
}

resource "aws_service_discovery_service" "backend_b" {
  name = local.backend_b_service_name

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = local.common_tags
}
