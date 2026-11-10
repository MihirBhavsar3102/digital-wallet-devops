variable "project" {
  type        = string
  description = "Project name, first part of every resource name."
  default     = "digital-wallet"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.project))
    error_message = "project must be 2-24 chars: lowercase letters, digits, hyphens, starting with a letter."
  }
}
variable "environment" {
  type        = string
  description = "Deployment environment: staging or prod."
  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be \"staging\" or \"prod\"."
  }
}
variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.aws_region))
    error_message = "aws_region must look like us-east-1 or ap-south-1."
  }
}
variable "owner" {
  type        = string
  description = "Person or team responsible, written to the owner tag."
  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}
variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR block for the VPC, e.g. 10.10.0.0/16."
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && can(regex("^[0-9.]+/[0-9]+$", var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR such as 10.10.0.0/16."
  }
}

variable "github_repository" {
  type        = string
  description = "GitHub repository allowed to deploy to this environment, as OWNER/REPO. Not secret, so it has a default and CI needs no tfvars file."
  default     = "MihirBhavsar3102/digital-wallet-devops"
  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must look like OWNER/REPO."
  }
}

# There is deliberately no database password variable: RDS creates and rotates the master
# password in Secrets Manager (see modules/rds), so it never passes through Terraform input.
# Any variable that does hold a secret must be declared with sensitive = true.