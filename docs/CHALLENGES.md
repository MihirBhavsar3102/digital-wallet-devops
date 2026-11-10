# Challenges log

One row per problem, written the moment it is solved. Only real problems go here.

| # | When | Step | Symptom (exact error) | Root cause | Fix | Prevention | Time lost |
|---|------|------|-----------------------|------------|-----|------------|-----------|
| 1 | 2026-11-10 | 1.1 terraform plan | `Error: Too many command line arguments` and `Given variables file staging does not exist.` | PowerShell splits an unquoted `-var-file=staging.tfvars` at the dot | Quote the argument: `"-var-file=staging.tfvars"` | Always quote `-var-file` in PowerShell, or use Git Bash | 5 minutes |
