provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      project     = var.project
      environment = var.environment
      managed-by  = "terraform"
      owner       = var.owner
    }
  }
}

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# Smoke test: proves credentials + backend work. Delete once real modules exist.
data "aws_caller_identity" "current" {}

# Modules get added here one at a time, bottom-up (network first):
module "network" {
  source             = "../../modules/network"
  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  single_nat_gateway = true # staging: one shared NAT, cheaper but a single point of failure (see README)
}

module "security_groups" {
  source      = "../../modules/security-groups"
  name_prefix = local.name_prefix
  vpc_id      = module.network.vpc_id
}
module "ecr" {
  source      = "../../modules/ecr"
  name_prefix = local.name_prefix
}
