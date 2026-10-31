resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}"
  retention_in_days = 90
}

resource "aws_ecs_cluster" "main" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  skip_destroy             = true # keep old revisions so manual rollback stays possible

  container_definitions = jsonencode([{
    name         = "app"
    image        = "${var.image_repo}:${var.image_tag}" # GitOps: changes when the tag file changes
    essential    = true
    portMappings = [{ containerPort = 8000 }]

    environment = [
      { name = "AWS_REGION", value = var.region },
      { name = "DB_HOST", value = aws_rds_cluster.db.endpoint },
      { name = "DB_NAME", value = "calls" },
      { name = "DB_USER", value = "app_user" },
      { name = "CRM_URL", value = var.crm_url },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name                               = var.name
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.app.arn
  desired_count                      = 2
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30
  wait_for_steady_state              = true # terraform apply fails if the deployment fails

  deployment_circuit_breaker {
    enable   = true
    rollback = true # auto-revert to the last good revision
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.https, null_resource.db_init]

  # autoscaling owns the task count
  lifecycle {
    ignore_changes = [desired_count]
  }
}