variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, for example digital-wallet-staging. The log groups are named /<name_prefix>/<kind>."
}

variable "log_retention_days" {
  type        = number
  description = "Days to keep the application and system logs in CloudWatch."
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs accepts, for example 7, 14, 30 or 90."
  }
}
