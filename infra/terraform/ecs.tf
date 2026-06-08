resource "aws_cloudwatch_log_group" "load_balancer" {
  name              = "/ecs/${local.load_balancer_service_name}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "backend_a" {
  name              = "/ecs/${local.backend_a_service_name}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "backend_b" {
  name              = "/ecs/${local.backend_b_service_name}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_ecs_cluster" "this" {
  name = local.cluster_name
  tags = local.common_tags
}

resource "aws_ecs_task_definition" "load_balancer" {
  family                   = local.load_balancer_service_name
  cpu                      = tostring(var.load_balancer_cpu)
  memory                   = tostring(var.load_balancer_memory)
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = local.execution_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.load_balancer_cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name           = "app"
      image          = var.load_balancer_image
      essential      = true
      cpu            = 0
      mountPoints    = []
      systemControls = []
      volumesFrom    = []
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = local.load_balancer_environment
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.load_balancer.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = local.load_balancer_service_name
        }
      }
    }
  ])

  tags = local.common_tags
}

resource "aws_ecs_task_definition" "backend_a" {
  family                   = local.backend_a_service_name
  cpu                      = tostring(var.backend_cpu)
  memory                   = tostring(var.backend_memory)
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = local.execution_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.backend_cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name           = "app"
      image          = var.backend_image
      essential      = true
      cpu            = 0
      mountPoints    = []
      systemControls = []
      volumesFrom    = []
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = local.backend_a_environment
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.backend_a.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = local.backend_a_service_name
        }
      }
    }
  ])

  tags = local.common_tags
}

resource "aws_ecs_task_definition" "backend_b" {
  family                   = local.backend_b_service_name
  cpu                      = tostring(var.backend_cpu)
  memory                   = tostring(var.backend_memory)
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = local.execution_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.backend_cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name           = "app"
      image          = var.backend_image
      essential      = true
      cpu            = 0
      mountPoints    = []
      systemControls = []
      volumesFrom    = []
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = local.backend_b_environment
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.backend_b.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = local.backend_b_service_name
        }
      }
    }
  ])

  tags = local.common_tags
}

resource "aws_ecs_service" "backend_a" {
  name            = local.backend_a_service_name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.backend_a.arn
  desired_count   = var.backend_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [aws_security_group.backend_tasks.id]
    assign_public_ip = var.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.backend_a.arn
  }

  tags = local.common_tags
}

resource "aws_ecs_service" "backend_b" {
  name            = local.backend_b_service_name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.backend_b.arn
  desired_count   = var.backend_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [aws_security_group.backend_tasks.id]
    assign_public_ip = var.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.backend_b.arn
  }

  tags = local.common_tags
}

resource "aws_ecs_service" "load_balancer" {
  name                              = local.load_balancer_service_name
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.load_balancer.arn
  desired_count                     = var.load_balancer_desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [aws_security_group.load_balancer_tasks.id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.load_balancer.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  depends_on = [aws_lb_listener.http]

  tags = local.common_tags
}
