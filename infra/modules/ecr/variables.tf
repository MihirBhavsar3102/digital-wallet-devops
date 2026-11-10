variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, <project>-<environment>."
}
variable "keep_last_images" {
  type        = number
  description = "How many images to keep per repository; older ones expire."
  default     = 10
  validation {
    condition     = var.keep_last_images >= 1
    error_message = "keep_last_images must be at least 1."
  }
}
