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
variable "github_environment" {
  type        = string
  description = "Name of the GitHub Environment whose jobs may assume the deploy role. Case-sensitive."
}
variable "ecr_repository_arns" {
  type        = list(string)
  description = "ARNs of the ECR repositories the instances pull from and the pipeline pushes to."
}
variable "db_secret_arn" {
  type        = string
  description = "ARN of the one Secrets Manager secret the instances may read: the master user secret that RDS creates and manages."
}
variable "allow_db_snapshot" {
  type        = bool
  description = "Grant the deploy role rds:CreateDBSnapshot on this environment's database (prod only)."
  default     = false
}
