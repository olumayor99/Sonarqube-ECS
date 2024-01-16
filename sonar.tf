provider "aws" {
  region     = local.region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

data "aws_availability_zones" "available" {}

locals {
  region = "us-east-1"
  name   = basename(path.cwd)

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  image          = "sonarqube:8.9-community"
  container_name = "sonarqube"
  container_port = 9000
  sonarqube_user = "sonarqube_user"
  sonarqube_pass = "sonarqube_pass"
  log_group      = "/ecs/sonarqube"
  sonar_db_port  = 5432

  tags = {
    Name    = local.name
    Example = local.name
  }
}

module "ecs_cluster" {
  source  = "terraform-aws-modules/ecs/aws//modules/cluster"
  version = "5.7.4"

  cluster_name = local.name

  # Capacity provider
  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 50
        base   = 20
      }
    }
    FARGATE_SPOT = {
      default_capacity_provider_strategy = {
        weight = 50
      }
    }
  }

  tags = local.tags
}

module "ecs_service" {
  source  = "terraform-aws-modules/ecs/aws//modules/service"
  version = "5.7.4"

  name        = local.name
  cluster_arn = module.ecs_cluster.arn

  cpu    = 1024
  memory = 4096

  # Enables ECS Exec
  enable_execute_command = true

  # Container definition(s)
  container_definitions = {

    (local.container_name) = {
      cpu       = 1024
      memory    = 3072
      essential = true
      image     = local.image
      port_mappings = [
        {
          name          = local.container_name
          containerPort = local.container_port
          hostPort      = local.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "SONARQUBE_JDBC_URL"
          value = "jdbc:postgresql://${aws_db_instance.sonarqube_db.address}:${aws_db_instance.sonarqube_db.port}/sonar"
        },
        {
          name  = "SONARQUBE_JDBC_USERNAME"
          value = "${aws_db_instance.sonarqube_db.username}"
        },
        {
          name  = "SONARQUBE_JDBC_PASSWORD"
          value = "${aws_db_instance.sonarqube_db.password}"
        },
      ]

      command = [
        "-Dsonar.search.javaAdditionalOpts=-Dnode.store.allow_mmap=false"
      ]

      ulimits = [
        {
          name      = "nofile"
          softLimit = 65535
          hardLimit = 65535
        }
      ]

      mount_points = [
        {
          sourceVolume  = "sonarqube-volume"
          containerPath = "/opt/sonarqube/temp/"
          readOnly      = false
        },
        {
          sourceVolume  = "sonarqube-volume"
          containerPath = "/opt/sonarqube/data/"
          readOnly      = false
        },
        {
          sourceVolume  = "sonarqube-volume"
          containerPath = "/opt/sonarqube/extensions/"
          readOnly      = false
        },
        {
          sourceVolume  = "sonarqube-volume"
          containerPath = "/opt/sonarqube/logs/"
          readOnly      = false
        },
      ]

      enable_cloudwatch_logging = false

      log_configuration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.sonarqube.name
          awslogs-region        = local.region
          awslogs-stream-prefix = local.container_name
        }
      }

      linux_parameters = {
        capabilities = {
          drop = [
            "NET_RAW"
          ]
        }
      }

      memory_reservation = 100
    }
  }

  volume = {
    (local.container_name) = {
      name = "sonarqube-volume"
    }
  }

  load_balancer = {
    service = {
      target_group_arn = module.alb.target_groups["ex_ecs"].arn
      container_name   = local.container_name
      container_port   = local.container_port
    }
  }

  subnet_ids = module.vpc.private_subnets
  security_group_rules = {
    alb_ingress_9000 = {
      type                     = "ingress"
      from_port                = local.container_port
      to_port                  = local.container_port
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.alb.security_group_id
    }
    egress_all = {
      type        = "egress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = local.tags
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name = local.name

  load_balancer_type = "application"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  # For example only
  enable_deletion_protection = false

  # Security Group
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      description = "HTTP web traffic"
      cidr_ipv4   = "0.0.0.0/0"
    }
    all_https = {
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      description = "HTTPS web traffic"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  listeners = {
    # ex-http-https-redirect = {
    #   port     = 80
    #   protocol = "HTTP"
    #   redirect = {
    #     port        = "443"
    #     protocol    = "HTTPS"
    #     status_code = "HTTP_301"
    #   }
    # }
    # ex-https = {
    #   port            = 443
    #   protocol        = "HTTPS"
    #   certificate_arn = "arn:aws:iam::123456789012:server-certificate/test_cert-123456789012"

    #   forward = {
    #     target_group_key = "ex_ecs"
    #   }
    # }
    ex-https = {
      port            = 80
      protocol        = "HTTP"
      forward = {
        target_group_key = "ex_ecs"
      }
    }
  }

  target_groups = {
    ex_ecs = {
      backend_protocol                  = "HTTP"
      backend_port                      = local.container_port
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      create_attachment = false
    }
  }

  tags = local.tags
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}

# RDS Postgres database instance
resource "aws_db_instance" "sonarqube_db" {
  identifier             = "${local.name}-db"
  db_name                = "sonar"
  allocated_storage      = 20
  storage_type           = "gp2"
  engine                 = "postgres"
  engine_version         = "16.1"
  instance_class         = "db.t3.micro"
  username               = local.sonarqube_user
  password               = local.sonarqube_pass
  db_subnet_group_name   = aws_db_subnet_group.sonarqube.name
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.rds_db.id]
  multi_az               = false
  storage_encrypted      = true
  kms_key_id             = aws_kms_key.sonar_key.arn
}

resource "aws_db_subnet_group" "sonarqube" {
  name       = "${local.name}-subnet-group"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_cloudwatch_log_group" "sonarqube" {
  name = "/ecs/sonarqube"

  tags = local.tags
}

resource "aws_security_group" "rds_db" {
  name        = "${local.name}-sonar-db-sg"
  description = "Allow traffic to RDS DB only on PostgreSQL port and only coming from ECS SG"
  vpc_id      = module.vpc.vpc_id
  ingress {
    protocol        = "tcp"
    from_port       = local.sonar_db_port
    to_port         = local.sonar_db_port
    security_groups = [module.ecs_service.security_group_id]
  }
  egress {
    protocol    = -1
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_kms_key" "sonar_key" {
  description         = "Sonar Encryption Key"
  is_enabled          = true
  enable_key_rotation = true

  tags = local.tags
}
