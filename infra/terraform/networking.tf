resource "aws_security_group" "alb" {
  name        = local.alb_security_group_name
  description = "Security group for ${var.project_name} ECS ALB"
  vpc_id      = var.vpc_id

  ingress {
    description = "public-http"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = local.alb_security_group_name })
}

resource "aws_security_group" "load_balancer_tasks" {
  name        = local.load_balancer_security_name
  description = "Security group for ${var.project_name} ECS load balancer tasks"
  vpc_id      = var.vpc_id

  ingress {
    description     = "alb-to-lb"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = local.load_balancer_security_name })
}

resource "aws_security_group" "backend_tasks" {
  name        = local.backend_security_group_name
  description = "Security group for ${var.project_name} ECS backends"
  vpc_id      = var.vpc_id

  ingress {
    description     = "lb-to-backends"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer_tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = local.backend_security_group_name })
}

resource "aws_lb" "this" {
  name               = local.alb_name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = merge(local.common_tags, { Name = local.alb_name })
}

resource "aws_lb_target_group" "load_balancer" {
  name        = local.target_group_name
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    path                = var.target_group_health_path
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 10
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(local.common_tags, { Name = local.target_group_name })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.load_balancer.arn
  }
}
