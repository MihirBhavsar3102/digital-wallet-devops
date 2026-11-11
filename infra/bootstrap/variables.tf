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