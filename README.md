# digital-wallet-devops

A DevOps assignment: take a ready-made NestJS + React + PostgreSQL wallet app and run it on AWS
with Terraform, a GitHub Actions CI/CD pipeline, and CloudWatch monitoring.

> **Status: work in progress.** The Terraform skeleton and remote state are in place. The rest of
> the infrastructure, pipeline and monitoring are not written yet.

## Terraform state

Each environment keeps its state in one S3 bucket, `digital-wallet-shared-tfstate-<account-id>`,
under its own key (`staging/terraform.tfstate`, `prod/terraform.tfstate`). The bucket has
versioning, AES256 encryption, all public access blocked, a policy denying non-TLS requests,
and `prevent_destroy`. Locking uses S3's native lock file (`use_lockfile = true`, Terraform >= 1.10).
No DynamoDB table is needed, as that method is deprecated in the current docs.

### The chicken-and-egg step

A Terraform backend bucket must exist before an environment can use it, but Terraform needs
somewhere to store state to create that bucket. `infra/bootstrap/` breaks the loop: it uses
**local** state and is applied by hand, once. Its `terraform.tfstate` is git-ignored.

### Limitations

- Bootstrap state exists only on the machine that applied it. If lost, the bucket must be re-imported
  (`terraform import`) before bootstrap can be managed again. No locking or versioning protects it.
- Only one person or machine can safely run bootstrap.
- `prevent_destroy` means destroying the bucket needs a deliberate code change first.
- The AWS account ID appears in each `backend.tf` because backend blocks cannot use variables.

## Repo layout

| Path | Purpose |
|------|---------|
| `app/` | The sample application (imported unmodified, then changed in later commits) |
| `infra/bootstrap/` | One-off Terraform that creates the remote-state bucket |
| `infra/modules/` | Reusable Terraform modules |
| `infra/envs/staging/`, `infra/envs/prod/` | One folder per environment, both calling the same modules |
| `.github/workflows/` | GitHub Actions pipelines |
| `scripts/` | Deploy and smoke-test scripts |
| `monitoring/` | CloudWatch agent configuration |
| `docs/` | Challenges log and approach documentation |

## Credits

The application in `app/` is [tedrosdev/digital-wallet](https://github.com/tedrosdev/digital-wallet),
imported at upstream commit `011bd00b2e43aee3c9f955b4bd84b73ac40338b7` (2024-12-23). The first commit
in this repository is that import, with file contents unchanged, so every later commit shows what
was changed on top of it. Its original README is kept at `app/UPSTREAM_README.md`.

Licence note: the upstream README says the project is MIT-licensed and links to a `LICENSE` file, but
no `LICENSE` file exists in the upstream repository, and its `backend/package.json` declares
`"license": "UNLICENSED"`. No licence text has therefore been copied here.
