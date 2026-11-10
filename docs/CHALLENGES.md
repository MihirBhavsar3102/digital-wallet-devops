# Challenges log

One row per problem, written the moment it is solved. Only real problems go here.

| # | When | Step | Symptom (exact error) | Root cause | Fix | Prevention | Time lost |
|---|------|------|-----------------------|------------|-----|------------|-----------|
| 1 | 2026-11-10 | 1.1 terraform plan | `Error: Too many command line arguments` and `Given variables file staging does not exist.` | PowerShell splits an unquoted `-var-file=staging.tfvars` at the dot | Quote the argument: `"-var-file=staging.tfvars"` | Always quote `-var-file` in PowerShell, or use Git Bash | 5 minutes |
| 2 | 2026-11-10 | 1.8 terraform plan | After a clean apply, every plan still showed `module.rds.aws_db_parameter_group.this will be updated in-place` with `apply_method = "pending-reboot" -> null` replaced by `"immediate"` for `rds.force_ssl` | AWS stores the default-valued `rds.force_ssl` as `pending-reboot` (source `system`) and will not change the apply method of a default parameter without changing its value, while the provider's default `apply_method` is `immediate` | Declare `apply_method = "pending-reboot"` on that parameter so the code matches what AWS stores; the plan became `No changes` and nothing changed in AWS | After the first apply, run `terraform plan` once and expect `No changes`; for a parameter AWS reports as `pending-reboot`, set the same apply method in code | ~10 minutes (estimate) |
