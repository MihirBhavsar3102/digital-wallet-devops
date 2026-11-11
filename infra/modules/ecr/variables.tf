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

variable "force_delete" {
  type        = bool
  description = "Delete the repositories together with the images they hold when they are destroyed. Without it AWS refuses to delete a repository that still has images, and terraform destroy fails. true in staging so it can be torn down; false in production, where the images are kept."
}
