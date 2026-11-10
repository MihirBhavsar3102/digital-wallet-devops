# digital-wallet-devops

A DevOps assignment: take a ready-made NestJS + React + PostgreSQL wallet app and run it on AWS
with Terraform, a GitHub Actions CI/CD pipeline, and CloudWatch monitoring.

> **Status: work in progress.** The Terraform skeleton, remote state, network, security groups, ECR,
> IAM, compute, the load balancer and the database are in place. The pipeline and monitoring are not written yet.

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
| `secretsmanager:GetSecretValue` | The RDS-managed master user secret only, by its exact ARN |

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

- The RDS instance identifier must be `<name_prefix>-db`, and pre-deploy snapshots must be named
  `<name_prefix>-<anything>`, to match the prod snapshot permission. The [database](#database-rds-postgresql)
  module follows the identifier rule, and names the prod final snapshot `<name_prefix>-final`.
- The instance role reads the database secret by its exact ARN, passed in from the RDS module. RDS
  chooses the secret's name itself (`rds!db-<id>`), so a naming convention could not have worked.
- Instances must carry the tag `environment=<env>` or the deploy role cannot run commands on them.
  Provider `default_tags` are not applied to instances launched by an Auto Scaling group, so the
  [compute module](#compute) sets the tag on the group with propagation. Checked on staging: both
  instances carry `environment=staging` and `Role=app`.
- **Not exercised yet:** the `ssm:resourceTag/environment` condition. The tag it needs is in place,
  but the condition is only tested once the pipeline runs `ssm:SendCommand` as the deploy role.

## Compute

`infra/modules/compute/` runs the application on EC2 instances in an Auto Scaling group, spread over
both private-app subnets (one per AZ). The instances have no public IP address. Traffic reaches them
through the [load balancer](#load-balancer-alb).

### Instances

- **Image:** the latest Ubuntu LTS (26.04), looked up with an `aws_ami` data source. The owner is
  Canonical's account ID, `099720109477`, taken from Ubuntu's AWS documentation, and the name filter is
  `ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*`.
- **Type:** the `instance_type` variable, `t3.small` in both environments. It must be an x86_64 family,
  because the image is amd64, and validation rejects Graviton types such as `t4g`.
- **IAM:** the [instance profile](#ec2-instance-role) from the IAM module.
- **IMDSv2 is required** (`http_tokens = "required"`), so the metadata service refuses unauthenticated
  requests. The hop limit is 2, so containers can reach the instance's credentials.
- **Storage:** a 20 GiB gp3 root volume with encryption on.
- **No key pair.** There is no SSH, as described under [security groups](#no-ssh-access-goes-through-ssm).

### First boot

A short `user_data` script runs once per instance and:

1. switches Ubuntu's apt sources to HTTPS (see [Ubuntu package updates over HTTPS](#ubuntu-package-updates-over-https));
2. installs Docker Engine and the Compose plugin from Docker's official apt repository;
3. installs the AWS CLI (used by `deploy.sh` for the ECR login and Secrets Manager) and the CloudWatch
   agent (its configuration is added in the monitoring step);
4. creates `/opt/app/` containing `instance.env` (region, account ID, name prefix) and `deploy.sh`, a copy
   of `scripts/deploy.sh`, which is still a skeleton until the pipeline step;
5. starts a **placeholder** nginx container on ports 80 and 8081, so load balancer health checks pass
   before the first real deploy. Its page shows which instance answered, and `/api` returns 200. The
   image comes from the public ECR mirror of nginx, which avoids Docker Hub's pull rate limits.

`deploy.sh` has to remove the placeholder (`docker rm -f placeholder`) before it starts the real
containers, because both use ports 80 and 8081.

### Auto Scaling group

- Minimum 1, desired 2 and maximum 3 instances.
- Health check type `ELB` with a 300 second grace period, which covers the `user_data` install.
  An instance that fails the load balancer's health check is replaced.
- Rolling instance refresh, keeping at least 50% of capacity healthy. The group references
  `latest_version` of the launch template, so editing the template (including `user_data`) replaces the
  instances one at a time.

### Tags and SSM

Provider `default_tags` are not applied to instances launched by an Auto Scaling group, so the module
reads them with an `aws_default_tags` data source and sets all of them on the group with
`propagate_at_launch`, together with `Name` and `Role=app`. The volumes get the same tags from the
launch template. `Role=app` is what SSM Run Command targets:

```
aws ssm describe-instance-information
aws ssm start-session --target <instance-id>        # needs the Session Manager plugin installed locally
aws ssm send-command --document-name AWS-RunShellScript --targets "Key=tag:Role,Values=app" \
    --parameters 'commands=sudo docker ps'
```

### Checked on staging

Two instances were `InService` in `ap-south-1a` and `ap-south-1b` and both appeared as `Online` managed
nodes in Systems Manager. The SSM agent comes preinstalled on Canonical's AMIs. On both instances:
the placeholder container was running, Docker, Compose, the AWS CLI and the CloudWatch agent were
installed, `deploy.sh` was in place (mode 750, owned by root), an unauthenticated metadata request
returned `401`, no key pair was attached, and the volumes were encrypted gp3.

### Ubuntu package updates over HTTPS

Ubuntu's own apt mirrors are configured with plain `http://` (port 80), but the `app` security group only
allows outbound HTTPS. This was found on staging: from an instance, `http://ap-south-1.ec2.archive.ubuntu.com`
timed out while the same mirror over `https://` returned 200, and the boot log showed Ubuntu's package
indexes failing to download. So `apt` could not fetch Ubuntu's packages and `unattended-upgrades` could not
fetch security updates. Docker's repository, snap, ECR, SSM and CloudWatch were unaffected, because they all
use HTTPS.

`user_data` now rewrites the `URIs:` lines of `/etc/apt/sources.list.d/*.sources` to `https://` before the
first `apt-get update`. The security group stays HTTPS-only, and no port 80 rule is added. A missing or
renamed sources file on a future image does not abort the boot.

The change was tested on a running staging instance by switching a copy of the source files in a throwaway
directory: `apt-get update` fetched 35.8 MB over HTTPS and exited 0, and `postgresql-client` became
visible. It takes effect on instances launched after the launch template change is applied, because the
rolling instance refresh then replaces the running instances one at a time. Instances launched before that
still have the problem.

### Image updates

The AMI lookup uses `most_recent = true`. When Canonical publishes a new image, the next plan shows a
launch template change that rolls the instances onto it. This picks up security fixes without a code
change, but in production it means a plan can contain a replacement nobody wrote.

## Load balancer (ALB)

`infra/modules/alb/` puts an internet-facing Application Load Balancer in the two public subnets, using
the `alb` security group. It is the only public entry point: the instances behind it are private.

- **Invalid header fields are dropped** (`drop_invalid_header_fields`), so malformed headers never reach
  the application.
- **Deletion protection** is the `deletion_protection` variable: off in staging so it can be destroyed to
  save money, on in production.
- The HTTP listener on port 80 forwards to the frontend by default.

### Routing and health checks

| Request | Target group | Instance port | Health check path |
|---------|--------------|---------------|-------------------|
| everything else (default) | `<name_prefix>-fe-tg` (frontend) | 80 | `/` |
| `/api` and `/api/*` (listener rule, priority 10) | `<name_prefix>-be-tg` (backend) | 8081 | `/api` |

- The upstream app already serves everything under `/api`, so the rule forwards without rewriting the path.
- Both are `instance` target groups. A target is healthy after 2 checks, 15 seconds apart, and removed after
  3 failures. Deregistration delay is a short 30 seconds. The Auto Scaling group registers its instances with
  both groups.
- `/api` is the backend's existing route (it returns the "Hello World" greeting). Switch the health check to a
  dedicated `/api/health` once the app has one, using the `backend_health_check_path` variable.
- The frontend and backend ports default to 80 and 8081 here and in the security-groups module. They are not
  linked, so change them in both places.

### Access logs

Access logs go to a dedicated bucket, `<name_prefix>-alb-logs-<account-id>`, under the prefix `alb`:

- **Encryption is SSE-S3 (AES256)**, because load balancer access logs do not support KMS keys.
- All public access is blocked, and logs expire after 30 days (`access_log_retention_days`).
- The bucket policy allows the load balancer log writer, and denies any request not made over TLS. The
  writer is the regional account returned by the `aws_elb_service_account` data source, so no account ID is
  hard-coded. That data source is correct for Mumbai. AWS Regions opened since December 2021 need a
  service principal instead, so check this before moving to a newer region.
- The load balancer test-writes to the bucket when it is created, so the policy is created first.
- Production keeps its logs when the bucket is destroyed, and staging can delete it with its contents.

### Checked on staging

Both target groups showed two healthy targets, and the load balancer's DNS name returned the placeholder
page, alternating between the two instances. `/api` returned `200` with the placeholder body. The listener
rule, the target group settings and the load balancer attributes (invalid headers dropped, access logs
on) matched the configuration. The log bucket had the expected encryption, public access block and
30 day lifecycle rule, and logs were delivered, so the HTTPS-only bucket policy does not block the
log writer.

### HTTP only for now

There is no domain, so there is no ACM certificate, no HTTPS listener and no redirect from 80 to 443. With a
domain, add an ACM certificate, a 443 listener, a redirect on port 80, and a 443 ingress rule on the `alb`
security group. Until then, traffic between clients and the load balancer is not encrypted.

Once the real backend is deployed, its Swagger UI at `/api/docs` will be reachable through the load balancer
too, because the `/api/*` rule forwards it. Consider blocking it in production.

## Database (RDS PostgreSQL)

`infra/modules/rds/` creates one PostgreSQL instance per environment on the private-db subnets (a DB
subnet group across both AZs). It is not publicly accessible, and its `db` security group accepts port 5432
from the `app` group only.

| Setting | Staging | Prod |
|---------|---------|------|
| Engine | PostgreSQL 17 (running 17.9) | PostgreSQL 17 |
| Instance class | `db.t4g.micro` (Graviton) | `db.t4g.micro` |
| Storage | 20 GiB gp3, encrypted | 20 GiB gp3, encrypted |
| Multi-AZ | no | **yes** |
| Backup retention | 1 day | 7 days |
| Deletion protection | no | **yes** |
| Final snapshot on deletion | none | `digital-wallet-prod-final` |

The instance identifier is `<name_prefix>-db`, the database is `digital_wallet` and the master user is
`pgadmin`, as in `app/docker-compose.yml`. Backups run at 21:00-21:30 UTC (02:30 IST) and maintenance at
Sunday 22:00-23:00 UTC (Monday 03:30 IST), kept apart.

### Engine version

The version is pinned to major **17**. The application locks Prisma 6.0.1, which was released before
PostgreSQL 18, and AWS's default for new instances in this region is 18, so leaving the version unset would
have picked 18. With only the major given and automatic minor upgrades on, AWS keeps the instance on the
latest 17.x. The running version is reported as `engine_version_actual`. The first real migration in staging
is the compatibility test.

### Password and secret

`manage_master_user_password = true` makes RDS create the master password in Secrets Manager, so it is never
in the code, in a variable, or in Terraform state. Checked on staging: the state holds `password = null` and
only the secret's ARN, KMS key and status. No `random_password` fallback was needed. Had it been, the password
would be stored in state.

- RDS chooses the secret's name (`rds!db-<id>`), so the instance role reads it by its exact ARN, passed in
  from the module.
- The secret holds only `username` and `password`. The host, port and database name are not in it, so the
  pipeline must build `DATABASE_URL` itself, as
  `postgresql://pgadmin:<url-encoded password>@<endpoint>:5432/digital_wallet?sslmode=require`. Generated
  passwords can contain characters that must be URL-encoded.
- **The password rotates automatically every 7 days** (the provider's documented default). Checked on
  staging: rotation is on, every 7 days. An application that reads the password once and keeps it will fail
  to open new connections after a rotation, until it is restarted or reads the secret again. How the
  pipeline handles this is decided in the pipeline step. Rotation can be turned off with
  `aws_secretsmanager_secret_rotation` and `rotation_enabled = false`.

### TLS and logging

- **TLS is required.** The parameter group sets `rds.force_ssl = 1`. It is already the default on 17 and
  18, but is set explicitly so it stays visible. Checked: a connection with `sslmode=disable` was refused
  (`no pg_hba.conf entry ... no encryption`), and one with `sslmode=require` reported TLS in use. The
  application's connection string must therefore use `sslmode=require` or stricter.
- **Slow queries are logged** with `log_min_duration_statement = 1000` ms (variable `slow_query_threshold_ms`).
  A 2 second `pg_sleep` run from an app instance appeared in the PostgreSQL log as
  `duration: 2011.685 ms`.
- The PostgreSQL and upgrade logs are exported to CloudWatch, into `/aws/rds/instance/<identifier>/postgresql`
  and `/upgrade`. Terraform creates these log groups first, with a 30 day retention
  (`log_retention_days`), because groups created by RDS never expire.
- **Enhanced monitoring** runs every 60 seconds through its own IAM role
  (`AmazonRDSEnhancedMonitoringRole`). **Performance Insights** is on with 7 day retention. The enhanced
  monitoring data goes to the shared `RDSOSMetrics` log group, which has its own 30 day retention.

### A parameter-group quirk

AWS records `rds.force_ssl` as `pending-reboot` with the source `system`, and will not change the apply method
of a default-valued parameter without changing its value. With the provider's default `apply_method` of
`immediate`, every plan showed an in-place change that could never be applied away. The module therefore
declares `apply_method = "pending-reboot"` for that one parameter, which matches what AWS stores and changes
nothing in AWS. The parameter group uses `name_prefix` with `create_before_destroy`, as the provider docs
advise, so a later major version upgrade can replace it.

### Checked on staging

The instance was `available` with the settings above, on the two private-db subnets, with its parameter group
`in-sync`. From an app instance over SSM, the instance role read the secret and `psql` connected as `pgadmin`
to `digital_wallet` over TLS. From the laptop the name resolved to a private address (`10.10.21.112`) and a
connection to port 5432 failed. Both log groups existed with 30 day retention.

Application instances have no `psql` installed. Once the
[apt-over-HTTPS fix](#ubuntu-package-updates-over-https) is applied, `postgresql-client` can be installed
with `apt`. A container works either way:

```
PW=$(aws secretsmanager get-secret-value --secret-id <secret-arn> --query SecretString --output text \
     | python3 -c 'import sys,json; print(json.load(sys.stdin)["password"])')
docker run --rm -e PGPASSWORD="$PW" -e PGSSLMODE=require public.ecr.aws/docker/library/postgres:17-alpine \
    psql -h <endpoint> -U pgadmin -d digital_wallet -c "select version()"
```

### Cost and deletion

In Mumbai (AWS price list, published 2026-10-29) `db.t4g.micro` is $0.021 per hour single-AZ and $0.042 per hour
Multi-AZ, and gp3 storage is $0.131 per GB-month single-AZ and $0.262 Multi-AZ, so 20 GiB is $2.62 or $5.24 a
month. Staging has no deletion protection and no final snapshot, so destroying it deletes the data. Production
needs deletion protection turned off before it can be destroyed.

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
