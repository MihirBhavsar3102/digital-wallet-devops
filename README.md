# digital-wallet-devops

A DevOps assignment: take a ready-made NestJS + React + PostgreSQL wallet app and run it on AWS
with Terraform, a GitHub Actions CI/CD pipeline, and CloudWatch monitoring.

> **Status: work in progress.** The Terraform skeleton, remote state, network, security groups, ECR
> and IAM are in place. The database, compute, load balancer, pipeline and monitoring are not written yet.

## Terraform state

Each environment keeps its state in one S3 bucket, `digital-wallet-shared-tfstate-<account-id>`,
under its own key (`staging/terraform.tfstate`, `prod/terraform.tfstate`). The bucket has
versioning, AES256 encryption, all public access blocked, a policy denying non-TLS requests,
and `prevent_destroy`. Locking uses S3's native lock file (`use_lockfile = true`, Terraform >= 1.10).
No DynamoDB table is needed, as that method is deprecated in the current docs.

### The chicken-and-egg step

A Terraform backend bucket must exist before an environment can use it, but Terraform needs
somewhere to store state to create that bucket. `infra/bootstrap/` breaks the loop: it uses
**local** state and is applied by hand, once. Its `terraform.tfstate` is git-ignored. Bootstrap also
creates the account-wide GitHub OIDC identity provider (see
[Identity and access](#identity-and-access-iam)), because that provider is one per account and
must outlive any single environment.

### Limitations

- Bootstrap state exists only on the machine that applied it. If lost, the bucket and the OIDC
  provider must be re-imported (`terraform import`) before bootstrap can be managed again. No locking
  or versioning protects it.
- Only one person or machine can safely run bootstrap.
- `prevent_destroy` means destroying the bucket needs a deliberate code change first.
- The AWS account ID appears in each `backend.tf` because backend blocks cannot use variables.

## Network

`infra/modules/network/` builds one VPC per environment, spread over two Availability Zones (the
first two available in the region, `ap-south-1a` and `ap-south-1b`). The VPC CIDR is a variable
(`10.10.0.0/16` for staging, `10.20.0.0/16` for prod). DNS support and DNS hostnames are on.
`cidrsubnet()` carves six /24 subnets in three tiers, leaving gaps between the tiers for later growth:

| Tier | Holds | Staging AZ-a / AZ-b | Prod AZ-a / AZ-b |
|------|-------|---------------------|------------------|
| public | ALB, NAT gateways | `10.10.0.0/24`, `10.10.1.0/24` | `10.20.0.0/24`, `10.20.1.0/24` |
| private-app | EC2 | `10.10.10.0/24`, `10.10.11.0/24` | `10.20.10.0/24`, `10.20.11.0/24` |
| private-db | RDS | `10.10.20.0/24`, `10.10.21.0/24` | `10.20.20.0/24`, `10.20.21.0/24` |

Routing, which is what makes the tiers different:

| Route table | Associated subnets | Default route (`0.0.0.0/0`) |
|-------------|--------------------|-----------------------------|
| public (one) | both public | Internet gateway |
| private-app (one per AZ) | one private-app each | NAT gateway |
| private-db (one, shared) | both private-db | **none**: the database has no path to the internet |

The db route table is declared with `route = []`, so Terraform also removes any route someone adds
to it by hand. Staging builds 24 resources and prod builds 26.

### NAT gateway: one in staging, one per AZ in prod

The `single_nat_gateway` variable switches between the two layouts. Each environment sets it in its own
`main.tf`.

- **Staging (`true`)**: one NAT gateway and one Elastic IP, in the AZ-a public subnet. Both private-app
  route tables point at it. This is the cheaper option, but it is a **single point of failure**: if
  AZ-a goes down, instances in both AZs lose outbound internet access. Traffic from AZ-b also crosses
  AZs to reach the NAT gateway, which AWS bills for. This trade-off is accepted for staging.
- **Prod (`false`)**: one NAT gateway and Elastic IP per AZ, and each private-app route table uses the
  NAT gateway in its own AZ, so one AZ failing does not cut off the other.

NAT gateways and Elastic IPs are billed for every hour they exist.

### VPC endpoints

An S3 **gateway** endpoint is attached to the private-app route tables. It is free, and ECR image
layers are served from S3, so image pulls bypass the NAT gateway. Interface endpoints for ECR and
SSM are deliberately not created: in Mumbai an interface endpoint costs $0.013 per hour plus
$0.01 per GB (AWS price list, published 2026-11-05), roughly $95 a month for five endpoints across
two AZs, and they are not needed on the happy path.

## Security groups

`infra/modules/security-groups/` creates one security group per tier. Traffic can only flow
`internet -> alb -> app -> db`:

| Group | Inbound | Outbound | Why |
|-------|---------|----------|-----|
| `alb` | TCP 80 from `0.0.0.0/0` (443 is added when HTTPS is) | Only to the `app` group on the app ports | The single public entry point |
| `app` | Frontend and backend ports from the `alb` group only | 443 to the internet through NAT (ECR, SSM, CloudWatch, Secrets Manager); 5432 to the `db` group | No public ingress and no SSH |
| `db` | TCP 5432 from the `app` group only | None | Database reachable only from the app tier |

- **Groups are referenced by ID, not by CIDR.** Only two rules use a CIDR: the public HTTP rule on
  `alb`, and the HTTPS-out rule on `app`, whose destination is the internet and so has no group ID.
- **Every rule has a description**, and each rule is its own resource
  (`aws_vpc_security_group_ingress_rule` / `_egress_rule`) instead of an inline block, so diffs stay
  readable. Separate rule resources also avoid a dependency cycle between groups that reference each
  other. A staging check found 8 rules across the three groups, none without a description.
- **The `db` group has no egress rule at all.** Terraform removes the allow-all egress rule that AWS
  adds to new groups, and none is added back.
- The frontend port defaults to 80 and the backend port to 8081, as in `app/docker-compose.yml`.
  Both are module variables.

### No SSH: access goes through SSM

**No security group opens port 22, and the instances have no key pairs for SSH.** Shell access and
deployments go through AWS Systems Manager: Session Manager for an interactive shell and Run Command
for deploys. Instances reach Systems Manager through the NAT gateway using the outbound HTTPS rule
on the `app` group, and authenticate with their IAM instance profile. Nothing needs to be reachable
from the internet to administer them.

## Container registry (ECR)

`infra/modules/ecr/` creates two repositories per environment, named
`digital-wallet-<env>-frontend` and `digital-wallet-<env>-backend`.

- **Immutable tags.** A tag can never be overwritten, so a tag that was deployed always means the
  same image. The pipeline therefore has to push a unique tag per build, such as the git commit SHA.
  Pushing `latest` a second time is rejected.
- **Scan on push** is enabled.
- **Encryption** is AES256, the ECR default, at no extra cost. KMS was not used, to avoid per-key cost
  and key management.
- **Lifecycle policy:** keeps the last 10 images in each repository (the `keep_last_images` module
  variable) and expires older ones.

## Identity and access (IAM)

`infra/modules/iam/` creates two roles per environment: one for the EC2 instances and one for the
GitHub Actions pipeline.

### EC2 instance role

Attached to the instances through the instance profile `<name_prefix>-ec2-profile`. It is least
privilege, with no wildcard on anything that supports resource-level permissions:

| Permission | Scope |
|------------|-------|
| `AmazonSSMManagedInstanceCore` (AWS-managed) | Session Manager and Run Command, which replace SSH |
| `CloudWatchAgentServerPolicy` (AWS-managed) | CloudWatch agent metrics and logs |
| ECR pull: `BatchGetImage`, `GetDownloadUrlForLayer`, `BatchCheckLayerAvailability` | This environment's two repositories only |
| `ecr:GetAuthorizationToken` | `*`, because AWS does not support scoping this action to a resource |
| `secretsmanager:GetSecretValue` | The one database secret, `<name_prefix>-db-credentials`, only |

### GitHub Actions deploy roles (OIDC)

The GitHub OIDC identity provider for `token.actions.githubusercontent.com` is created once, in
`infra/bootstrap/`. An account can have only one provider per URL and both environments share an
account, so it cannot live in an environment: destroying staging to save money would otherwise break
the production pipeline's login.

Each environment has its own role, `<name_prefix>-github-deploy`:

| Permission | Scope |
|------------|-------|
| ECR push: `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage` | This environment's two repositories only |
| `ssm:SendCommand` | The `AWS-RunShellScript` document, and only instances tagged `environment=<env>` |
| `ssm:GetCommandInvocation` | `*`, to read command results |
| `rds:CreateDBSnapshot` (**prod only**) | The production database and snapshots named `digital-wallet-prod-*` |

Each trust policy checks two claims in the GitHub token: the audience must be `sts.amazonaws.com`, and
the subject must be exactly `repo:MihirBhavsar3102/digital-wallet-devops:environment:<env>`. In practice:

- The GitHub Environments must be named exactly `staging` and `prod` (the match is case-sensitive).
- A workflow job must declare `environment: <env>` and `permissions: id-token: write`.
- A job from another repository, a fork, or a job with no environment produces a different subject
  and is refused. Production can also require a reviewer's approval on its GitHub Environment.

#### Why no AWS access keys live in GitHub

The pipeline never holds a stored credential. For each run, GitHub issues a short-lived, signed token
describing that run (repository and environment). AWS verifies the signature against the OIDC provider,
checks the claims against the role's trust policy, and returns temporary credentials that expire
after about an hour. There is no long-lived key to leak, rotate or revoke, and a stolen token is
useless to anyone but a job from this repository and environment.

### Conventions that later steps must follow

- The database secret must be named `<name_prefix>-db-credentials`. The policy matches its ARN as
  that name plus `-??????`, because Secrets Manager adds a hyphen and six random characters.
- The RDS instance identifier must be `<name_prefix>-db`, and pre-deploy snapshots must be named
  `<name_prefix>-<anything>`, to match the prod snapshot permission.
- Instances must carry the tag `environment=<env>` or the deploy role cannot run commands on them.
  Provider `default_tags` are not applied to instances launched by an Auto Scaling group, so the tag has
  to be set on the launch template or the group.
- **Not exercised yet:** the secret ARN pattern and the `ssm:resourceTag/environment` condition are
  tested once the RDS and compute steps create a real secret and instances.

## Repo layout

| Path | Purpose |
|------|---------|
| `app/` | The sample application (imported unmodified, then changed in later commits) |
| `infra/bootstrap/` | One-off Terraform that creates the remote-state bucket and the account-wide GitHub OIDC provider |
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
