provider "aws" {
  region = var.aws_region

  default_tags {
    # The standard tags come last, so extra_tags can never override them.
    tags = merge(var.extra_tags, {
      project     = var.project
      environment = var.environment
      managed-by  = "terraform"
      owner       = var.owner
    })
  }
}

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# Only used for the account_id output.
data "aws_caller_identity" "current" {}

# This file is identical in every environment. Everything that differs between staging and
# production lives in <env>.tfvars, so there is no per-environment literal below.

module "network" {
  source             = "../../modules/network"
  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
}

module "security_groups" {
  source            = "../../modules/security-groups"
  name_prefix       = local.name_prefix
  vpc_id            = module.network.vpc_id
  alb_ingress_cidrs = var.alb_ingress_cidrs
  frontend_port     = var.frontend_port
  backend_port      = var.backend_port
}

module "ecr" {
  source       = "../../modules/ecr"
  name_prefix  = local.name_prefix
  force_delete = !var.deletion_protection # staging deletes its images with the repositories; production keeps them
}

module "rds" {
  source                  = "../../modules/rds"
  name_prefix             = local.name_prefix
  subnet_ids              = module.network.private_db_subnet_ids
  security_group_id       = module.security_groups.db_security_group_id
  engine_version          = var.db_engine_version
  instance_class          = var.db_instance_class
  allocated_storage       = var.db_allocated_storage
  db_name                 = var.db_name
  multi_az                = var.db_multi_az
  backup_retention_period = var.db_backup_retention_period
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = !var.deletion_protection # a final snapshot is taken only when protection is on
  log_retention_days      = var.log_retention_days
}

module "secrets" {
  source                  = "../../modules/secrets"
  name_prefix             = local.name_prefix
  recovery_window_in_days = var.deletion_protection ? 30 : 0
}

module "iam" {
  source                   = "../../modules/iam"
  name_prefix              = local.name_prefix
  environment              = var.environment
  github_repository        = var.github_repository
  github_owner_id          = var.github_owner_id
  github_repository_id     = var.github_repository_id
  github_environment       = coalesce(var.github_environment, var.environment) # the GitHub Environment must have exactly this name
  image_source_name_prefix = var.image_source_name_prefix
  ecr_repository_arns      = values(module.ecr.repository_arns)
  secret_arns              = [module.rds.master_user_secret_arn, module.secrets.jwt_secret_arn]
  allow_db_snapshot        = var.allow_db_snapshot
}

module "alb" {
  source                     = "../../modules/alb"
  name_prefix                = local.name_prefix
  vpc_id                     = module.network.vpc_id
  public_subnet_ids          = module.network.public_subnet_ids
  security_group_id          = module.security_groups.alb_security_group_id
  deletion_protection        = var.deletion_protection
  frontend_port              = var.frontend_port
  backend_port               = var.backend_port
  frontend_health_check_path = var.frontend_health_check_path
  backend_health_check_path  = var.backend_health_check_path
  access_log_retention_days  = var.log_retention_days
}

module "monitoring" {
  source             = "../../modules/monitoring"
  name_prefix        = local.name_prefix
  log_retention_days = var.log_retention_days
}

module "compute" {
  source                = "../../modules/compute"
  name_prefix           = local.name_prefix
  subnet_ids            = module.network.private_app_subnet_ids
  security_group_id     = module.security_groups.app_security_group_id
  instance_profile_name = module.iam.instance_profile_name
  instance_type         = var.instance_type
  min_size              = var.asg_min_size
  desired_capacity      = var.asg_desired_capacity
  max_size              = var.asg_max_size
  frontend_port         = var.frontend_port
  backend_port          = var.backend_port
  target_group_arns     = [module.alb.frontend_target_group_arn, module.alb.backend_target_group_arn]
  db_host               = module.rds.address
  db_port               = module.rds.port
  db_name               = module.rds.db_name
  db_secret_arn         = module.rds.master_user_secret_arn

  cloudwatch_agent_config_parameter = module.monitoring.agent_config_parameter_name
}
