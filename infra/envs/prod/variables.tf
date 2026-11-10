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

# Pattern for secrets, added at the RDS step:
# variable "db_password" {
#   type        = string
#   description = "RDS master password."
#   sensitive   = true
# }