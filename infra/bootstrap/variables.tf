variable "project" {
  type        = string
  description = "Project name, first part of every resource name."
  default     = "digital-wallet"
}
variable "aws_region" {
  type        = string
  description = "Region for the state bucket."
}
variable "owner" {
  type        = string
  description = "Person or team responsible, written to the owner tag."
}

variable "alert_email" {
  type        = string
  sensitive   = true # a personal address: kept out of plan output and logs
  description = "E-mail address that receives the pipeline's failure notices and production deploy announcements. Personal, so it has no default and is not committed: set it in terraform.tfvars (git-ignored) or with -var. AWS sends a confirmation message to it, and nothing is delivered until it is accepted."
  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must look like name@example.com."
  }
}

variable "alarm_email" {
  type        = string
  sensitive   = true # a personal address: kept out of plan output and logs
  description = "E-mail address that receives the CloudWatch alarms of every environment. Personal, so it has no default and is not committed: set it in local.tfvars (git-ignored) and apply with -var-file=local.tfvars, or use -var. It can be the same address as alert_email. AWS sends a confirmation message to it, and nothing is delivered until it is accepted."
  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alarm_email))
    error_message = "alarm_email must look like name@example.com."
  }
}

variable "github_repository" {
  type        = string
  description = "GitHub repository whose workflows may publish to the notification topic, as OWNER/REPO. Not secret, so it has a default."
  default     = "MihirBhavsar3102/digital-wallet-devops"
  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must look like OWNER/REPO."
  }
}

variable "github_owner_id" {
  type        = string
  description = "Numeric id of the GitHub account that owns the repository. Since 15 July 2026 GitHub puts it, and the repository id, in the token subject that the role trusts. Look it up with: gh api repos/OWNER/REPO --jq .owner.id"
  default     = "62109840"
  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be the numeric id."
  }
}

variable "github_repository_id" {
  type        = string
  description = "Numeric id of the GitHub repository (see github_owner_id). A repository that is deleted and recreated gets a new id, so this value has to be updated then. Look it up with: gh api repos/OWNER/REPO --jq .id"
  default     = "1451854102"
  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be the numeric id."
  }
}
