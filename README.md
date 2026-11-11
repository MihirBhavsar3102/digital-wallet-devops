# digital-wallet-devops

A DevOps assignment: take a ready-made NestJS + React + PostgreSQL wallet app and run it on AWS
with Terraform, a GitHub Actions CI/CD pipeline, and CloudWatch monitoring.

> **Status: work in progress.** The Terraform skeleton, remote state, network, security groups, ECR,
> IAM, compute, the load balancer, the database, the staging/production variables, the quality gates,
> the application images, `deploy.sh`, a first manual deploy, the local compose setup, the integration test
> and the smoke test are in place. The pipeline and monitoring are not written yet.

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

`infra/modules/network/` builds one VPC per environment, spread over two or three Availability Zones
(`az_count`, default 2): the first ones available in the region, `ap-south-1a` and `ap-south-1b` by
default. The VPC CIDR is a variable
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
| `alb` | TCP 80 from the CIDRs in `alb_ingress_cidrs` (default `0.0.0.0/0`; 443 is added when HTTPS is) | Only to the `app` group on the app ports | The single public entry point |
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
- The frontend port defaults to 80 and the backend port to 8081, as in `app/docker-compose.yml`. Each
  environment sets them once, and the same two variables are passed to the security groups, the load
  balancer and the instance placeholder, so they cannot drift apart.

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
- **Deleting a repository that holds images.** AWS refuses to, so without `force_delete` a
  `terraform destroy` stops with an error on the repositories once an image has been pushed. The module takes
  a required `force_delete` variable, and each environment sets it to `!deletion_protection`: staging deletes
  its images together with the repositories, and production keeps them (its repositories must be emptied on
  purpose before they can be destroyed). Staging was changed in place, with no image touched, because
  `terraform destroy` acts on the stored state, so the setting has to be applied before it helps.

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
| `secretsmanager:GetSecretValue` | The RDS-managed database secret and the [JWT secret](#jwt-secret) only, by exact ARN |

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
- The instance role reads two secrets, the database secret and the JWT secret, by exact ARN, passed in
  from the RDS and secrets modules. RDS chooses the database secret's name itself (`rds!db-<id>`), so a
  naming convention could not have worked.
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
  requests. The **hop limit is 1**, so containers cannot reach the metadata service or the instance
  role's credentials. `deploy.sh` runs on the host and passes secrets in as environment variables, so no
  container needs AWS credentials. It was 2 at first; raise it only if a container ever has to call AWS
  with the instance role.
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
5. starts a **placeholder** nginx container on the frontend and backend ports (80 and 8081), so load balancer health checks pass
   before the first real deploy. Its page shows which instance answered, and `/api` returns 200. The
   image comes from the public ECR mirror of nginx, which avoids Docker Hub's pull rate limits.

`deploy.sh` has to remove the placeholder (`docker rm -f placeholder`) before it starts the real
containers, because both use ports 80 and 8081.

### Auto Scaling group

- Minimum, desired and maximum sizes are variables: staging runs 1 / 1 / 2 instances and production
  2 / 2 / 3.
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

The **metadata hop limit of 1** was checked on the replacement instance (EC2 reports hop limit 1 and tokens
required). From the host, a token request returns `200`. From a container on the default bridge network the
same request gets no answer, while the same container on the host network gets `200`, so it is the hop limit
that blocks it. The instance also has no way to read other secrets: `secretsmanager:ListSecrets` and
reading a secret that is not on its list are both `AccessDenied`.

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

The mechanism was first tested on a running staging instance, by switching a copy of the source files in a
throwaway directory. After the change was applied, the rolling instance refresh replaced both staging
instances, and on each new instance:

- the apt sources were `https://`, and the first-boot log had no `Failed to fetch` or `index files failed`
  lines (before the fix it had 10 matching lines) and 49 successful HTTPS fetches from Ubuntu's mirrors;
- `apt-get update` exited 0, and a simulated `apt-get install postgresql-client` resolved from Ubuntu's mirrors;
- `unattended-upgrade --dry-run` fetched the pending security updates;
- the placeholder, Docker, the AWS CLI, the CloudWatch agent and the database connection all still worked.

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

Application instances have no `psql` installed. With the
[apt-over-HTTPS fix](#ubuntu-package-updates-over-https), a simulated `apt-get install postgresql-client`
resolves from Ubuntu's mirrors (it installs client version 18, which can talk to the version 17 server).
A container works either way:

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

## Environments: staging and production

`infra/envs/staging/` and `infra/envs/prod/` call the same modules. Their `main.tf`, `variables.tf`,
`outputs.tf` and `versions.tf` are **byte-identical**, and no module code is copied between them. Checked
with `diff -rq --exclude=.terraform infra/envs/staging infra/envs/prod`, which reports only three
differences:

- `backend.tf`, which differs in one line, the state key (`staging/terraform.tfstate` and `prod/terraform.tfstate`);
- `staging.tfvars` and `prod.tfvars`, which hold every per-environment value.

Everything that makes the environments differ is therefore in two small files, and a reviewer can compare
them side by side:

| Setting | Staging | Prod |
|---------|---------|------|
| VPC CIDR | `10.10.0.0/16` | `10.20.0.0/16` |
| NAT gateways | single, shared | one per AZ |
| RDS Multi-AZ | off | on |
| Backup retention | 1 day | 7 days |
| Deletion protection and final snapshot | off | on (final snapshot `<name_prefix>-final`) |
| App instances (min / desired / max) | 1 / 1 / 2 | 2 / 2 / 3 |
| Log retention | 14 days | 90 days |
| Deploy role may snapshot the database | no | yes |

`deletion_protection` is a single switch. It protects the database and the load balancer, makes the database
take a final snapshot, keeps the access log bucket and the images in the ECR repositories when the
environment is destroyed, and gives the secrets a 30 day recovery window. Turned off, the environment can be
destroyed cleanly.

```
cd infra/envs/staging
terraform init
terraform plan  "-var-file=staging.tfvars"
terraform apply "-var-file=staging.tfvars"
```

(The quotes matter in PowerShell.) Terraform 1.11 or later is required, because the JWT secret uses a
write-only argument.

**Why separate directories and not workspaces.** Workspaces could replace the two folders, but separate
directories are more explicit: each environment has its own state key and its own reviewable values, and
there is no chance of applying to the wrong workspace. The cost is four duplicated files, which the `diff`
above keeps honest.

**The two tfvars files are committed on purpose**, although other `*.tfvars` files are git-ignored. They hold no
secrets: the database password is created by RDS and the JWT secret by Terraform, and neither is ever a
variable. They are what makes the environments differ, and CI needs them. `terraform.tfvars.example` is the
template for a new environment. Anything personal or secret goes in a `local.tfvars`, which git ignores.

### Checked on staging

Applying this change to staging did what the saved plan said (4 to add, 5 to change, 1 to destroy). It
created the JWT secret and the VPC's empty default security group, replaced the instance
role's secrets policy, cut log retention to 14 days, and resized the Auto Scaling group to 1 / 1 / 2. The
rolling refresh then replaced the instances, which took about six minutes. With a single instance the
placeholder app is briefly unavailable during a refresh; that gap was not measured. The database, the load
balancer and the network were not touched.

Afterwards `terraform plan` reported `No changes`, both target groups showed the new instance healthy, and
the load balancer answered with the placeholder page and `200` on `/api`. The database was still `available`,
single-AZ, with 1 day of backups. The variable validation was exercised with six bad values, and each was
refused before any AWS call: `log_retention_days = 10`, a backend port equal to the frontend port, a desired
size above the maximum, `alb_ingress_cidrs = ["not-a-cidr"]`, `instance_type = "t4g.small"`, and an
`extra_tags` map that contains `owner`.

### Destroy and rebuild (step 1.13)

Staging was destroyed with `terraform destroy` and rebuilt with `terraform apply`, to show that the code
is the infrastructure. The rebuild took about **10 to 12 minutes**, timed by hand, most of it creating the
database. Two things follow from a rebuild. The ECR repositories come back empty, so the application has to
be deployed again, and the load balancer gets a new DNS name.

That time was measured before the instances were made to wait for the database (they now read its address
and secret ARN at launch, see [deploy.sh](#deploysh)). Their start no longer overlaps with the database
creation, so a rebuild may take longer. This has not been measured: time the next one again.

### Cost, and running production at staging size

In Mumbai (AWS price list API) a NAT gateway is $0.056 per hour, the load balancer $0.0239, a `t3.small`
instance $0.0224, and `db.t4g.micro` $0.021 single-AZ or $0.042 Multi-AZ. Running 24 hours a day, and
leaving out storage, data processing, load balancer capacity units and logs, that is roughly:

| | Staging | Prod |
|---|---------|------|
| Estimate per month | about $94 (1 NAT and address, load balancer, 1 instance, single-AZ database) | about $170 (2 NATs and addresses, load balancer, 2 instances, Multi-AZ database) |

Production is configured for resilience and is only applied when it is needed, for example for a demo. If
that is too expensive, run it at staging size by setting `single_nat_gateway = true`, `db_multi_az = false` and
`asg_min_size` and `asg_desired_capacity` to 1 in `prod.tfvars`. Nothing else changes, but the resilience
described above is then not in place.

## Variables and outputs

Every variable has a type and a description, and a validation where a mistake is likely: the environment
name, CIDR blocks, instance and database class formats, port ranges (the two ports must differ), the
Auto Scaling sizes (desired between minimum and maximum), and `log_retention_days`, which must be a value
CloudWatch Logs accepts.

- **Set per environment, with no default**, so each environment has to decide: `environment`, `aws_region`,
  `owner`, `vpc_cidr`, `single_nat_gateway`, the three Auto Scaling sizes, `db_multi_az`,
  `db_backup_retention_period`, `deletion_protection`, `allow_db_snapshot` and `log_retention_days`.
- **With a default shared by both**: `project`, `github_repository`, `az_count`, `alb_ingress_cidrs`, the two ports
  and two health check paths, `instance_type`, `db_name`, `db_instance_class`, `db_allocated_storage`,
  `db_engine_version` and `extra_tags`.
- **Tags.** The provider's `default_tags` are the four standard tags (`project`, `environment`, `managed-by`,
  `owner`) plus `extra_tags`. The standard tags are merged last, so `extra_tags` can never override them, and
  validation rejects those keys.
- **No variable holds a secret.** A variable that did would have to be declared `sensitive = true`.

Checked on staging: `terraform output` prints 18 outputs. None is marked sensitive, none looks like a key or a
password, and neither the JWT key nor any database password value appears in the outputs or in the state.

The outputs are the same in both environments and are all descriptions, names and ARNs, never a secret value:
the load balancer DNS name, the VPC ID, the subnet IDs per tier, the three security group IDs, the Auto
Scaling group name, the ECR repository URLs, the database endpoint, the database secret's ARN and the JWT
secret's ARN, the database log group names, the access log bucket, and the GitHub deploy role ARN. The state
bucket's name is an output of `infra/bootstrap/`, where the bucket is created.

Not written yet, because the monitoring module does not exist: the `alarm_email` variable, and the SNS topic
and dashboard outputs. They are added with the monitoring step.

## JWT secret

The backend signs its tokens with a JWT key. `infra/modules/secrets/` creates a Secrets Manager secret,
`<name_prefix>-jwt-secret`, and fills it with a 64 character random value that AWS generates.

- **The value never enters Terraform state or plan output.** It comes from an *ephemeral* resource
  (`aws_secretsmanager_random_password`), which exists only while Terraform runs, and is written through a
  write-only argument (`secret_string_wo`), which Terraform never stores. This needs Terraform 1.11 or later.
  The alternative, `random_password`, would have put the value in state.
- **Rotation is deliberate.** Increase the module's `secret_version` to generate and store a new value. That
  signs out every logged-in user, so it is not automatic.
- **Recovery window:** 30 days with deletion protection on (prod), none otherwise (staging).
- **Reading it:** the instance role can read exactly this secret and the database secret, nothing else. The
  output is its ARN.
- **Checked on staging.** The secret holds a 64 character value in AWS. That value is in neither the Terraform
  state nor the outputs (searched for it directly). The state holds only `has_secret_string_wo = true` for
  the version resource, and `password` is also `null` for the database. The instance role read both
  secrets, and was refused everything else.
- The JWT key in `app/docker-compose.yml` is the upstream project's demo value and is public. It must never be
  used in AWS, and the pipeline step removes it from the compose file.

## Local development and tests

You need Docker and Node 22. Everything below runs from the repository root.

### Run the app locally

```
cp app/.env.example app/.env       # then fill in both values: openssl rand -hex 32
cd app && docker compose up --build
```

The frontend is on <http://localhost:8080> and the backend on <http://localhost:8081/api> (Swagger on
`/api/docs`). Compose starts the database, waits for it to be healthy, runs `prisma migrate deploy` from the
same backend image that AWS uses, and only then starts the backend. It stops with a message if a secret is
missing from `app/.env`, and nothing secret is in the compose file.

- **Changing the password later.** Postgres only reads `POSTGRES_PASSWORD` when its volume is first created,
  so after editing `app/.env` run `docker compose down -v` once (it deletes the local database).
- **Why the local frontend differs from the AWS one.** On AWS the load balancer sends `/api/*` to the backend,
  so the image is built with the relative `/api`. Locally nothing does that, so compose builds the frontend
  with the backend's full URL; the backend's CORS setting allows `http://localhost:8080`. Only the `/api`
  build is ever pushed to ECR. The browser needs port 8080 to be free for the same CORS reason.

### Tests

| Test | Command | Needs |
|------|---------|-------|
| Unit (Jest, no database) | `cd app/backend && npm ci && npm test` | Node |
| Integration (the real app against a real PostgreSQL) | see below | a migrated database |
| Smoke test (a deployed app answers) | `scripts/smoke-test.sh <base-url>` | `curl` |
| `deploy.sh` and `smoke-test.sh` themselves | `docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/deploy.test.sh` (and `smoke-test.test.sh`) | Docker |

**Integration test.** `app/backend/test/wallet.integration-spec.ts` registers two users, logs them in, opens
accounts, deposits and transfers, and checks both balances; it also checks that a transfer larger than the
balance is refused and changes nothing, and that a request without a token gets 401. Nothing is mocked. It has
its own Jest config and script (`npm run test:integration`) and a file pattern the unit tests never match, so
CI can run it as a separate job. It needs `DATABASE_URL` for a database where the migrations have been
applied (`JWT_SECRET_KEY` defaults to a test value):

```
cd app && docker compose up -d db
docker compose exec -T db createdb -U pgadmin digital_wallet_test
cd backend
export DATABASE_URL="postgresql://pgadmin:<POSTGRES_PASSWORD>@localhost:6432/digital_wallet_test"
npx prisma migrate deploy && npm run test:integration
```

The CI job in step 2.2 is meant to run the same two commands against a `postgres:17` service container.

**Smoke test.** `scripts/smoke-test.sh <base-url> [api-base-url]` retries until the frontend serves the app's
page and `/api/health` answers `{"status":"ok"}`. It checks what comes back, not only the status code,
because the first-boot placeholder also answers 200 on `/` and `/api`. Locally:
`scripts/smoke-test.sh http://localhost:8080 http://localhost:8081`.

**Linting the Dockerfiles and scripts** (the checks the CI lint job in step 2.2 is meant to run):
`docker run --rm -i hadolint/hadolint < app/backend/Dockerfile` and
`docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable /mnt/scripts/*.sh /mnt/scripts/tests/*.sh`.

**npm 12.** On a machine with npm 12 (npm blocks dependency install scripts by default), run
`npm run prisma:generate` after `npm ci`. (bcrypt 6 ships its prebuilt binaries inside the package, so it no
longer needs an install script.) The images and CI use Node 22 with npm 10, where Prisma's script runs.

## Application images and deploy

Each instance runs two containers, the backend and the frontend, pulled from ECR. `scripts/deploy.sh`
puts them there. Step 1.14 did it by hand once; the pipeline in Part 2 automates the same steps.

### Images

- **Backend** (`app/backend/Dockerfile`): three stages on one pinned base, `node:22.23.4-bookworm-slim`
  (Node 20 reached end of life in April 2026; Debian rather than Alpine, because Prisma's engines and
  bcrypt's prebuilt binary both target glibc). It runs `node dist/main.js` as the non-root `node` user on
  port 8081, set by `PORT`. Production dependencies are installed on their own and the Prisma client is
  generated after that install.
- **OpenSSL in every stage.** The slim image has no OpenSSL, and Prisma picks its engine binaries by the
  OpenSSL it detects. Without it the build stages baked in `openssl-1.1.x` engines, which do not load once
  OpenSSL 3 is present at runtime. A shared `base` stage installs it, so the engines are
  `debian-openssl-3.0.x` and work with no network.
- **Production start.** `@nestjs/swagger` is a runtime dependency (the app imports it), and
  `tsconfig.build.json` compiles only `src/**`, so the entry point is `dist/main.js`.
- **Frontend** (`app/frontend/Dockerfile`): a Node build stage, then `nginx:1.30.6-alpine` on port 80.
  `VITE_API_BASE_URL` is a build argument that defaults to the relative `/api`, so one image works behind
  any load balancer hostname. nginx falls back to `index.html` for client-side routes and writes a JSON
  access log to stdout. It has no `/api` proxy: the load balancer sends `/api/*` to the backend first.
- **Health route.** `GET /api/health` is public (the global auth guard would otherwise answer 401) and
  returns `{"status":"ok"}`. The backend target group checks it (`backend_health_check_path`).
- **Logs.** The auth guard no longer prints request headers, bearer tokens or the decoded payload, because
  Part 3 sends the logs to CloudWatch.

### deploy.sh

`deploy.sh <tag>` runs on the instance as root (through SSM Run Command). It logs in to ECR, pulls both
images, reads the secrets into its own environment, applies the database migrations from the **new**
backend image, restarts the containers with Docker Compose, and then checks `/api/health` and the frontend
on the instance. Every failure exits non-zero.

- **A failed migration stops the deploy before anything is restarted**, so the running version stays up.
  `prisma migrate deploy` is idempotent, so on the second instance it has nothing to apply. Migrations
  therefore have to work for the old and the new code at once.
- **Secrets never reach the disk.** The database secret is read by ARN and the JWT secret by name. The
  password is percent-encoded into `DATABASE_URL`, and both values reach Compose through the environment
  (`DATABASE_URL:` with no value in the compose file), so a `$` or `#` in a secret cannot corrupt a file.
- **`/opt/app/instance.env`** is written by `user_data` and holds the region, account ID, name prefix, both
  ports and the database host, port, name and secret ARN. The instance role can only read secrets by exact
  ARN and cannot look anything up, and RDS chooses its secret's name, so these are handed over at launch.
  None of them is secret. Applying a change to this file, or to `deploy.sh` (which is embedded in
  `user_data`), replaces the instances once.
- **Safety.** A lock stops two deploys overlapping, the tag is validated, and unused images older than a week
  are pruned, so a rollback to a recent tag is fast.
- **Tests.** `scripts/tests/deploy.test.sh` runs the script against fake `aws`, `docker` and `curl`
  commands (26 checks): the order of the steps, URL-encoding, no secrets on disk, the failed-migration and
  failed-health paths, bad input and the lock. It needs Linux tools, so run it in a container:
  `docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/deploy.test.sh`.

### Manual first deploy (step 1.14)

The images are tagged with the short commit hash (`git rev-parse --short HEAD`). ECR tags are immutable,
so a rebuild of the same commit needs a new tag such as `<hash>-2`. After `terraform apply` had replaced the
instance, the images were pushed and `deploy.sh` was run through
`aws ssm send-command --document-name AWS-RunShellScript`, which is also what the pipeline will do.

### Checked on staging

- The apply changed 3 resources in place (the backend health check path, the launch template and the Auto
  Scaling group) and nothing else. The instance refresh took about six minutes. The new instance had the new
  `instance.env` and `deploy.sh`.
- The first deploy applied all 10 migrations to RDS from the production image over TLS
  (`sslmode=require`) with no certificate error, and finished in under 30 seconds with both images pulled.
- Both target groups reported `healthy`, the backend one on `/api/health`. Through the load balancer, `/`
  and `/api/health` returned 200, `/api/users` without a token returned 401 (the real backend, not the
  placeholder), and a deep link such as `/signup` loaded.
- A user was registered, logged in, given an account, and made a deposit and a transfer, both through the
  API and in a browser. Every browser call went to a relative `/api/...` on the load balancer's host and
  returned 2xx. Balances were exact (1000 + 200 - 300 = 900 in the browser run).
- Re-running the same tag took 9 seconds with no pending migrations. A second tag took 21 seconds, and so did
  the rollback to the first, with the data intact.
- The compose file on the instance contains no password, and nothing under `/opt/app` holds a secret value.

### Open decision: password rotation

RDS rotates the master password every 7 days, and `deploy.sh` reads it at deploy time. A running backend
keeps the password it started with, so after a rotation it cannot open new connections until the next
deploy or restart. Either turn rotation off (`rotation_enabled = false`) or accept and document it as a
known limit. This is not decided yet.

## Repo layout

| Path | Purpose |
|------|---------|
| `app/` | The sample application (imported unmodified, then changed in later commits) |
| `infra/bootstrap/` | One-off Terraform that creates the remote-state bucket and the account-wide GitHub OIDC provider |
| `infra/modules/` | Reusable Terraform modules |
| `infra/envs/staging/`, `infra/envs/prod/` | One folder per environment, both calling the same modules |
| `.github/workflows/` | GitHub Actions pipelines (`ci.yml` for pull requests) |
| `.github/dependabot.yml` | Weekly dependency update pull requests for npm, Docker, GitHub Actions and Terraform |
| `scripts/` | The deploy script, the smoke test, and the tests for both (`scripts/tests/`) |
| `monitoring/` | CloudWatch agent configuration |
| `docs/` | Challenges log and approach documentation |
| `.tflint.hcl`, `.checkov.yaml`, `.pre-commit-config.yaml`, `.gitleaks-baseline.json` | Quality gate configuration (see [Quality gates](#quality-gates)) |

## Quality gates

Four tools check the Terraform and the repository. The pre-commit hooks run `terraform fmt`, tflint and
gitleaks on every commit, and CI runs all of them, with checkov and `terraform validate`, on every pull
request (see [Continuous integration](#continuous-integration-pull-requests)).

| Tool | What it checks | How to run it |
|------|----------------|---------------|
| `terraform fmt` and `terraform validate` | Formatting and valid configuration | `terraform fmt -recursive infra`, then `terraform validate` in each folder |
| **tflint** (AWS ruleset 0.50.0) | Style, deprecated syntax, provider-specific mistakes | `tflint --init` once, then `tflint --chdir infra --recursive` |
| **checkov** | Security misconfigurations | `checkov` from the repository root (settings in `.checkov.yaml`) |
| **gitleaks** | Secrets in the staged changes and in the git history | `gitleaks git --baseline-path .gitleaks-baseline.json` |

Current result: `fmt` clean, `validate` passing in every folder, **tflint 0 issues**, and **checkov 250 checks
passed and 0 failed** (24 distinct checks accepted on purpose, below). Checked on Windows: the three pre-commit hooks
pass, and the gitleaks hook blocks a commit that contains a token (tested with a fake one).

**Pre-commit.** Install once with `pip install pre-commit` and `pre-commit install`. The hooks are
`terraform_fmt`, `terraform_tflint`, and a local gitleaks hook that uses the gitleaks you already have and
scans only the staged changes. It needs `terraform`, `tflint` and `gitleaks` on the PATH.

**What was fixed.** The first checkov run had 36 failures. Three were fixed in code: the metadata hop limit
is now 1, the VPC's default security group is taken over and left empty, and the state bucket expires old
versions after 90 days. tflint's 15 warnings were all one problem, no version constraints in the modules, and
are fixed by a `versions.tf` in every module (loose lower bounds; the environments pin the provider range and
the lock file pins the exact version). The rest are accepted findings. Applied and checked: the state
bucket's lifecycle rule is live (old versions expire after 90 days, delete markers are cleaned up, incomplete
uploads after 7), and the VPC's default security group has no ingress and no egress rules.

### Accepted findings

A finding that is knowingly accepted gets an inline `#checkov:skip=ID:reason` comment next to the resource
and a line here, so the reason is next to the code and also in one list.

| Check | Where | Why it is accepted |
|-------|-------|--------------------|
| `CKV_AWS_2`, `CKV_AWS_103` | ALB HTTP listener | HTTP only until a domain exists to get a certificate for, so there is no TLS policy to set. See [HTTP only for now](#http-only-for-now) |
| `CKV2_AWS_20` | ALB | There is nothing to redirect to without HTTPS |
| `CKV_AWS_378` | both target groups | Traffic from the load balancer to the instances stays inside the VPC |
| `CKV_AWS_260` | `alb_http` security group rule | The load balancer is the public entry point, open to `alb_ingress_cidrs` (the internet by default) |
| `CKV_AWS_260` | `app_frontend_from_alb` rule | False positive: the source is the load balancer's security group, not an IP range |
| `CKV2_AWS_28` | ALB | A web application firewall costs extra and is out of scope |
| `CKV2_AWS_11` | VPC | Flow logs cost extra and are out of scope |
| `CKV_AWS_150` | ALB | Deletion protection is the `deletion_protection` variable: off in staging so it can be destroyed, on in production |
| `CKV_AWS_293` | database | Same variable as above |
| `CKV_AWS_157` | database | Multi-AZ is the `db_multi_az` variable: off in staging to save cost, on in production |
| `CKV_AWS_145` | state bucket and ALB log bucket | SSE-S3 (AES256) is free, and load balancer access logs support SSE-S3 only, not KMS |
| `CKV_AWS_136` | ECR repositories | AES256 (the ECR default) is free; a customer-managed key adds cost and key management |
| `CKV_AWS_158` | database log groups | CloudWatch Logs encrypts at rest by default; a customer-managed key adds cost |
| `CKV_AWS_354` | database | Performance Insights uses the default AWS-managed key |
| `CKV_AWS_149` | JWT secret | The secret uses the default AWS-managed Secrets Manager key |
| `CKV_AWS_338` | database log groups | Retention is a per-environment variable (14 days staging, 90 days prod); a year costs more than it is worth here |
| `CKV_AWS_144` | state bucket and ALB log bucket | One region is enough, and replication would add cost |
| `CKV_AWS_18` | state bucket and ALB log bucket | Access logging needs another bucket to hold the logs |
| `CKV_AWS_21` | ALB log bucket | The logs expire, and versioning would keep deleted versions and add cost. (The state bucket is versioned.) |
| `CKV2_AWS_62` | state bucket and ALB log bucket | There is no consumer for bucket event notifications |
| `CKV_AWS_161` | database | The application signs in with the managed password; IAM database authentication would need application changes |
| `CKV2_AWS_57` | JWT secret | Automatic rotation would sign out every logged-in user; the key is rotated deliberately by increasing `secret_version` |
| `CKV2_AWS_5` | the three security groups | checkov scans each module on its own; the groups are attached in the load balancer, compute and rds modules |
| `CKV_AWS_394` | availability zone lookup | Only the first `az_count` names are used, and a zone added later sorts last, so the chosen zones do not change |

**trivy** is used as a second opinion and is not a gate, so its findings are not suppressed twice. It reports 13
distinct findings, all in the same categories as the table (plain HTTP, customer-managed keys, versioning,
logging, flow logs, deletion protection, IAM authentication). One has no checkov equivalent: `AWS-0104` calls
the `app` group's outbound HTTPS rule to `0.0.0.0/0` critical. That rule is how the instances reach ECR, SSM and
Secrets Manager through the NAT gateway, and replacing it would need interface endpoints, which cost about $95
a month (see [VPC endpoints](#vpc-endpoints)).

### Secrets in the repository

gitleaks finds 4 secrets in the git history. All are in the first commit, the unmodified import of the upstream
app: the JWT key in `app/docker-compose.yml` and in the upstream README (twice), and a token in
`app/backend/README.md`. The history cannot be rewritten
without breaking the "unmodified import" commit, so `.gitleaks-baseline.json` records exactly those 4
findings, with the values redacted, and a scan against it reports only new leaks. Treat the upstream JWT key
and the database password `1234` as public: they must never be used in AWS, and step 2.1 removes them from
the compose file. A scan of the working tree also flags the local `app/.env`. That file is git-ignored, was
never committed, and the hooks and CI do not scan it.

## Continuous integration (pull requests)

`.github/workflows/ci.yml` runs on every pull request to `main`, and by hand (`workflow_dispatch`). It only
checks: nothing in it deploys.

| Job | What it checks | Fails when |
|-----|----------------|------------|
| `changes` | Whether the Terraform, its tool settings or the workflow changed | it cannot decide |
| `lint` | eslint and prettier (backend), eslint (frontend), hadolint on both Dockerfiles, shellcheck on the scripts, actionlint on the workflows, and that the local compose file is valid | any of them reports a problem |
| `unit-tests` | The backend Jest suite, with the coverage report kept as an artifact for 14 days | a test fails |
| `integration-tests` | The migrations from scratch, then the integration test, against a `postgres:17` service container | a migration or a test fails |
| `dependency-scan` | trivy on both lockfiles: production dependencies, HIGH and CRITICAL | any such finding |
| `secret-scan` | gitleaks on the full history, against `.gitleaks-baseline.json` | a new secret |
| `image-build-scan` | Builds both images (nothing is pushed) and scans them with trivy, HIGH and CRITICAL that have a fix | any such finding |
| `iac-checks` | `terraform fmt`, `validate` in `bootstrap`, `staging` and `prod`, tflint and checkov | any of them reports a problem. Runs only when `infra/`, `.tflint.hcl`, `.checkov.yaml` or `ci.yml` changed |
| `script-tests` | The tests for `deploy.sh` and `smoke-test.sh` | a check fails |

**How it is built.**

- **Pinned.** Every third-party action is pinned to a full commit SHA (the version is in a comment), chosen from
  releases at least two weeks old. The scanners (hadolint, shellcheck, actionlint, trivy, gitleaks) run as
  images pinned by digest, so a moved tag cannot change what runs. The digests are listed once, at the top of
  the workflow, and are updated by hand: Dependabot does not read `docker run` commands.
- **Least privilege.** The token is read-only (`permissions: contents: read`), every job has a timeout, and a
  new push to the same pull request cancels the run it supersedes. There is no `pull_request_target`.
- **A job, not a path filter.** `iac-checks` is skipped by a `changes` job and not by a `paths` filter on the
  workflow. A workflow that a filter skips never reports its required checks, so the pull request would wait
  forever, while a skipped job counts as passed. Because a skipped job counts as passed, `changes` is a
  required check as well: otherwise a failure there would silently skip the Terraform checks.
- **Throwaway credentials.** The integration job's database password (`ci-only`) protects a container that
  exists for the length of the job and is not reachable from outside.

**Branch protection on `main`.** A pull request is required (with no required approvals, because this is a
single-person repository and GitHub does not let you approve your own pull request). All nine jobs above must
pass, the branch must be up to date with `main`, the rules apply to administrators too, and force-pushes and
deletion of `main` are blocked. To relax a rule temporarily, change it under Settings, Branches and put it back.

**Dependency findings fixed in this step.** The step 0.5 baseline output is not in the repository (`evidence/`
is git-ignored), so the "before" figures are from scanning the lockfiles on `main` at the start of the step:
38 HIGH and CRITICAL findings in 12 production packages (36 in the backend, 2 in the frontend), all with a
fixed version available. The backend image reported 46: the same application packages plus 10 more from the
npm bundled in the Node base image. The frontend image had 2, in an Alpine package. After this step both
lockfiles and both images report zero.

- `npm audit fix` took the changes that stay inside the declared version ranges.
- `bcrypt` 5 to 6 removes `tar` (9 findings, one of them critical), which it needed only to unpack its
  prebuilt binary at install time. bcrypt 6 ships the binary in the package.
- Four packages are pinned to vulnerable versions by NestJS itself, so `package.json` has scoped `overrides`:
  `multer` and `body-parser` under `@nestjs/platform-express`, `js-yaml` and `lodash` under `@nestjs/swagger`,
  and `lodash` under `@nestjs/config`. `npm audit fix` cannot move an exact pin, which is why these needed
  overrides. Dependabot does not update overrides, so revisit them when NestJS is updated.
- The backend runtime image deletes npm, npx and corepack. It starts with `node dist/main.js` and runs
  migrations with `node_modules/.bin/prisma`, so it never uses them, and they carried their own vulnerable
  dependencies.
- The frontend image runs `apk upgrade libxslt`, because the pinned `nginx:1.30.6-alpine` still ships a version
  with two fixable HIGH findings. Remove that line when the next nginx tag carries the fix.

**Not covered.** Three HIGH findings remain in development-only tooling (`glob`, `picomatch` and `tmp`, through
the Nest CLI). They are not in the runtime image and the gate does not scan development dependencies, so they
are noted here and not suppressed. Findings in the base image with no fix yet are left out of the image scan
(`--ignore-unfixed`) because nothing can be done about them. There is no `.trivyignore`: a finding is fixed,
and if one ever cannot be, the ignore file must carry a comment for each entry. Uploading the results to
GitHub's Security tab (SARIF) is not done.

**Dependabot** (`.github/dependabot.yml`) opens weekly pull requests, grouped by minor and patch, for npm
(backend and frontend), the two Dockerfiles, GitHub Actions and Terraform. Moving to another Node release line
is excluded: it is a decision, not an update. Its pull requests pass through the same checks.

**Running the same checks locally.** Everything above uses tools you can run yourself; the exact commands are in
the workflow. For example `docker run --rm -i hadolint/hadolint < app/backend/Dockerfile`,
`trivy fs app --scanners vuln --severity HIGH,CRITICAL`, and `gitleaks git --baseline-path
.gitleaks-baseline.json`. The Terraform checks are listed under [Quality gates](#quality-gates).

## Credits

The application in `app/` is [tedrosdev/digital-wallet](https://github.com/tedrosdev/digital-wallet),
imported at upstream commit `011bd00b2e43aee3c9f955b4bd84b73ac40338b7` (2024-12-23). The first commit
in this repository is that import, with file contents unchanged, so every later commit shows what
was changed on top of it. Its original README is kept at `app/UPSTREAM_README.md`.

Licence note: the upstream README says the project is MIT-licensed and links to a `LICENSE` file, but
no `LICENSE` file exists in the upstream repository, and its `backend/package.json` declares
`"license": "UNLICENSED"`. No licence text has therefore been copied here.
