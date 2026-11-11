variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, <project>-<environment>."
}
variable "environment" {
  type        = string
  description = "Environment name. Instances must carry the tag environment=<this value>."
}
variable "github_repository" {
  type        = string
  description = "GitHub repository allowed to deploy, as OWNER/REPO."
  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must look like OWNER/REPO."
  }
}
variable "github_owner_id" {
  type        = string
  description = "Numeric id of the GitHub account that owns the repository. GitHub puts it in the token's subject claim."
  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be the numeric id, for example 62109840."
  }
}
variable "github_repository_id" {
  type        = string
  description = "Numeric id of the GitHub repository. GitHub puts it in the token's subject claim."
  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be the numeric id, for example 1451854102."
  }
}
variable "github_environment" {
  type        = string
  description = "Name of the GitHub Environment whose jobs may assume the deploy role. Case-sensitive."
}
variable "image_source_name_prefix" {
  type        = string
  description = "name_prefix of the environment whose images this environment's pipeline promotes, for example digital-wallet-staging for production. The deploy role may then read those two repositories. Empty: none."
  default     = ""
  validation {
    condition     = can(regex("^[a-z0-9-]*$", var.image_source_name_prefix))
    error_message = "image_source_name_prefix must be empty or a name prefix such as digital-wallet-staging."
  }
}
variable "ecr_repository_arns" {
  type        = list(string)
  description = "ARNs of the ECR repositories the instances pull from and the pipeline pushes to."
}
variable "secret_arns" {
  type        = list(string)
  description = "ARNs of the Secrets Manager secrets the instances may read, and nothing else: the RDS-managed database secret and the JWT secret."
}
variable "allow_db_snapshot" {
  type        = bool
  description = "Grant the deploy role rds:CreateDBSnapshot on this environment's database (prod only)."
  default     = false
}
