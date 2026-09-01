locals {
  ecs_environments = {
    dev = {
      cpu           = 256
      memory        = 512
      desired_count = 0
    }
    prod = {
      cpu           = 512
      memory        = 1024
      desired_count = 0
    }
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  for_each          = local.ecs_environments
  name              = "/ecs/${local.account_name}-${each.key}"
  retention_in_days = 30

  tags = {
    Name        = "/ecs/${local.account_name}-${each.key}"
    Environment = each.key
  }
}

resource "aws_ssm_parameter" "cloudflared-tunnel-token" {
  for_each = local.cloudflare_tunnels

  name        = "/terrahorse/${each.key}/cloudflared/tunnel-token"
  description = "Cloudflare Tunnel token for the ${each.key} ECS task"
  type        = "SecureString"
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.terrahorse[each.key].token

  tags = {
    Name        = "/terrahorse/${each.key}/cloudflared/tunnel-token"
    Environment = each.key
  }
}


resource "aws_security_group" "ecs" {
  for_each    = local.ecs_environments
  name        = "${local.account_name}-ecs-${each.key}"
  description = "ECS ${each.key} tasks; outbound HTTPS only"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "HTTPS egress"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.account_name}-ecs-${each.key}"
    Environment = each.key
  }
}

resource "aws_ecs_cluster" "main" {
  for_each = local.ecs_environments
  name     = "${local.account_name}-${each.key}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  for_each     = local.ecs_environments
  cluster_name = aws_ecs_cluster.main[each.key].name

  capacity_providers = ["FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
  }
}

# These are stable templates. The application pipeline copies each template,
# replaces its image, and registers the deployable task definition separately.
resource "aws_ecs_task_definition" "template" {
  for_each = local.ecs_environments

  family                   = "${local.account_name}-${each.key}-template"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.ecs-task-execution.arn
  task_role_arn            = aws_iam_role.ecs-task.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "public.ecr.aws/docker/library/node:24.19.0-alpine3.24"
      essential = true
      command   = ["node", "-e", "require('http').createServer((_, response) => response.end('ok')).listen(3000)"]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs[each.key].name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "ecs"
        }
      }

      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
        }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "wget -q -O - http://127.0.0.1:3000/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 20
      }
    },
    {
      name      = "cloudflared"
      image     = "cloudflare/cloudflared:2026.8.2"
      essential = true
      command   = ["tunnel", "--no-autoupdate", "run"]
      dependsOn = [
        {
          containerName = "app"
          condition     = "START"
        }
      ]
      environment = [
        {
          name  = "TUNNEL_METRICS"
          value = "0.0.0.0:2000"
        }
      ]
      secrets = [
        {
          name      = "TUNNEL_TOKEN"
          valueFrom = aws_ssm_parameter.cloudflared-tunnel-token[each.key].arn
        }
      ]
    }
  ])

  tags = {
    Name        = "${local.account_name}-${each.key}-template"
    Environment = each.key
  }
}

resource "aws_ecs_service" "main" {
  for_each = local.ecs_environments

  name            = "${local.account_name}-${each.key}"
  cluster         = aws_ecs_cluster.main[each.key].id
  task_definition = aws_ecs_task_definition.template[each.key].arn
  desired_count   = each.value.desired_count

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
  }

  network_configuration {
    subnets          = values(aws_subnet.dmz)[*].id
    security_groups  = [aws_security_group.ecs[each.key].id]
    assign_public_ip = true
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    # GitHub Actions registers and deploys the rendered task definition.
    ignore_changes = [task_definition]
  }

  tags = merge(
    {
      Name        = "${local.account_name}-${each.key}"
      Environment = each.key
    },
    length([aws_ecs_cluster_capacity_providers.main[each.key].id]) > 0 ? {} : {}
  )
}
