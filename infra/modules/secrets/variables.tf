variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, <project>-<environment>."
}

variable "recovery_window_in_days" {
  type        = number
  description = "Days Secrets Manager keeps a deleted secret before it is gone for good. 0 deletes immediately (staging); 7 to 30 in production."
  validation {
    condition     = var.recovery_window_in_days == 0 || (var.recovery_window_in_days >= 7 && var.recovery_window_in_days <= 30)
    error_message = "recovery_window_in_days must be 0, or between 7 and 30."
  }
}

variable "secret_version" {
  type        = number
  description = "Version of the generated JWT secret. Increase it to generate and store a new value (this signs out every logged-in user)."
  default     = 1
}
