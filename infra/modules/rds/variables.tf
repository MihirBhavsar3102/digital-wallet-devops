variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, <project>-<environment>."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private-db subnet IDs, one per AZ, for the DB subnet group."
}

variable "security_group_id" {
  type        = string
  description = "ID of the database security group."
}

variable "engine_version" {
  type        = string
  description = "PostgreSQL version. A major-only value such as 17 lets AWS apply minor upgrades; the running version is reported by engine_version_actual."
  default     = "17"
  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?$", var.engine_version))
    error_message = "engine_version must look like 17 or 17.11."
  }
}

variable "instance_class" {
  type        = string
  description = "DB instance class, for example db.t4g.micro."
  default     = "db.t4g.micro"
  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.[a-z0-9]+$", var.instance_class))
    error_message = "instance_class must look like db.t4g.micro."
  }
}

variable "allocated_storage" {
  type        = number
  description = "Storage in GiB (gp3)."
  default     = 20
}

variable "db_name" {
  type        = string
  description = "Name of the initial database."
  default     = "digital_wallet"
}

variable "master_username" {
  type        = string
  description = "Master user name. The password is created and rotated by RDS in Secrets Manager."
  default     = "pgadmin"
}

variable "multi_az" {
  type        = bool
  description = "Run a standby in a second AZ. False in staging, true in production."
}

variable "backup_retention_period" {
  type        = number
  description = "Days to keep automated backups."
  default     = 7
  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 0 and 35."
  }
}

variable "backup_window" {
  type        = string
  description = "Daily backup window in UTC, hh:mm-hh:mm. Must not overlap the maintenance window."
  default     = "21:00-21:30"
  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$", var.backup_window))
    error_message = "backup_window must look like 21:00-21:30."
  }
}

variable "maintenance_window" {
  type        = string
  description = "Weekly maintenance window in UTC, ddd:hh:mm-ddd:hh:mm."
  default     = "sun:22:00-sun:23:00"
  validation {
    condition     = can(regex("^(mon|tue|wed|thu|fri|sat|sun):([01][0-9]|2[0-3]):[0-5][0-9]-(mon|tue|wed|thu|fri|sat|sun):([01][0-9]|2[0-3]):[0-5][0-9]$", var.maintenance_window))
    error_message = "maintenance_window must look like sun:22:00-sun:23:00."
  }
}

variable "deletion_protection" {
  type        = bool
  description = "Block deletion of the instance. On in production."
}

variable "skip_final_snapshot" {
  type        = bool
  description = "Skip the final snapshot on deletion. True in staging; false in production, which snapshots to <name_prefix>-final."
}

variable "slow_query_threshold_ms" {
  type        = number
  description = "Statements slower than this many milliseconds are logged (log_min_duration_statement)."
  default     = 1000
}

variable "log_retention_days" {
  type        = number
  description = "Days to keep the exported PostgreSQL logs in CloudWatch."
  default     = 30
}
