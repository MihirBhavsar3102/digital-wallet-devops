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
must outlive any single environment, and the [pipeline notifications](#pipeline-notifications-step-26)
(an SNS topic with an e-mail subscription, and the role that publishes to it) for the same reason.

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
| `ssm:GetParameter` (added in step 2.4) | The one parameter `/<name_prefix>/deployed-tag` only: the tag of the last release that passed its smoke test, read at boot (see [First boot](#first-boot)) |

### GitHub Actions deploy roles (OIDC)

The GitHub OIDC identity provider for `token.actions.githubusercontent.com` is created once, in
`infra/bootstrap/`. An account can have only one provider per URL and both environments share an
account, so it cannot live in an environment: destroying staging to save money would otherwise break
the production pipeline's login.

Each environment has its own role, `<name_prefix>-github-deploy`:

| Permission | Scope |
|------------|-------|
| ECR push: `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage` | This environment's two repositories only |
| `ecr:DescribeImages` (added in step 2.3) | This environment's two repositories only. Read-only: lets the pipeline ask whether a commit's tag is already pushed, so that a re-run skips the push |
| `ssm:SendCommand` | The `AWS-RunShellScript` document, and only instances tagged `environment=<env>` |
| `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations`, `ssm:ListCommands` (the last two added in step 2.4) | `*`, to read command results, find the instances a command reached and ask whether the command as a whole succeeded. None of the three supports resource-level permissions |
| `ssm:PutParameter` (added in step 2.4) | The one parameter `/<name_prefix>/deployed-tag`, which the pipeline writes after a deploy has passed its smoke test |
| `rds:CreateDBSnapshot` (**prod only**) | The production database and snapshots named `digital-wallet-prod-*` |
| `rds:DescribeDBSnapshots` (**prod only**, added in step 2.5) | The same two resources: the database and snapshots named `digital-wallet-prod-*`. `aws rds wait db-snapshot-available` polls it, and names the snapshot, which is what RDS checks |
| ECR read: `BatchGetImage`, `GetDownloadUrlForLayer`, `BatchCheckLayerAvailability`, `DescribeImages` (**prod only**, added in step 2.5) | Staging's two repositories only (`image_source_name_prefix`), so production can promote the image that passed staging, see [Production](#production-step-25) |

Each trust policy checks two claims in the GitHub token: the audience must be `sts.amazonaws.com`, and
the subject must be exactly `repo:MihirBhavsar3102@62109840/digital-wallet-devops@1451854102:environment:<env>`.
In practice:

- The GitHub Environments must be named exactly `staging` and `production` (the match is case-sensitive).
  Production's Terraform environment is `prod`, which names its resources and the `environment=prod` tag the
  deploy targets, but its GitHub Environment is `production`, so `envs/prod/prod.tfvars` sets
  `github_environment = "production"` and the trust policy follows it.
- A workflow job must declare `environment: <env>` and `permissions: id-token: write`.
- A job from another repository, a fork, or a job with no environment produces a different subject
  and is refused. Production can also require a reviewer's approval on its GitHub Environment.

**The subject carries numeric ids (found in step 2.3).** Since 15 July 2026 GitHub gives repositories created
after that date an *immutable* subject claim: the numeric owner and repository ids follow the names
(`repo:OWNER@OWNER_ID/REPO@REPO_ID:environment:NAME`). The first version of these trust policies used the older
name-only form, which such a token never matches, and the first run of `cd.yml` failed with `Not authorized to
perform sts:AssumeRoleWithWebIdentity`. The module now builds the subject from `github_repository` and two ids,
`github_owner_id` and `github_repository_id`, which have defaults in each environment because none is secret.
The ids make the role stricter: a repository deleted and recreated under the same name gets a new id and cannot
assume it. In that case, update `github_repository_id`. To check what a repository issues, or to look the ids up:

```
gh api repos/OWNER/REPO/actions/oidc/customization/sub    # use_immutable_subject and sub_claim_prefix
gh api repos/OWNER/REPO --jq '{owner_id: .owner.id, repository_id: .id}'
```

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
- The parameter `/<name_prefix>/deployed-tag` is created by the compute module and its permissions are built
  from the same name in the IAM module: change one and the other has to follow.
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
3. installs the AWS CLI (used by `deploy.sh` for the ECR login and Secrets Manager) with AWS's own installer
   from `awscli.amazonaws.com`, and the CloudWatch agent, which it then starts with the configuration from
   Parameter Store (see [CloudWatch agent](#cloudwatch-agent-step-32)).
   The CLI used to come from the Snap store, which was unreachable on 2026-11-11 and kept every new instance
   from booting, see [Boot without the Snap store](#boot-without-the-snap-store);
4. creates `/opt/app/` containing `instance.env` (region, account ID, name prefix) and `deploy.sh`, a copy
   of `scripts/deploy.sh`, which is still a skeleton until the pipeline step;
5. starts a **placeholder** nginx container on the frontend and backend ports (80 and 8081), so load balancer health checks pass
   before the first real deploy. Its page shows which instance answered, and `/api` returns 200. The
   image comes from the public ECR mirror of nginx, which avoids Docker Hub's pull rate limits;
6. **converges to the last good release** (step 2.4): reads the SSM parameter `/<name_prefix>/deployed-tag`
   and, unless it says `none`, runs `deploy.sh` with that tag. The pipeline writes the tag after every deploy
   that passed its smoke test. Without this step a replacement instance (a failed health check, an instance
   refresh, a scale-out) would serve the placeholder until the next deploy. If the deploy fails here the
   placeholder stays up and the boot still finishes. Terraform creates the parameter with the value `none`
   and ignores later changes to the value, which belongs to the pipeline. It is destroyed with the
   environment on purpose: a rebuilt environment has empty ECR repositories, so a surviving tag would point
   at an image that no longer exists.

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

### Boot without the Snap store

The first `user_data` installed the AWS CLI with `snap install aws-cli --classic`. On 2026-11-11 at about 15:00
UTC the Snap store stopped answering: `api.snapcraft.io` and `snapcraft.io` timed out over IPv4 from the
staging instance, which is in `ap-south-1`, and from a laptop on another network, while Docker, AWS and
Ubuntu's archive answered normally. (No incident was reported publicly that I could find, so the cause is
unknown.) `snap install` failed with `error: unable to contact snap store`, and because the script stops at
its first error, no new instance got as far as writing `/opt/app/deploy.sh` or starting the placeholder. Each
one failed the load balancer's health check and was replaced after about six minutes by one that failed the
same way: an instance refresh that never finished, while the one old instance kept serving. The first
deploy to arrive in the middle of that failed with `/opt/app/deploy.sh: not found`.

The CLI now comes from AWS's own installer (`curl` of `awscli.amazonaws.com`, `unzip`, `install`), which puts it
in `/usr/local/bin`, on the default PATH of every shell including SSM's. Tried first on Ubuntu 26.04: it
installs and runs. This removes the one dependency on a service that is not AWS, Docker or Canonical's package
archive. Boot still depends on those three, and on the public ECR mirror of nginx. Baking an image with
everything installed (for example with Packer) would remove them all, at the price of an image pipeline: it is
listed under future improvements.

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
| GitHub Environment the deploy role trusts (`github_environment`) | `staging` (same as the environment) | `production` |
| Where the images come from (`image_source_name_prefix`) | built by the pipeline | promoted from `digital-wallet-staging` |

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
- **With a default shared by both**: `project`, `github_repository`, `github_owner_id`, `github_repository_id`, `az_count`, `alb_ingress_cidrs`, the two ports
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
secret's ARN, the database log group names, the application and system log group names (`app_log_group_names`,
step 3.1), the access log bucket, and the GitHub deploy role ARN. The state bucket's name is an output of
`infra/bootstrap/`, where the bucket is created.

The dashboard and alarm outputs (`dashboard_names`, `dashboard_urls`, `saved_query_names`, `alarm_names`,
`alarm_topic_arn`; steps 3.6 and 3.7 of [Part 3](#monitoring-and-logging-part-3)) are there too. There is **no
`alarm_email` variable in an environment**: the alarm topic and the address live in `infra/bootstrap`, see
[Alarms and notifications](#alarms-and-notifications-step-37).

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
| `infra/modules/` | Reusable Terraform modules (`monitoring/`: log groups, the agent's configuration and the error metric; `observability/`: the dashboards and saved queries, and from step 3.7 the alarms) |
| `infra/envs/staging/`, `infra/envs/prod/` | One folder per environment, both calling the same modules |
| `.github/workflows/` | GitHub Actions pipelines (`ci.yml` for pull requests) |
| `.github/dependabot.yml` | One weekly pull request with all minor and patch dependency updates (npm, Docker, GitHub Actions, Terraform) |
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
| `CKV_AWS_158` | database, application and system log groups | CloudWatch Logs encrypts at rest by default; a customer-managed key adds cost |
| `CKV_AWS_354` | database | Performance Insights uses the default AWS-managed key |
| `CKV_AWS_149` | JWT secret | The secret uses the default AWS-managed Secrets Manager key |
| `CKV_AWS_338` | database, application and system log groups | Retention is a per-environment variable (14 days staging, 90 days prod); a year costs more than it is worth here |
| `CKV_AWS_144` | state bucket and ALB log bucket | One region is enough, and replication would add cost |
| `CKV_AWS_18` | state bucket and ALB log bucket | Access logging needs another bucket to hold the logs |
| `CKV_AWS_21` | ALB log bucket | The logs expire, and versioning would keep deleted versions and add cost. (The state bucket is versioned.) |
| `CKV2_AWS_62` | state bucket and ALB log bucket | There is no consumer for bucket event notifications |
| `CKV_AWS_161` | database | The application signs in with the managed password; IAM database authentication would need application changes |
| `CKV2_AWS_57` | JWT secret | Automatic rotation would sign out every logged-in user; the key is rotated deliberately by increasing `secret_version` |
| `CKV2_AWS_5` | the three security groups | checkov scans each module on its own; the groups are attached in the load balancer, compute and rds modules |
| `CKV_AWS_394` | availability zone lookup | Only the first `az_count` names are used, and a zone added later sorts last, so the chosen zones do not change |
| `CKV_AWS_26` | alarm topic (`infra/bootstrap`) | An alarm message holds an alarm name, a metric and a threshold. CloudWatch cannot use the AWS-managed SNS key, and a customer-managed key with a wrong policy fails silently (the alarm cannot publish and nobody is told) |

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
| `lint` | eslint and prettier (backend), eslint (frontend), hadolint on both Dockerfiles, shellcheck on the scripts, actionlint on the workflows, `scripts/check-workflows.sh` (the [hardening rules](#hardening-step-28)), and that the local compose file is valid | any of them reports a problem |
| `unit-tests` | The backend Jest suite, with the coverage report kept as an artifact for 14 days | a test fails |
| `integration-tests` | The migrations from scratch, then the integration test, against a `postgres:17` service container | a migration or a test fails |
| `dependency-scan` | trivy on both lockfiles: production dependencies, HIGH and CRITICAL | any such finding |
| `secret-scan` | gitleaks on the full history, against `.gitleaks-baseline.json` | a new secret |
| `image-build-scan` | Builds both images (nothing is pushed) and scans them with trivy, HIGH and CRITICAL that have a fix | any such finding |
| `iac-checks` | `terraform fmt`, `validate` in `bootstrap`, `staging` and `prod`, tflint and checkov | any of them reports a problem. Runs only when `infra/`, `.tflint.hcl`, `.checkov.yaml` or `ci.yml` changed |
| `script-tests` | The tests for `deploy.sh`, `smoke-test.sh`, `ecr-tag-status.sh`, `ssm-deploy.sh`, `promote-image.sh`, `notify.sh`, `rollback-check.sh` and `check-workflows.sh` | a check fails |

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

**Dependabot** (`.github/dependabot.yml`) opens **one pull request a week**, on Monday, holding every minor and
patch update for npm (backend and frontend), the two Dockerfiles, GitHub Actions and Terraform together. It is
one `multi-ecosystem-groups` group (`weekly`) that all six update entries join with `patterns: ["*"]`. The
pull request passes through the same checks as any other.

- **Major versions are not in it.** They are excluded with `ignore`. A major bump (a framework, Vite, the Node
  release line) needs a decision and usually code changes, and inside the weekly pull request it would fail CI
  and hold the routine updates back with it. Upgrade them by hand when you choose to; `npm outdated` in
  `app/backend` and `app/frontend` lists them.
- **Prisma is excluded too.** `prisma` and `@prisma/client` are held at 6.0.1 on purpose (see
  [Engine version](#engine-version)). The first weekly pull request proposed 6.0.1 to 6.19.3, which pulls in
  `deepmerge-ts` 7.1.5 (CVE-2026-40345, HIGH, fixed only in 8.0.0), so CI blocked it. Upgrade Prisma as its own
  tested change, then remove the two `ignore` entries for it.
- **Security updates are separate.** GitHub opens those on its own when an advisory appears, so an urgent fix
  does not wait for Monday or ride along with an update that might fail. They are not controlled by this file.
- **Why it was changed.** The first version grouped only minor and patch updates inside each npm folder. Every
  major bump, every GitHub Actions update and every Docker image update still got its own pull request: 12 were
  opened within two minutes of the merge, on top of 4 security-update pull requests that were already open
  (challenges log, row 15).
- **Confirmed after the merge.** Within about three minutes Dependabot opened one grouped pull request (the
  backend and frontend packages and the frontend Dockerfile together) and closed four superseded ones itself. It
  left the eight open major-version pull requests alone, so those have to be closed by hand. The first weekly
  pull request is blocked by CI on a new HIGH finding, `deepmerge-ts` (CVE-2026-40345, fixed only in 8.0.0), that
  its Prisma 6.0.1 to 6.19.3 update pulls in, which is the gate working as intended (challenges log, row 15).

**Running the same checks locally.** Everything above uses tools you can run yourself; the exact commands are in
the workflow. For example `docker run --rm -i hadolint/hadolint < app/backend/Dockerfile`,
`trivy fs app --scanners vuln --severity HIGH,CRITICAL`, and `gitleaks git --baseline-path
.gitleaks-baseline.json`. The Terraform checks are listed under [Quality gates](#quality-gates).

## Continuous delivery: build, push, deploy, promote and roll back (steps 2.3 to 2.7)

`.github/workflows/cd.yml` runs when a commit lands on `main`, which is when a pull request is merged
([ci.yml](#continuous-integration-pull-requests) has already checked it). It has three jobs, in a chain:
`build-and-push` (step 2.3), `deploy-staging` (step 2.4, [below](#deploy-to-staging-step-24)) and
`deploy-production` (step 2.5, [below](#production-step-25)), which waits for a person to approve it.
The last two use the `tag` output of the first. A fourth workflow, `rollback.yml`
([below](#rollback-step-27)), deploys an older release by hand.

The deploy, the smoke test and the record of the last good release are one action, `.github/actions/deploy`,
used by `deploy-staging`, `deploy-production` and the rollback, so a rollback runs exactly the deploy step a
release does.

### Build and push: `build-and-push`

What the job does, in order:

1. **Checks its configuration.** The three variables below must be set, and the job says which one is missing.
2. **Tags the commit** with its first seven characters (`${GITHUB_SHA::7}`). `git rev-parse --short` was not
   used, because it returns a longer hash when seven would be ambiguous, and the tag has to be predictable.
3. **Logs in to AWS** with `aws-actions/configure-aws-credentials` and `role-to-assume`, then to ECR with
   `aws-actions/amazon-ecr-login`. There is no stored key (see
   [Why no AWS access keys live in GitHub](#why-no-aws-access-keys-live-in-github)).
4. **Asks ECR which of the two tags exist** (`scripts/ecr-tag-status.sh`) and keeps the ones that do not.
5. **Builds those images with Buildx**, loaded into the runner's Docker and not pushed. The frontend gets
   `VITE_API_BASE_URL=/api` as a build argument, because Vite bakes it into the bundle.
6. **Scans them with trivy before anything is pushed**, with the same gate as the `image-build-scan` job in
   `ci.yml`: HIGH and CRITICAL findings that have a fix fail the job.
7. **Pushes them** and publishes the tag as the job output `tag`. A summary on the run page says which image
   was pushed and which was already there.

### Set up once: the `staging` GitHub Environment

The job declares `environment: staging`, and these variables live on that environment (Settings, Environments,
staging, Variables). None is a secret.

| Variable | Value |
|----------|-------|
| `AWS_ROLE_ARN` | The Terraform output `github_deploy_role_arn` of `infra/envs/staging` |
| `AWS_REGION` | `ap-south-1` |
| `NAME_PREFIX` | `digital-wallet-staging`, so the repositories are `<prefix>-backend` and `<prefix>-frontend` |
| `ALB_URL` (step 2.4) | `http://` and the Terraform output `alb_dns_name` of `infra/envs/staging`, for the smoke test. It changes whenever staging is rebuilt, see [after a rebuild](#after-a-rebuild-of-staging) |

```
gh variable set AWS_ROLE_ARN --env staging --body "<role arn>"
gh variable set AWS_REGION   --env staging --body ap-south-1
gh variable set NAME_PREFIX  --env staging --body digital-wallet-staging
gh variable set ALB_URL      --env staging --body "http://$(terraform -chdir=infra/envs/staging output -raw alb_dns_name)"
```

### Decisions

- **The job must declare the environment.** The deploy role's trust policy accepts one token subject,
  `repo:<owner>@<owner id>/<repo>@<repo id>:environment:staging` (see [GitHub Actions deploy roles](#github-actions-deploy-roles-oidc)),
  and GitHub only puts `environment:staging` in the subject when the job names the environment. Without that
  line AWS refuses the login. The alternative, a trust policy that also accepts `ref:refs/heads/main`, would
  have widened what the role trusts. A side effect: the run page shows a deployment to `staging` as soon as the
  images are pushed, before any instance has been touched. Step 2.4's `deploy-staging` job will show the real one.
- **A tag that already exists is skipped, not an error.** The repositories have immutable tags, so pushing the
  same tag twice is rejected. A re-run of a commit, whether by hand or because a later job failed, therefore
  asks first and skips what is there. Each image is checked on its own, so a run that pushed the backend and
  stopped before the frontend is repaired by a re-run, which builds only the frontend. The alternative, to try
  the push and ignore the "already exists" error, would pay for a build and a scan first and would also hide a
  real rejection. The check needs `ecr:DescribeImages`, which was added to the deploy role in this step.
- **"Cannot tell" is not "absent".** `ecr-tag-status.sh` treats only `ImageNotFoundException` as absent. An
  expired login, a missing permission or a repository that does not exist stops the job, because reading
  one of them as absent would lead to a push that cannot work.
- **What is pushed is what was scanned.** The builds load the image locally, trivy scans it, and `docker push`
  sends that same image. A second build for the push could in principle differ from the one that was scanned.
  Both images are scanned before either is pushed, so a finding in one cannot leave the other in ECR.
- **Build cache.** Buildx keeps its layers in GitHub's cache service, one scope per image
  (`type=gha,mode=max`). An unchanged dependency layer is restored instead of rebuilt. `ignore-error=true` keeps
  an outage of the cache service from failing a release. The first run on `main` starts cold.
- **One run at a time, never cancelled.** The workflow's concurrency group queues runs and does not cancel one
  that has started, because stopping a push or a deploy half way is worse than waiting. If several commits
  land while a run is going, GitHub keeps only the newest waiting run, which ships the latest `main`.
- **Pinned and least privilege.** Every action is pinned to a full commit SHA, the workflow token is read-only,
  and the one job that needs more asks for exactly `id-token: write` and `contents: read`. trivy runs as the same
  image, pinned by digest, as in `ci.yml`: when the digest is updated there, update it here too.

### Re-running a commit

| State of ECR when the job starts | What the job does |
|----------------------------------|-------------------|
| Neither tag exists (a new commit) | Builds, scans and pushes both |
| Both tags exist | Builds and pushes nothing, and still outputs the tag |
| One tag exists | Builds, scans and pushes only the other |
| The check itself fails | Stops with AWS's message |

### Checked on `main` (2026-11-11)

- **First run.** After the trust policy fix (see the immutable subject note under
  [GitHub Actions deploy roles](#github-actions-deploy-roles-oidc)), the run logged in to AWS, built both images,
  scanned them and pushed them in 4 minutes 12 seconds. Both repositories hold the tag `6d97901`, the first seven
  characters of the merge commit. The build cache starts cold on the first run.
- **Re-run of the same commit.** It finished in 18 seconds: both tags were `present`, so nothing was built, scanned
  or pushed, and the run still succeeded. That is the immutable-tag decision working on real AWS.
- **ECR's own scan reports more than the gate does.** Scan on push shows 6 HIGH, 2 MEDIUM and 3 LOW on the backend
  and 1 CRITICAL on the frontend. Trivy run on the pushed images, without `--ignore-unfixed`, finds no HIGH or
  CRITICAL in the frontend (so ECR's zlib finding is not confirmed), and 11 distinct HIGH and CRITICAL CVEs in the
  backend's Debian packages (util-linux, zlib, ncurses, perl and others). None has a fixed version: Debian lists
  them as `affected`, `fix_deferred` or `will_not_fix`. That is exactly what `--ignore-unfixed` leaves out, so the
  gate behaved as designed, and a build fails as soon as one of them gets a fix.

### Deploy to staging (step 2.4)

`deploy-staging` runs after `build-and-push` (`needs`), in the same `staging` GitHub Environment, so it uses
the same role, and deploys the tag that job output:

1. **Deploys** with `scripts/ssm-deploy.sh staging <tag>`: `aws ssm send-command` with the `AWS-RunShellScript`
   document, sent to the instances tagged `environment=staging` and `Role=app` (no instance IDs, so a replacement
   instance is found by its tags), running `/opt/app/deploy.sh <tag>`.
2. **Smoke-tests** with `scripts/smoke-test.sh "$ALB_URL"`, from the runner, through the public load balancer.
   It checks that the page is the app and that `/api/health` says ok, so the first-boot placeholder, which
   also answers 200, does not pass.
3. **Records the tag** in the SSM parameter `/<name_prefix>/deployed-tag`, only after the smoke test passed.

**How `ssm-deploy.sh` waits and fails** (63 tests in `scripts/tests/ssm-deploy.test.sh`):

- **One instance at a time, and stop at the first error.** `--max-concurrency 1` and `--max-errors 0`. The
  parameter names come from `aws ssm send-command help`: `MaxErrors` is "the maximum number of errors allowed
  without the command failing. When the command fails one more time beyond the value of `MaxErrors`, the
  systems stops sending the command to additional targets", so 0 stops at the first failure (its default, set
  explicitly so the intent is visible). The second instance keeps serving the old version while the first is
  updated, and a failed deploy never reaches it.
- **It waits with `aws ssm wait command-executed`, per instance.** That waiter polls every 5 seconds and gives up
  after 20 attempts, 100 seconds, which a deploy that pulls images and runs migrations can exceed. When it gives
  up while the command is still `InProgress` the script calls it again, until 15 minutes. Failed, TimedOut and
  Cancelled end the run.
- **It waits for an instance that is still booting.** A new instance has its SSM agent running and its tags set
  within a minute, but `user_data` takes about three before `/opt/app/deploy.sh` exists. The command that runs
  on the instance is `cloud-init status --wait`, then `deploy.sh`. The first version had no wait, and the
  deploy to such an instance failed with `deploy.sh: not found` (status 127). If the boot did fail, `deploy.sh`
  is missing and the message says `this instance has not finished booting` and points at the boot log.
- **On failure it prints the output of every instance that failed.** `aws ssm get-command-invocation` supplies
  the stdout and stderr of `deploy.sh`. SSM runs the instances in an order of its own, and with `--max-errors 0`
  the first failure stops the rest, which then end as `Terminated` with nothing to show. The instance the
  script is waiting on is therefore not necessarily the one that failed: on staging the healthy instance was
  reported as `Terminated` while the real error was on the other. The script lists all the instances, marks the
  ones SSM only stopped, and prints the output of the ones that failed on their own. A successful run prints
  the same output, so the log shows what each instance did.
- **A deploy that reaches no instance fails.** Probed on staging with a harmless `echo`: SSM answers
  `TargetCount: 0` and status `Pending` both for a command whose tags match an instance and for one whose tags
  match nothing, and it raises no error for the second. A deploy to an environment that is down, or whose
  instances are not registered with Systems Manager, would therefore look like a success. The script requires
  an invocation to appear, and the command as a whole to end `Success`, which also catches an instance whose
  invocation shows up after the others have finished.

**The last good release.** After a deploy that passed its smoke test, the job writes the tag to the SSM
parameter `/<name_prefix>/deployed-tag`. A new instance reads it at boot and deploys it, so a replacement
instance serves the last good version and not the placeholder (see [First boot](#first-boot)). The parameter
only ever holds a tag that was smoke-tested. It is destroyed with the environment, because a rebuilt environment
has empty ECR repositories. The permissions behind it (list and read the command, write one parameter, read one
parameter) are in [Identity and access](#identity-and-access-iam).

#### After a rebuild of staging

Staging is destroyed to save money and rebuilt with `terraform apply`. A rebuild changes three things the
pipeline depends on:

- **The load balancer's address.** Set `ALB_URL` again, or the smoke test checks a load balancer that no longer
  exists:
  `gh variable set ALB_URL --env staging --body "http://$(terraform -chdir=infra/envs/staging output -raw alb_dns_name)"`
- **The ECR repositories come back empty**, and the deployed-tag parameter back as `none`. Run the workflow
  again for the newest commit on `main` (Actions, the latest CD run, Re-run all jobs): the tags are absent, so
  both images are rebuilt and pushed, and the deploy follows.
- **The role, its variables and the environment** keep their names, so `AWS_ROLE_ARN`, `AWS_REGION` and
  `NAME_PREFIX` stay valid.

### Production (step 2.5)

`deploy-production` needs `build-and-push` and `deploy-staging` (the first is listed too, because a job can only
read the outputs of the jobs it names), and runs in the `production` GitHub Environment.

**The approval gate.** Settings, Environments, `production` holds the rules, which were set with the GitHub API
and can be seen and changed on that page:

| Rule | Setting |
|------|---------|
| Required reviewers | `MihirBhavsar3102`. The job pauses before any step until a reviewer approves it, and the run page shows a **Review deployments** prompt (this is the screenshot for the demo) |
| Prevent self-review | off, because this is a single-person repository and GitHub would otherwise leave nobody able to approve. With a second person, add them as a reviewer and turn it on |
| Deployment branches | `main` only. A workflow from any other branch cannot enter the environment, and so cannot use the role |
| Wait timer | none. It is optional: set one on the same page to give a reviewer time to cancel after approving |

The gate also protects the AWS role. Production's deploy role trusts only a token whose subject ends in
`environment:production`, and GitHub only issues that to a job that has passed the environment's rules.

**What the job does after the approval, in order:**

1. **Checks its configuration**: the variables below must be set.
2. **Logs in** with production's role, then to ECR.
3. **Promotes the release that passed staging** (`scripts/promote-image.sh`, 29 tests). The two environments
   have separate repositories, so production gets the image that was built, scanned and smoke-tested for
   staging and not a second build of the commit. The two images are copied inside ECR and the script checks that
   each copy has the same digest as its source. A release that is not in staging's repositories is refused
   before anything is copied, an image that is already in production's repositories is left alone (immutable
   tags), and an AWS error is a failure.
4. **Snapshots the database** with `aws rds create-db-snapshot` and waits with
   `aws rds wait db-snapshot-available`. The snapshot is named `digital-wallet-prod-pre-<tag>-<run id>-<attempt>`:
   it has to start with the name prefix, which is what the role's permission matches, and it is unique per run
   attempt. Migrations are part of a deploy and a rollback of the code cannot undo them, so the deploy does not
   start until the snapshot is available. These manual snapshots are kept until someone deletes them: how long
   to keep them is part of the backup strategy (step 4.3).
5. **Deploys** with `scripts/ssm-deploy.sh prod <tag>`, the script of the staging job, to the instances tagged
   `environment=prod`, one at a time.
6. **Smoke-tests** through the production load balancer, with the same script.
7. **Records the tag** in `/digital-wallet-prod/deployed-tag`, and the summary of the run page lists the tag,
   the snapshot and the address.

**Variables** on the `production` GitHub Environment, none of them a secret:

| Variable | Value |
|----------|-------|
| `AWS_ROLE_ARN` | The ARN of the role `digital-wallet-prod-github-deploy` (set; the role exists once production is applied) |
| `AWS_REGION` | `ap-south-1` (set) |
| `NAME_PREFIX` | `digital-wallet-prod` (set) |
| `SOURCE_NAME_PREFIX` | `digital-wallet-staging`, where the image that passed staging is (set) |
| `ALB_URL` | `http://` and the Terraform output `alb_dns_name` of `infra/envs/prod`. **Not set**, because production has not been applied: the job's first step stops with a message that says so |

**Decisions:**

- **The environment is named `production`, the Terraform environment `prod`.** They disagreed: the role trusted
  `environment:prod`, so no job in the `production` environment could ever have assumed it, and the login would
  have failed at the first approved run. `github_environment` (a variable of both environments, defaulting to the
  environment's own name) lets `prod.tfvars` set `production`. The staging and prod Terraform files stay identical,
  and the differences are in the tfvars.
- **Promote, do not rebuild.** What runs in production is what ran on staging. The copy uses
  `docker buildx imagetools create --prefer-index=false`. Trying it on staging showed that without the flag, a
  single image is wrapped in a new image index, which has a different digest: a look-alike, not the same image.
  The script compares the digests, so a copy that is not identical fails instead of being deployed.
- **Concurrency is per deploy job.** The workflow-wide group of step 2.3 would hold every later run behind a run
  that is waiting for an approval, which can take days. `deploy-staging` and `deploy-production` have a group
  each (`cancel-in-progress: false`): two deploys to one environment never overlap, a deploy that has started is
  never cancelled, and of the runs queued for one environment only the newest waits. The consequence is that
  an older run can still be waiting for approval when a newer one has already been deployed to staging.
  Approve the newest run and reject the older ones.
- **Permissions.** Besides the push rights from step 2.3, the production role may read staging's two repositories
  (for the promotion) and describe snapshots (for the wait). Everything else is as for staging. See
  [GitHub Actions deploy roles](#github-actions-deploy-roles-oidc).

#### Not run end to end: production has never been applied

Production costs about $170 a month and is stood up for a demo only, so the steps after the approval have not
run against real production resources. What has been checked instead:

- `scripts/promote-image.sh` against a fake `aws` and `docker` (29 checks), and `docker buildx imagetools create`
  itself against staging's real ECR: it works with the registry, and it is how the digest finding above was made.
- `ssm-deploy.sh` and `smoke-test.sh` are the scripts the staging job runs for real.
- `terraform plan` of production against an empty local state: the trust condition is
  `repo:MihirBhavsar3102@62109840/digital-wallet-devops@1451854102:environment:production`, the promotion policy
  names staging's two repositories and nothing else, and the snapshot policy has both the create and the wait
  permission.
- The snapshot step's shell, run against a fake `aws`: the name it builds is a valid RDS identifier and matches
  the role's `digital-wallet-prod-*` pattern.
- **Not checked:** production's role assuming through the approval, the cross-repository copy, the snapshot and
  its wait, `ssm:SendCommand` on the `environment=prod` tag, and the deploy to two instances.

#### Standing production up for a demo

```
cd infra/envs/prod
terraform init
terraform apply "-var-file=prod.tfvars"
gh variable set ALB_URL --env production --body "http://$(terraform output -raw alb_dns_name)"
```

Then push a commit to `main` (or re-run the latest CD run), wait for staging to pass, and approve the
deployment. Staging has to be up when production deploys, because that is where the image comes from. The
first deploy to production finds its repositories empty, which is what the promotion is for. Afterwards, to
stop paying for production: its ECR repositories keep their images (`deletion_protection`), so empty them first
or `terraform destroy` stops with an error, and delete the pre-deploy snapshots you no longer need.

### Rollback (step 2.7)

`.github/workflows/rollback.yml` deploys a release that is **already in ECR** to an environment again, normally an
older one, without building anything. It is run by hand: Actions, Rollback, Run workflow, or

```
gh workflow run rollback.yml -f environment=staging -f image_tag=3e8bbd8
```

| Input | |
|-------|-|
| `environment` | `staging` or `production` |
| `image_tag` | the release, as a short commit SHA, such as `3e8bbd8` |

**What it does**, in order, as one job that takes the chosen environment as its GitHub Environment (so that
environment's variables, the role it assumes and its protection rules all apply):

1. Checks its inputs and that it was started from `main`.
2. Logs in with the environment's deploy role (OIDC, no stored key).
3. **Checks that the release is in ECR** (`scripts/rollback-check.sh`, 22 tests): both images have to be in the
   environment's repositories, because `deploy.sh` pulls both. A release that is not there is refused before any
   instance is touched, and the message lists the releases that are, newest first. The usual reasons are a typo and
   a release the lifecycle policy has expired.
4. Runs the shared deploy action: the instances one at a time, the smoke test through the load balancer, and the
   record of the release in the SSM parameter `/<name_prefix>/deployed-tag`.

A **production** rollback waits for the reviewer's approval, as a production deploy does, and can only run from
`main`. A failed rollback sends an e-mail, and a successful production rollback announces which release production
now runs, as a deploy does ([Pipeline notifications](#pipeline-notifications-step-26)).

#### Finding the last good tag

There are three places to look. The first is the one to trust.

1. **The SSM parameter and its history.** The pipeline writes the parameter only after a release has passed its
   smoke test, so its history is the list of releases that worked, in order. The current value is what the
   environment runs now, and the one before it is the previous good release:
   ```
   aws ssm get-parameter-history --name /digital-wallet-staging/deployed-tag \
     --query 'sort_by(Parameters,&LastModifiedDate)[].[LastModifiedDate,Version,Value]' --output text
   ```
   Use `/digital-wallet-prod/deployed-tag` for production. (From Git Bash, set `MSYS_NO_PATHCONV=1` first, or the
   leading `/` is rewritten into a Windows path.) The first value, `none`, is Terraform's.
2. **ECR: what still exists.** The lifecycle policy keeps the last 10 **images** of each repository, and a rollback
   can only go to one of them:
   ```
   aws ecr describe-images --repository-name digital-wallet-staging-backend \
     --query 'reverse(sort_by(imageDetails[?imageTags], &imagePushedAt))[].[imagePushedAt, join(`, `, imageTags)]' --output text
   ```
   One image can carry many tags. A commit that changes no code, such as a documentation change, builds an
   identical image, so its tag lands on the existing image: on 2026-11-11 seven tags shared one image. Rolling back
   between tags of the same image changes nothing; a rollback is only meaningful between different images.
3. **Run history.** `gh run list --workflow cd.yml --status success` lists the runs that deployed, the run's summary
   says `Staging runs <tag>`, and the repository's Deployments page lists what each environment was given.

#### What a rollback does not undo

- **Database migrations.** `deploy.sh` runs `prisma migrate deploy` from the image being deployed. An older image has
  fewer migrations, so it applies nothing, and nothing reverts what a newer one applied. The older code therefore
  has to work with the newer schema, which is the rule migrations are written to already (the old and the new code
  have to tolerate each other during a deploy). Data written by the newer version stays. If a migration itself
  has to be undone, production's pre-deploy snapshot (step 2.5) is the restore point, at the price of the data
  written since.
- **The pipeline moving on.** The next merge to `main` deploys the newest release to staging again, and queues a
  production deploy for approval. To keep a rollback in place, revert the bad commit first, or do not merge until it
  is fixed.
- **A deploy that is waiting for approval.** A production rollback shares the `deploy-production` concurrency group
  with `cd.yml`'s production job, so that they never overlap. A run of `cd.yml` that is waiting for its approval may
  hold that group, and then the rollback queues behind it: cancel or reject that run first. This one is not
  verified, because production has not been applied.

#### Decisions

- **A workflow of its own, not an extra trigger of `cd.yml`.** `cd.yml` is a chain (build, staging, production). A run
  that skips the build would have to skip or rewrite the condition of every job that needs it, and a job whose
  `needs` was skipped is skipped itself unless its condition says otherwise. That is easy to get wrong and cannot be
  tested short of running it.
- **The rollback records the release it went back to.** Otherwise the parameter would still name the release that was
  rolled back from, and a replacement instance, which deploys that parameter at boot, would bring the bad release
  back.
- **The environment is the input.** `environment: ${{ inputs.environment }}` makes the variables, the role and the
  approval gate follow the choice with no extra logic, and production's rules cannot be skipped by choosing it.

#### Checked (2026-11-11)

Before this was merged, the rollback job was run once from a throwaway branch (the trigger and the inputs replaced
by literals, nothing else changed) against staging, to the older release `70f912e-2` from step 1.14, which is a
genuinely different image. It passed every step. The two containers on the instance then ran `...:70f912e-2`, the
instance's `current-tag` and the SSM parameter said `70f912e-2`, the smoke test passed, and `/api/health` answered
through the load balancer. `rollback-check.sh` was also run against staging's real ECR, for a tag that exists and
for a typo, and its refusal listed the releases that are there.

After the merge, `workflow_dispatch` was run for real from `main`:

- **A rollback of staging** to `70f912e-2` (the run is titled `Rollback staging to 70f912e-2`) passed, and staging
  ran that release and the parameter named it.
- **A mistyped tag**, `70f912f`, was refused at the step `The release is in ECR`, with both repositories' lists of
  releases in the log. None of the deploy steps ran, staging still ran `70f912e-2`, and the failure e-mail
  (`Rollback failed: rollback (main)`) was sent.
- **A roll forward** to the newest release with the same workflow passed. The SSM parameter's history now shows the
  sequence of what was deployed, rollbacks included.
- The refactored deploy steps of `cd.yml` also ran for real, on the merge itself: `deploy-staging` passed through
  the shared action.

**Not checked:** a rollback of production (production has not been applied), and the concurrency caveat above.

### Not done

- **A second reviewer and a wait timer** for production. The repository has one maintainer, so the reviewer
  can approve their own deployment. Both can be added on the environment's page without changing the workflow.
- **Restricting `staging` to `main`** as well. Production already is (see above). The staging role trusts any job
  in the `staging` environment, so a workflow on another branch that names it could use the role. That belongs
  to the hardening step (2.8).
- **An SBOM and image signing** (for example Syft or Trivy for the SBOM and cosign for the signature) are not
  done. They are listed here for the future-improvements list of the final write-up. ECR's own scan on push
  still runs on every pushed image.
- **Scan results are not uploaded as SARIF** to GitHub's Security tab, the same as in `ci.yml`.

## Pipeline notifications (step 2.6)

A failed pipeline sends an e-mail, through an SNS topic with an e-mail subscription. There is no Slack: the plan
offered either, and e-mail was chosen.

| E-mail | Sent when | Subject looks like |
|--------|-----------|--------------------|
| A failed CI run | a job of `ci.yml` failed on a pull request | `[digital-wallet-devops] CI failed: unit-tests, integration-tests (PR #59)` |
| A failed CD run | `build-and-push`, `deploy-staging` or `deploy-production` failed, or the production approval was rejected | `[digital-wallet-devops] CD failed: deploy-staging (main)` |
| A production deploy | `deploy-production` succeeded (the "Should" of the plan) | `[digital-wallet-devops] production now runs 3e8bbd8` |

The body names the failed jobs, lists the result of every job, and gives the branch or pull request, who
triggered the run, the commit (with a link) and the run's URL.

### How it works

- **A final `notify` job in `ci.yml` and in `cd.yml`.** It lists every other job in `needs` and runs with
  `if: failure()`, so it starts when they have all finished and fires when any of them failed. `failure()` is false
  for a cancelled run, so a push that supersedes a run does not send an e-mail for the run it cancelled.
- **Where it does not run.** A pull request from a fork and a pull request that Dependabot opened get no OIDC
  token to give to AWS, so `ci.yml`'s notify job is left out for them (they still show red in GitHub). The job
  is not a required check.
- **One composite action, `.github/actions/notify`.** It assumes the notify role through OIDC (no stored key) and
  runs `scripts/notify.sh`, which builds the message and publishes it (40 tests in
  `scripts/tests/notify.test.sh`). If the two repository variables below are not set, it prints a warning on the
  run and sends nothing, so a failing run does not fail a second time.
- **Branch names are untrusted.** Branch names, pull request branches and actor names are chosen by whoever
  opens the pull request. They reach the script through the environment, never the command line, and the script
  removes line breaks and control characters (so a branch named `main` + newline + `Run: <their link>` cannot forge a
  line) and makes the subject printable ASCII cut to the 100 characters SNS accepts. Tested.
- **A notification that cannot be sent fails the notify job**, so a broken channel is seen.

### Set up once

1. Put your address in `infra/bootstrap/terraform.tfvars`, which git ignores (the variable is sensitive and has no
   default, so it never enters the repository): `alert_email = "you@example.com"`.
2. Apply bootstrap (4 resources to add: the topic, the subscription, the role and its policy):
   ```
   cd infra/bootstrap
   terraform plan
   terraform apply
   ```
3. **Confirm the subscription.** AWS sends "AWS Notification - Subscription Confirmation" to the address; follow
   the link in it. Until then the subscription is `PendingConfirmation` and **nothing is delivered**, with no error
   anywhere. Check with
   `aws sns list-subscriptions-by-topic --topic-arn <arn> --query 'Subscriptions[].SubscriptionArn'`: a pending one
   shows `PendingConfirmation` instead of an ARN.
4. Set the two repository variables (not secrets, and not environment-scoped, because a notify job has no
   environment):
   ```
   gh variable set NOTIFY_ROLE_ARN  --body "$(terraform -chdir=infra/bootstrap output -raw github_notify_role_arn)"
   gh variable set NOTIFY_TOPIC_ARN --body "$(terraform -chdir=infra/bootstrap output -raw pipeline_alerts_topic_arn)"
   ```

### Decisions

- **The topic is in bootstrap, not in an environment, and is not the alarm topic.** The plan said to publish to
  "the SNS topic you already create for alarms". There is none yet (monitoring is Part 3), and one per
  environment would be destroyed with staging every day. A recreated e-mail subscription has to be confirmed again
  by clicking a link, so notifications would stop after every rebuild, and a failed pull request has to be reported
  when no environment is up at all. Bootstrap is applied once and outlives every environment, like the OIDC provider.
- **The topic uses the AWS-managed key (`alias/aws/sns`).** It is free, and checkov wants topics encrypted. The key's
  policy, read in this account, allows any principal in the account that may use SNS to publish through SNS, so the
  publisher role needs `sns:Publish` and nothing for KMS. **This key cannot be used for CloudWatch alarms**:
  CloudWatch cannot be granted use of an AWS-managed key, so the alarm topic needs a customer-managed key, or none. It
  has none (see [Alarms and notifications](#alarms-and-notifications-step-37)).
- **The role trusts two token subjects**, in the immutable form (see
  [GitHub Actions deploy roles](#github-actions-deploy-roles-oidc)): a run on `main`
  (`...:ref:refs/heads/main`, which is `cd.yml`) and a pull request of this repository (`...:pull_request`, which is
  `ci.yml`). It belongs to no environment because a notify job has none. All it can do is `sns:Publish` to the one
  topic, so a pull request that rewrote the workflow could do no more than send e-mail to the owner.
- **Rejecting a production deployment sends an e-mail, cancelling the run does not.** A rejected deployment is a
  failed job, so `failure()` is true. To dismiss a run that waits for an approval without an e-mail, cancel the run.

### Test it

The plan's test is a pull request with a deliberately failing test. Branch from `main`, add a test that fails
(for example `expect(1).toBe(2)` in a new file under `app/backend/src`), open a **draft** pull request, wait for
`unit-tests` to fail, and check for the e-mail, which arrives within a minute or so of the `notify` job. Then close
the pull request without merging and delete the branch. To test `cd.yml`'s notice, reject the production
deployment of a run that waits for approval.

### Checked (2026-11-11)

Both paths were run for real, and both e-mails were received in the inbox (not the spam folder).

- **`ci.yml`, a pull request.** A draft pull request (#60, closed without merging) added a test that fails on
  purpose. Only `unit-tests` failed, the other eight jobs passed, and `notify` ran for 9 seconds. It assumed the
  role through OIDC with the `pull_request` subject and sent `[digital-wallet-devops] CI failed: unit-tests (PR #60)`
  with every job's result, the pull request, branch, actor, commit link and run link.
- **`cd.yml`, a run on `main`.** The production deployment of a waiting run was rejected. `deploy-production` failed,
  `notify` assumed the role with the `ref:refs/heads/main` subject and sent
  `[digital-wallet-devops] CD failed: deploy-production (main)`, and `announce-production` was skipped, as it
  should be. This is the case the "Rejecting a production deployment sends an e-mail" note above describes.
- **SNS** counted 2 messages published and 0 failed.

**Not checked:** the e-mail for a successful production deploy (it needs production to be applied), and the two
conditions that leave `ci.yml`'s notify job out for a fork's and a Dependabot pull request, which only a real one
of those would exercise.

### Not done

- **Slack.** Not wanted.
- **Rate limiting or a digest.** Every failed run sends one e-mail.
- **E-mail for a failed run of a fork's or Dependabot's pull request**, for the reason above.
- **A second subscriber.** Add another `aws_sns_topic_subscription`, or subscribe by hand in the console.

## Hardening (step 2.8)

The plan asks for four things: actions pinned to full commit SHAs, least-privilege permissions per job, no
long-lived cloud keys with secrets and variables scoped to environments, and a concurrency group per environment.
Most of this was built in as the pipeline grew. This step audited it from the files, **turned the rules into an
automated check** so that they stay true, and **enforced two of them in GitHub's own settings**.

### Actions are pinned to full commit SHAs

Every third-party action in `.github/workflows/` and `.github/actions/` is pinned to a 40-character commit SHA, with
the version in a comment (`uses: actions/checkout@3d3c42e5... # v7.0.1`), and the scanner images are pinned by
digest. Local actions (`./.github/actions/...`) are in the repository itself.

**Why.** In March 2025 attackers modified the popular action `tj-actions/changed-files` and **retroactively repointed
existing version tags to a malicious commit**, so every workflow that referred to the action by a tag ran it. Between
14 and 15 March 2025 its script read secrets out of the runner's memory and printed them into the workflow logs, which
are public in a public repository. GitHub's advisory says the action was used by over 23,000 repositories (the potential
reach, not the number of victims) and that the fix is version 46.0.1. CISA wrote that it was potentially enabled by a
compromise of another action, `reviewdog/action-setup@v1` (CVE-2025-30154), and added both CVEs to its Known Exploited
Vulnerabilities catalog on 26 March 2025. Sources: GitHub's advisory
[GHSA-mrrh-fwg8-r2c3](https://github.com/advisories/GHSA-mrrh-fwg8-r2c3) (CVE-2025-30066) and
[CISA's alert](https://www.cisa.gov/news-events/alerts/2025/03/18/supply-chain-compromise-third-party-tj-actionschanged-files-cve-2025-30066-and-reviewdogaction).
A tag can be moved after you have reviewed it. A commit SHA cannot.

**What pinning does not do.** It protects you from a tag that is moved later. It does not help if the commit you
pinned was already bad, and it does not cover what a pinned action downloads while it runs (the attack fetched its
script from a gist). Dependabot bumps the pins weekly, in one pull request, so read that diff and be wary of an
action whose maintainer you do not know. The other layers below, no stored keys and read-only tokens, limit what a bad
action could take.

**Three layers keep it true:**

1. **A check on every pull request.** `scripts/check-workflows.sh` runs in the `lint` job (see below), so an unpinned
   action is caught in the pull request, with the file and line, before anything runs. It also covers the composite
   action files.
2. **GitHub's own setting, "Require actions to be pinned to a full-length commit SHA"**, turned on for the
   repository in this step (`sha_pinning_required`; [GitHub's announcement](https://github.blog/changelog/2025-08-15-github-actions-policy-now-supports-blocking-and-sha-pinning-actions/)).
   It is enforced when the workflow runs, so it also covers a workflow that nobody reviewed. Checked for real: a
   throwaway branch with a workflow that uses `actions/checkout@v4` failed at `Set up job` with
   *"The action actions/checkout@v4 is not allowed in MihirBhavsar3102/digital-wallet-devops because all actions must
   be pinned to a full-length commit SHA."*, and its steps never ran. The branch was deleted.
3. **Dependabot** keeps the pins current, so that pinning does not mean never updating.

### `scripts/check-workflows.sh`: the rules, as a check

It reads every workflow and composite action and reports each problem as `file:line: what is wrong` (39 tests,
mutation-checked, and run on this repository's own workflows too):

| # | Rule | Why |
|---|------|-----|
| 1 | Every `uses:` is a local action, a Docker image by digest, or an action pinned to a full 40-character SHA | a tag or branch can be moved |
| 2 | Every workflow declares top-level `permissions` | the token is never given the repository's default silently |
| 3 | Those grant no write access, and there is no `write-all` anywhere | a job that needs more asks for exactly that on the job |
| 4 | No `pull_request_target` | it runs with secrets and a write token on code from a fork |
| 5 | No long-lived AWS keys (`aws-access-key-id`, `secrets.AWS_*`, ...) | the pipeline uses OIDC and a role |
| 6 | Every `actions/checkout` sets `persist-credentials: false` | otherwise the token stays in the git config for later steps to read |

It reads lines, not YAML, which is enough because the files are regular and means it needs only bash and awk.

### Least privilege, per job

The repository's default token is read-only (`default_workflow_permissions: read`, and Actions cannot approve pull
requests), checked in the settings. Every workflow declares `contents: read` at the top (rules 2 and 3), and a job
that needs more asks for it itself. The only extra permission anywhere is `id-token: write`, which a job needs to
trade GitHub's token for AWS credentials:

| Workflow | Jobs | Permissions |
|----------|------|-------------|
| `ci.yml` | `changes`, `lint`, `unit-tests`, `integration-tests`, `dependency-scan`, `secret-scan`, `image-build-scan`, `iac-checks`, `script-tests` | `contents: read` only: nothing in CI can reach AWS |
| `ci.yml` | `notify` | `id-token: write`, only when a job failed |
| `cd.yml` | `build-and-push`, `deploy-staging`, `deploy-production` | `id-token: write`, each in its own GitHub Environment |
| `cd.yml` | `notify`, `announce-production` | `id-token: write` |
| `rollback.yml` | `rollback`, `notify`, `announce-production` | `id-token: write`; `rollback` in the environment that was chosen |

No job has `contents: write`, `pull-requests: write`, `packages: write` or any other write permission, because nothing in
the pipeline pushes to the repository, comments on pull requests or publishes a package.

### No long-lived cloud keys, and nothing secret to scope

- **No AWS key exists anywhere.** Every job that reaches AWS assumes a role through OIDC and gets credentials that
  last about an hour. The deploy roles trust one GitHub Environment each, and the notify role trusts a run on `main`
  and a pull request, all in the immutable subject form (see
  [GitHub Actions deploy roles](#github-actions-deploy-roles-oidc)). Rule 5 stops a key from being added.
- **The repository has no secrets at all**, at the repository level or in either environment (`gh secret list` is
  empty for all three), and no workflow refers to `secrets.`. There is no Slack webhook because e-mail was chosen,
  and the AWS access is OIDC. If one is ever added, it belongs in the environment that uses it.
- **Variables are scoped to the environment that owns them.** None is a secret.

| Scope | Variables |
|-------|-----------|
| Environment `staging` | `AWS_ROLE_ARN`, `AWS_REGION`, `NAME_PREFIX`, `ALB_URL` |
| Environment `production` | `AWS_ROLE_ARN`, `AWS_REGION`, `NAME_PREFIX`, `SOURCE_NAME_PREFIX` (`ALB_URL` is set when production is applied) |
| Repository | `NOTIFY_ROLE_ARN`, `NOTIFY_TOPIC_ARN`: the notify jobs have no GitHub Environment, so they cannot read an environment's variables |

### One deploy at a time per environment

Two deploys to one environment can never overlap, at three levels:

1. **GitHub:** the groups `deploy-staging` and `deploy-production` (`cancel-in-progress: false`), used by the deploy jobs
   of `cd.yml` **and** by `rollback.yml` (`group: deploy-${{ inputs.environment }}`). A deploy that has started is never
   cancelled, and of the runs queued for one environment only the newest waits. `build-and-push` has no group on purpose:
   every commit pushes its own tag.
2. **SSM:** `ssm-deploy.sh` sends the command with `--max-concurrency 1`, so the instances of one environment are updated
   one at a time.
3. **The instance:** `deploy.sh` holds a lock (`flock`), so a second deploy on the same instance fails instead of
   overlapping.

### GitHub settings changed in this step

| Setting | Before | After | Why |
|---------|--------|-------|-----|
| Require actions to be pinned to a full-length commit SHA | off | **on** | enforced when the workflow runs, see above |
| Approval for workflow runs from forks | first-time contributors | **all external contributors** | the repository is public: nobody outside runs a workflow on its runners without a person approving it |
| Environment `staging`: deployment branches | any branch | **`main` only** | the staging role trusts any job in the environment, so a workflow on another branch that named `staging` could use it. `production` was already limited to `main` |

Already right and left as they were: the read-only default token, Actions not being allowed to approve pull requests,
and production's required reviewer.

### Not done

- **Pinning the OIDC trust to the workflow file.** The roles trust a repository and an environment, and GitHub's
  token also carries a `job_workflow_ref` claim (which workflow file, at which ref). Requiring it, for example
  `cd.yml` and `rollback.yml` at `refs/heads/main` for the deploy roles, would stop any other workflow that reaches
  the environment from using the role. It is a change to the IAM trust policies, so it needs an apply.
- **Watching the runner's network.** The tj-actions attack was detected by a tool that flags unexpected outbound calls
  from the runner (the payload fetched a script from `gist.githubusercontent.com`). The runners here are GitHub's, with no
  egress filtering.
- **A second reviewer** for production (above).

## Monitoring and logging (Part 3)

Everything is CloudWatch and everything is Terraform, in `infra/modules/monitoring/` (the database's own log
groups and enhanced monitoring stay in the `rds` module, because they must exist before the instance). One
limit to keep in mind when reading the dashboards: the load balancer's metrics show request rate, errors and
latency **at the edge**, as the client sees them, not timings inside the application code.

| What the assignment asks for | Where it comes from | Step |
|------------------------------|---------------------|------|
| CPU, memory, disk of the instances | `AWS/EC2` CPU, and the CloudWatch agent for memory and disk (EC2 does not report them) | 3.2 |
| Request rate, error rate, latency | `AWS/ApplicationELB` metrics, error rate by metric math | 3.4 |
| Database metrics | `AWS/RDS`, enhanced monitoring, Performance Insights | 3.5 |
| Application, system and access logs | the log groups below | 3.1 to 3.3 |
| Dashboards, saved queries, alarms | `observability` module | 3.6, 3.7 |

### Log groups (step 3.1)

Terraform creates four log groups per environment, named `/<name_prefix>/<kind>`, with `retention_in_days` set from
`log_retention_days` (14 days in staging, 90 in production):

| Log group | What goes in | Written by |
|-----------|--------------|------------|
| `/<name_prefix>/backend` | backend container output, one JSON object per line | Docker's `awslogs` driver (step 3.3) |
| `/<name_prefix>/frontend` | nginx: the JSON access log and the error log | Docker's `awslogs` driver (step 3.3) |
| `/<name_prefix>/syslog` | `/var/log/syslog` of each instance | the CloudWatch agent (step 3.2) |
| `/<name_prefix>/auth` | `/var/log/auth.log` of each instance | the CloudWatch agent (step 3.2) |

**Why Terraform creates them.** A log group that is left to be created by the first write (by the agent or by the
Docker driver) never expires, and keeps costing money for as long as the account exists. Created here, each one has
its retention from the start, and `terraform destroy` removes it with the environment. The two database groups
(`postgresql` and `upgrade`) are created the same way in the `rds` module. The load balancer's access logs go to an
S3 bucket with their own expiry (see [Access logs](#access-logs)).

**Checked:** `terraform validate` in both environments, tflint and checkov (0 failed), and a plan against staging: 4
log groups to create with 14 day retention, and `app_log_group_names` in the outputs.

**Checked on staging (2026-11-12):** after the apply, the four groups exist with `retentionInDays` 14, and `terraform
plan` reported `No changes`, so staging was exactly `main`.

### CloudWatch agent (step 3.2)

EC2 reports CPU on its own, but **not memory or disk**, so each instance runs the CloudWatch agent. Its
configuration is written by hand in [`monitoring/cloudwatch-agent.json`](monitoring/cloudwatch-agent.json).

| What | Setting | Why |
|------|---------|-----|
| Metrics | `cpu` (`usage_active`), `mem` (`used_percent`), `disk` (`used_percent`, the root filesystem `/` only) | the three the assignment asks for; the other mounts are tmpfs and the like |
| Namespace | `CWAgent` | the agent's default |
| Interval | 60 seconds | EC2's own CPU metric is every 5 minutes unless detailed monitoring is paid for, so the agent's CPU is the one-minute view |
| Dimension | `AutoScalingGroupName`, and nothing else; `aggregation_dimensions` rolls the disk metric up to it | instances are replaced often, so a per-instance dimension would start a new series each time and every alarm and dashboard would have to chase it. The group's name is stable. The cost: the graphs are for the group (average and maximum over its instances), and to look at one instance you read its log stream, named after the instance ID |
| Logs | `/var/log/syslog` to `/<name_prefix>/syslog`, `/var/log/auth.log` to `/<name_prefix>/auth`, stream = instance ID | the system and authentication logs |
| Retention | not set in the file | Terraform owns it (step 3.1). The agent stops if two places set different retention for one group |

**How an instance gets it.** The monitoring module stores the file, with the two log group names filled in by
`templatefile()`, in a Parameter Store parameter called `AmazonCloudWatch-<name_prefix>-agent`. The name has to start
with `AmazonCloudWatch-` because the AWS-managed `CloudWatchAgentServerPolicy` on the instance role lets the agent
read exactly those parameters (checked in the policy document), so the IAM module did not change. `user_data`
installs the agent and runs `amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c ssm:<parameter>`, which loads
the parameter and starts (and enables) the agent. It also installs `rsyslog`, so that the two log files exist whatever
the image includes. The agent's own variable, `${aws:AutoScalingGroupName}`, is written `$${aws:AutoScalingGroupName}`
in the file so that Terraform does not try to fill it in.

**Starting the agent is allowed to fail.** `user_data` stops at its first error, and an instance that never finishes
booting is replaced by one that fails the same way (see [Boot without the Snap store](#boot-without-the-snap-store)).
So a failed start only prints a line to the boot log and the instance serves traffic without metrics. The memory and
disk alarms of step 3.7 treat missing data as a problem, so someone is told.

#### Changing the agent configuration

Edit the file and run `terraform apply`: only the parameter changes, so no instance is replaced. The instances are
not told, so make them fetch it again with AWS's own Run Command document:

```sh
aws ssm send-command --document-name AmazonCloudWatch-ManageAgent \
  --targets Key=tag:Role,Values=app \
  --parameters action=configure,mode=ec2,optionalConfigurationSource=ssm,optionalConfigurationLocation=AmazonCloudWatch-<name_prefix>-agent,optionalRestart=yes
```

(In Git Bash set `MSYS_NO_PATHCONV=1` first.) An instance that boots later reads the new version by itself. If the
agent does not start, `amazon-cloudwatch-agent-ctl -m ec2 -a status` shows its state and
`/opt/aws/amazon-cloudwatch-agent/logs/configuration-validation.log` says what is wrong with the configuration.

#### Checked, and not yet

- **`scripts/tests/agent-config.test.sh`** (14 checks, in the `script-tests` job) renders the file the way Terraform
  does and checks what the dashboards and alarms rely on: valid JSON, the namespace, the single dimension, the three
  collectors, the root-only disk, both log files in their own groups, no retention. Each check was shown to fail on
  a deliberately broken copy (a wrong namespace, an unescaped agent variable, `*` for the disk, swapped log groups,
  a retention period, a trailing comma).
- **A plan against staging** (76 to add, 0 to change): the parameter is valid JSON of 1032 characters (the Standard
  tier allows 4096) with `${aws:AutoScalingGroupName}` intact, and the log groups are the right ones.

#### Checked on a live instance (2026-11-12)

On a freshly built staging instance, one minute after it booted, and again over the next ten minutes:

- **The boot ran the agent.** The boot trace shows the `fetch-config ... -c ssm:AmazonCloudWatch-digital-wallet-staging-agent`
  line, and `amazon-cloudwatch-agent-ctl -m ec2 -a status` says `running` and `configured`; the service is active and
  enabled. The agent's own log says it is piping `/var/log/syslog` and `/var/log/auth.log` to the two groups with
  `retention -1`, meaning it leaves the retention alone: the groups still have Terraform's 14 days.
- **The log files exist on Ubuntu 26.04.** `rsyslog` 8.2512 was installed by `user_data` and both files are there.
- **Metrics arrive with the dimension the alarms need.** Under `CWAgent`: `mem_used_percent {AutoScalingGroupName}`;
  `disk_used_percent` twice, the raw series `{path=/, AutoScalingGroupName, device, fstype}` and the rolled-up series
  `{AutoScalingGroupName}` that `aggregation_dimensions` produces (the alarms and dashboards use the rolled-up one);
  and `cpu_usage_active` under `{AutoScalingGroupName}` and `{AutoScalingGroupName, cpu=cpu-total}`. **The CPU metric
  showed up about eight minutes after the agent started, later than memory and disk** (it is computed from two
  samples, and CloudWatch can take minutes to list a new metric), so a graph has a gap at the start.
- **Log lines arrive.** Both streams are named after the instance ID and hold events from the instance's first boot
  (the agent reads a file from its start): systemd and `useradd` lines for the system log and the auth log.
- **Not checked:** what the agent does after a reboot, and the alarms on missing metrics (step 3.7).

### Application and access logs (step 3.3)

Three kinds of log lines reach CloudWatch, all as one JSON object per line, so that Logs Insights, a metric filter
and `docker logs | jq` can read the fields:

| Log | Written by | Log group |
|-----|------------|-----------|
| Backend: application and request lines | the NestJS backend, to stdout | `/<name_prefix>/backend` |
| Frontend: the access log, and nginx's error log | the nginx container (JSON access log since step 2.1; the error log goes to stderr) | `/<name_prefix>/frontend` |
| Load balancer access log | the load balancer, to S3 (see [Access logs](#access-logs)) | the S3 bucket, not CloudWatch |

#### The backend's logs

NestJS's default logger prints coloured text, and the version used here (10.4) has no JSON mode, so
`app/backend/src/common/` has two small pieces and no new dependency:

- **`json-logger.ts`** replaces Nest's logger (`NestFactory.create(AppModule, { logger })`), so Nest's own startup lines
  and every `Logger` call in the code come out as JSON. A line has `time`, `level` (`info`, `warn`, `error`, `debug`,
  `verbose`, `fatal`), `context` and `message`; an `Error` adds its `stack`, kept inside the one line. A plain object
  passed as the message has its fields written at the top level, which is how the request line below gets its fields.
  It never throws: a circular object or a failing output must not break the request being logged.
- **`request-logger.ts`** is a middleware that writes one line when each response has finished:

```json
{"time":"2026-11-12T05:20:37.229Z","level":"warn","context":"http","message":"request completed","requestId":"3d072fc3-ef39-437b-8062-e4e77b733dfc","method":"GET","path":"/api/accounts/my-accounts","status":401,"durationMs":2.12}
```

  - The **level follows the status**: 5xx is `error`, 4xx `warn`, anything else `info`. The CloudWatch error metric of
    step 3.4 counts the `error` lines, so a wrong password is not an application error and a failed database call is.
  - The **request ID** is the caller's `X-Request-Id` when it is short and made of letters, digits, `.`, `_` and `-`,
    and a new UUID otherwise (so a caller cannot put a line break or a megabyte into the log). It is also returned in
    the response header. The load balancer's own `X-Amzn-Trace-Id` is logged beside it as `traceId`, to find the same
    request in the load balancer's access log.
  - The **path has no query string**, because a query can carry a token.
  - **A healthy `/api/health` is not logged.** The load balancer calls it every few seconds from each of its nodes and
    those lines would drown the real requests. An unhealthy answer is logged.
- Two upstream lines were plain text and are now JSON as well: the guard's `console.error('JWT verification failed:',
  err)`, which printed the whole error over several lines on every bad token, is one `warn` line with the reason (a
  bad token is the caller's mistake, not a server error, and the token is never logged: tested); and
  `UsersController initialized`.

A database failure gives two `error` lines, Nest's own for the exception (with its stack) and the request line with
`"status":500`. To read the logs live: `MSYS_NO_PATHCONV=1 aws logs tail /<name_prefix>/backend --follow` (Git Bash
rewrites a leading `/`).

#### Getting the containers' output to CloudWatch

`deploy.sh` writes the compose file, and each service now has `logging: driver: awslogs`, with the region, the log
group, and the **instance ID as the stream name** (so the same instance has the same stream name in all four groups).
The values come from `/opt/app/instance.env`, which `user_data` writes (the instance ID, and the two group names that
Terraform passes in); `deploy.sh` stops by name if one is missing.

- **Non-blocking delivery** (`mode: non-blocking`, `max-buffer-size: 4m`). Docker's default is blocking, and then a
  container that writes to stdout while CloudWatch cannot be reached stalls. Non-blocking keeps a 4 MB buffer and drops
  messages when it is full, which is the right trade for a log (checked in Docker's documentation).
- **The driver runs in the Docker daemon on the host, so it uses the instance role** (`CloudWatchAgentServerPolicy`
  allows `logs:CreateLogStream` and `logs:PutLogEvents`). No container has AWS credentials, which fits the metadata
  hop limit of 1.
- **The groups must exist before the container starts**: the driver is not told to create them
  (`awslogs-create-group` defaults to false), and Terraform creates them with their retention (step 3.1). A container
  whose group is missing does not start, which fails the deploy and its health check, not silently.
- `docker logs` and `docker compose logs`, which `deploy.sh` prints when a deploy fails, still work.

#### Checked, and not yet

- **Backend:** 66 unit tests (34 before, 32 new: the logger, the request logger and the guard's warning). The real
  backend was run against a throwaway PostgreSQL and called with `curl`. The first run showed one plain-text line
  left (`UsersController initialized`), which is why that line was changed. After that, a run with startup, a 401, a
  bad token and a database outage had no line that was not JSON, a healthy `/api/health` was silent, a bad token gave
  a `warn` line with no token in it, a rejected request ID was replaced, and stopping the database gave the two
  `error` lines.
- **`deploy.sh`:** 37 tests (11 new). Each new check was shown to fail on a broken copy (no non-blocking mode, the
  frontend writing to the backend's group, `INSTANCE_ID` not exported to compose, the guard removed, a different
  driver). One of the first checks turned out to pass even with a variable missing, because `grep -q` with several
  patterns means "any of them", so it now requires every one. The real `docker compose config` resolves the
  generated file's `logging:` block.
- **`user_data`:** rendered with test values, it passes `bash -n`, and the section that writes `instance.env` was run
  with a stubbed metadata service: the file has the instance ID and both group names and can be sourced under `set -u`.
  A plan against staging: 76 to add, 0 to change.

#### Checked on a live instance (2026-11-12)

The release was deployed by re-running the CD run for `main` (after pointing `ALB_URL` at the rebuilt load balancer,
see [After a rebuild of staging](#after-a-rebuild-of-staging)), then six requests were sent through the load balancer.

- **The daemon accepts the options.** `docker inspect` shows both containers with the `awslogs` driver and exactly
  `awslogs-group`, `awslogs-region`, `awslogs-stream` (the instance ID), `mode: non-blocking` and `max-buffer-size: 4m`.
- **The backend group.** 36 events in ten minutes, **none that is not JSON**. The request with a made-up
  `X-Request-Id` came back with it, a rejected token produced one `warn` line without the token, the query string
  (`?token=SECRETQUERY`) was not in any line, and the two lines that mention `/api/health` are Nest's startup route
  mapping, so the health check itself is silent.
- **The frontend group** holds the request as a JSON line (with `x_forwarded_for`). Its non-JSON lines are nginx's
  own one-time startup messages (the entrypoint scripts and `[notice]` lines of the error log). **The load balancer's
  health check shows up here, 12 lines in 15 minutes**, which is noise; nginx could leave it out of the access log
  the way the backend does (not done).
- **The load balancer's access log reached S3** within five minutes (it is delivered in 5 minute batches), and the
  line for the 404 carries `Root=1-6af557ea-47b6c42570e5c327686e3f7b`, which is the `traceId` of the backend's line for
  the same request. So a request can be followed from the load balancer to the application.
- **A request that fails on purpose, with no debug route in the application:** `POST /api/auth/login` with an empty
  body `{}` makes Prisma throw, and the backend answers 500 and writes the two `error` lines (the exception with its
  stack, and the request line). Step 3.8 uses it for load.

**Size to watch.** `user_data` carries `deploy.sh` base64-encoded and EC2 allows 16 KB. It is about 12 to 14 KB now
(an upper bound; the plan cannot show the rendered value, because it depends on the database address), so
`deploy.sh` has room for about 2 KB more. If it runs out, the fix is `base64gzip()`, which cloud-init unpacks.

### Metrics: application and database (steps 3.4 and 3.5)

Almost every metric already exists, because AWS publishes it (the load balancer, the database, EC2) or because step
3.2 made the agent publish it. These two steps are about **choosing the right ones, knowing their exact names and
dimensions, and adding the two that did not exist**: an application error count, and the Auto Scaling group's own
metrics. The names and dimensions below were read from CloudWatch on live staging (2026-11-12), not copied from
documentation. Dashboards (3.6) and alarms (3.7) use exactly these.

| Question | Namespace and metric | Dimensions | Statistic |
|----------|----------------------|------------|-----------|
| Is a host busy? (1 minute) | `CWAgent` `cpu_usage_active` | `AutoScalingGroupName` | Average, Maximum |
| The same, from EC2 (5 minutes) | `AWS/EC2` `CPUUtilization` | `AutoScalingGroupName` | Average, Maximum |
| Is memory or disk filling up? | `CWAgent` `mem_used_percent`, `disk_used_percent` | `AutoScalingGroupName` | Average, Maximum |
| How much network? | `AWS/EC2` `NetworkIn`, `NetworkOut` | `AutoScalingGroupName` | Sum |
| How many instances are serving? | `AWS/AutoScaling` `GroupInServiceInstances` | `AutoScalingGroupName` | Average (**enabled in this step**) |
| Request rate | `AWS/ApplicationELB` `RequestCount` | `LoadBalancer` | Sum |
| Responses by class | `HTTPCode_Target_2XX_Count`, `_4XX_Count`, `_5XX_Count` | `LoadBalancer` and `TargetGroup` | Sum |
| Latency | `TargetResponseTime` | `LoadBalancer` and `TargetGroup` | p50, p95, p99 |
| Are targets healthy? | `HealthyHostCount`, `UnHealthyHostCount` | `TargetGroup` and `LoadBalancer` | Minimum, Maximum |
| Did the application log an error? | `<name_prefix>/Application` `ApplicationErrors` | none | Sum (**new in this step**) |
| Database load and room | `AWS/RDS` `CPUUtilization`, `FreeableMemory`, `FreeStorageSpace`, `DatabaseConnections`, `ReadIOPS`, `WriteIOPS`, `ReadLatency`, `WriteLatency`, `DiskQueueDepth` | `DBInstanceIdentifier` | Average |

The load balancer dimensions are the ARN suffixes the `alb` module already outputs (`app/<name>/<id>` and
`targetgroup/<name>/<id>`). Listings also show the identifiers of earlier, destroyed load balancers (three older ones
appeared), so dashboards and alarms always name the current one explicitly.

**One honest limit.** The `AWS/ApplicationELB` metrics are measured at the load balancer: request rate, status
codes, and how long the *target* took to answer. They say nothing about time spent inside the application code, and
`TargetResponseTime` is not what a browser sees (it leaves out the network to the user). Measuring inside the code
would need instrumentation, listed under "Not done" below.

#### Error rate, and why `FILL`

The error rate is `100 * FILL(HTTPCode_Target_5XX_Count, 0) / RequestCount`, a metric math expression. **A 5xx metric
does not exist until the first 5xx happens**: after ten minutes of traffic that included 404s and 401s, the listing
had `HTTPCode_Target_2XX_Count` and `_4XX_Count` but no `_5XX_Count`. Without `FILL(..., 0)` the expression has no data
at exactly the moment everything is healthy, and an alarm would sit in "insufficient data". When there is no traffic at
all, `RequestCount` is missing too, and the alarm has to treat that as fine (step 3.7).

#### The application error count

A metric filter on the backend group counts error-level lines into `ApplicationErrors`
(`<name_prefix>/Application`, one namespace per environment, because staging and production share an account and a
metric filter cannot carry a fixed dimension). It says something the load balancer cannot: **the application logged an
error**, including one that never became a 5xx.

**Why not simply count every error line.** The live logs showed that one failed request writes *two* `error` lines,
Nest's `ExceptionsHandler` line (with the stack) and the request logger's line for the 500 (`context: "http"`).
Counting both doubles every failure, and the 5xx rate is already measured at the load balancer. So the filter leaves
the `http` lines out:

```
{ ($.level = "error" || $.level = "fatal") && ($.context NOT EXISTS || $.context != "http") }
```

`NOT EXISTS` is there because a missing field makes `!=` false: a plain `$.context != "http"` would silently skip an
error line that has no context. The pattern was tested with `aws logs test-metric-filter` (a read-only call that
tests a pattern against sample lines) on the real lines in the backend group (about forty, from the live checks above)
plus a few synthetic ones: a `fatal`, an error with no `context`, and an `http` error with status 503:

| Pattern | Exception line | `http` 500 line | `fatal` | error with no context |
|---------|:--------------:|:---------------:|:-------:|:---------------------:|
| every error or fatal line | counted | **counted (double)** | counted | counted |
| `... && $.context != "http"` | counted | not counted | counted | **not counted (a gap)** |
| the pattern above | counted | not counted | counted | counted |

It counts one for each exception and nothing for 4xx, startup, or the health check.

#### Database metrics (step 3.5)

The metric names in the table were confirmed against `AWS/RDS` for the instance (the plan said to confirm them), along
with `DBLoad`, which Performance Insights adds. What was checked live: enhanced monitoring writes to the shared
`RDSOSMetrics` log group (30 day retention), Performance Insights is on, the monitoring interval is 60 seconds, and the
PostgreSQL log group has its stream. Slow queries (`log_min_duration_statement`, step 1.8) arrive in that group; no slow
query was run in this session.

#### The Auto Scaling group's metrics

The group's own metrics (the `AWS/AutoScaling` namespace) are off until enabled, and none existed. The compute module
now enables `GroupInServiceInstances`, `GroupDesiredCapacity` and `GroupTotalInstances` at one-minute granularity.
Dashboard 1 shows instances in service, and a drop in it is what an instance refresh or a failing boot looks like.
It is free, and a plan against live staging shows it as an in-place change of the group (no instance is touched).

#### Checked, and not yet

- **The filter pattern** against real log lines, as above. The first attempt used hand-written samples passed on the
  command line and disagreed with what the live `filter-log-events` returned for the same line, because Windows
  argument quoting had mangled a sample; it was redone with events pulled from CloudWatch and passed in a JSON file.
- **A plan against live staging:** 1 to add (the filter), 1 to change (the group, in place), 0 to destroy.
- **Not applied yet**, so not checked: that `ApplicationErrors` is published and that `GroupInServiceInstances` appears.
  After the apply, `POST /api/auth/login` with `{}` makes one failure that should add exactly 1 (not 2).

#### Not done

- **Instrumenting the application itself** (a Prometheus client with a `/metrics` route, or CloudWatch embedded
  metric format), which would give timings inside the code. It is the next improvement.
- **Per-route metrics.** The logs have `path` and `durationMs`, so Logs Insights can compute them (step 3.6), but there
  is no metric per route.

### Dashboards and saved queries (step 3.6)

Two CloudWatch dashboards and seven saved Logs Insights queries, all Terraform, in `infra/modules/observability/`.
After an apply, `terraform output dashboard_urls` prints the console links. Each panel is titled as the question it
answers, a threshold that has an alarm is drawn on the panel as a red horizontal line (from the same variable the
alarm uses, `alarm_thresholds`), and all panels share one default time range (3 hours) and a 60 second period, except
the EC2 metrics, which AWS publishes every 5 minutes.

**Why a module of its own.** The dashboards need the Auto Scaling group, the load balancer and the database, and the
compute module already takes its log group names from `monitoring`. Putting the dashboards in `monitoring` made the two
modules refer to each other. Terraform accepted that and `plan` was clean, but **checkov silently stopped checking one
IAM policy**: its total fell from 309 to 299 passed checks with 0 failed, so the gate got weaker and stayed green
(challenges log, row 20). `observability` is called last and only reads from the other modules, and checkov is back to
309 / 0 / 59, identical to `main`.

**Dashboard 1, `<name_prefix>-infrastructure`:** *Are the instances busy?* (CPU %, average and busiest, alarm line) ·
*Is memory running out?* · *Is the disk filling up?* · *How much data moves in and out?* · *How many instances are serving
traffic?* (in service against wanted) · *Are the instances passing EC2's own health checks?* · then the database: *Is the
database busy?* (CPU %) · *How many connections are open?* · *Is it short of memory?* · *How much storage is left?* (alarm
line at 2 GiB) · *How much I/O is it doing?* · *How long do reads and writes take?* · *Is I/O queuing up?* · *How busy is it
overall?* (Performance Insights `DBLoad`).

**Dashboard 2, `<name_prefix>-application`:** *How much traffic is there?* · *What is being returned?* (2xx, 4xx and 5xx per
minute) · *What share of requests fail?* (the `FILL` formula of [Metrics](#error-rate-and-why-fill), alarm line at 5%) ·
*How long does the API take to answer?* (p50, p95 and p99 of the backend target, alarm line on p95) · *Are the targets
healthy?* (both target groups) · *Is the application logging errors?* (the metric of step 3.4) · and three tables from the
backend log: *What went wrong most recently?*, *Which endpoints are slowest?* (p95) and *Which endpoints fail?*.

**Saved queries**, named `<name_prefix>/<name>` in the Logs Insights console (the dashboard's tables run the same text, so
the two cannot drift apart). The time range is picked in the console, so "in the last hour" means setting 1h.

| Query | Answers |
|-------|---------|
| Backend errors | the error and fatal lines, newest first (the exception and its request line) |
| Slowest requests | the 20 slowest single requests, with their request ID |
| Slowest paths (p95) | count, average, p95 and maximum duration per path |
| Failed requests by path (4xx and 5xx) | which endpoints fail, and how |
| 5xx by path | only our failures, by path and status |
| Failed application logins | requests to `/api/auth/login` that did not succeed |
| Failed authentication on the host (auth.log) | failed, denied or invalid authentication lines in `auth.log` |

There is no SSH here (access is through SSM), so the last query finds failed authentication on the host (PAM, `sudo`),
not failed SSH logins.

**Cost.** Two dashboards per environment, so four if production is ever applied. AWS's pricing page says how many a
free account gets; that was not checked here.

#### Checked, and not yet

- **CloudWatch accepted both dashboard bodies.** Terraform cannot validate them, so a malformed widget would only fail
  at the apply. `put-dashboard` validates the schema without the metrics needing to exist: both bodies were accepted
  with no validation messages (16 and 11 widgets, 24 and 15 metric series), under a temporary name that was deleted
  straight after (none left).
- **All seven queries ran on live staging** and completed. The numbers agree with what had been done: the two deliberate
  500s show up on `/api/auth/login` in every query that should see them (4 `error` lines for 2 failures, 2 in *5xx by
  path*, 3 in *Failed application logins*, which counts the 401 as well). *Failed authentication on the host* returned no
  rows, which is right (nothing has failed to authenticate); to prove its case-insensitive regex works, the same form of
  filter was run against lines that do exist (`NEW USER` matched `new user`).
- **A plan against live staging:** 9 to add (2 dashboards, 7 queries), 0 to change, 0 to destroy. Checkov and tflint clean.
- **Not applied yet.** After the apply the panels should be checked with real data: the CloudWatch agent and Auto
  Scaling series, the load balancer series, and the database series.

### Alarms and notifications (step 3.7)

Ten CloudWatch alarms in `infra/modules/observability/alarms.tf`, all notifying one SNS topic by e-mail, **when an alarm
goes into ALARM and again when it recovers** (not on "insufficient data", which would be noise).

#### Where the topic lives, and what to apply

The plan puts the alarm topic inside the environment. It is in `infra/bootstrap/` instead, next to the pipeline topic,
for the reason that topic already documents: **an e-mail subscription that is recreated has to be confirmed again by
clicking a link, and staging is destroyed and rebuilt every day**. A topic inside the environment would need a new
confirmation after every rebuild. This one is confirmed once, and staging and production both publish to it (every alarm
name starts with its environment's name). The environments find it by name (`data "aws_sns_topic"`), so no ARN is
committed.

The address is the bootstrap variable `alarm_email` (sensitive, validated), kept in the git-ignored
`infra/bootstrap/local.tfvars`. Order:

1. `cd infra/bootstrap && terraform apply -var-file=local.tfvars`: creates the topic and the subscription (plan: 2 to
   add). AWS then sends a **"Subscription Confirmation" e-mail: click its link once**. Until then nothing is delivered.
2. Then apply the environment as usual. Without the topic its plan stops with `reading SNS Topic
   (digital-wallet-alarms): empty result`, on purpose (checked).

The topic has **no encryption**. CloudWatch cannot be granted use of the AWS-managed SNS key, so encrypting it would need
a customer-managed key whose policy allows CloudWatch, and a mistake in that policy fails silently: the alarm cannot
publish and nobody is told. The messages hold an alarm name, a metric and a threshold (accepted finding `CKV_AWS_26`).

#### The alarms

The thresholds are one variable, `alarm_thresholds`, and the dashboards draw the same numbers as a red line. They are
**starting points to tune once there is a baseline**. The p95 latency (1 second) is a placeholder until step 3.8 measures
one.

| Alarm | Fires when | Missing data |
|-------|------------|--------------|
| `ec2-cpu-high` | agent CPU, average, above 80% for 2 x 5 minutes | not breaching |
| `ec2-memory-high` | memory used above 85% for 2 x 5 minutes | **breaching** |
| `ec2-disk-high` | root disk above 80% for 2 x 5 minutes | **breaching** |
| `alb-5xx-rate-high` | `100 * FILL(5xx, 0) / RequestCount` above 5% for 5 one-minute periods in a row | not breaching |
| `api-latency-p95-high` | p95 of the backend's `TargetResponseTime` above 1 s for 2 x 5 minutes; too few samples are ignored | not breaching |
| `alb-backend-unhealthy-hosts`, `alb-frontend-unhealthy-hosts` | one or more unhealthy targets for 3 minutes in a row | not breaching |
| `application-errors` | the error metric of step 3.4 is 1 or more in 5 minutes | not breaching |
| `rds-cpu-high` | database CPU above 80% for 2 x 5 minutes | **breaching** |
| `rds-free-storage-low` | free storage below 2 GiB for 2 x 5 minutes | **breaching** |

**`treat_missing_data` is chosen for each alarm, because "no data" means different things.** *Breaching* where the metric
should always exist: memory and disk (the agent can fail to start without failing the boot, see
[CloudWatch agent](#cloudwatch-agent-step-32), so its silence has to alarm) and the database (RDS always publishes). *Not
breaching* where an idle system publishes nothing: no requests means no latency and no 5xx rate, and no errors means no
data point. The CPU alarm is *not breaching* because the memory and disk alarms already cover a silent agent. One false
alarm to expect: replacing the only staging instance leaves a gap in the agent's metrics, so memory and disk can alarm once
after a change to the launch template.

#### Test the path

After the apply and the confirmation, force a state and check that the e-mail arrives (it returns to OK by itself at the
next evaluation, which sends the recovery e-mail):

```sh
aws cloudwatch set-alarm-state --alarm-name digital-wallet-staging-application-errors \
  --state-value ALARM --state-reason "testing the notification path"
```

#### Checked, and not yet

- **A plan of the alarms** in a throwaway root with the real staging values: 19 to add (2 dashboards, 7 queries, 10
  alarms), the ten names as above. A plan of `infra/bootstrap`: 2 to add (the topic and the subscription), 0 to change.
- **CloudWatch accepted the two unusual alarm shapes** under temporary names, deleted straight after: the metric math
  one with `FILL` (5 of 5 periods, not breaching) and the percentile one (p95, low samples ignored). The first attempt at
  the percentile one failed on my own typo of the CLI flag, which is singular, `--evaluate-low-sample-count-percentile`;
  the Terraform argument is plural, and `validate` accepted it.
- **checkov** is at 318 passed, 0 failed, 60 skipped (`main`: 309 / 0 / 59): nothing from `main` was lost, each alarm adds
  one check, and the one new skip is the documented topic.
- **Not applied yet**, so not checked: that the subscription is confirmed, that an alarm e-mail arrives, and that
  `set-alarm-state` works end to end.

#### Not done

- **Encrypting the topic** with a customer-managed key (above).
- **An alarm-status panel** on the dashboard, and composite alarms (for example one that pages only when the 5xx rate
  and the unhealthy hosts are both bad).
- **A topic per environment.** Production alarms go to the same address as staging's.

## Credits

The application in `app/` is [tedrosdev/digital-wallet](https://github.com/tedrosdev/digital-wallet),
imported at upstream commit `011bd00b2e43aee3c9f955b4bd84b73ac40338b7` (2024-12-23). The first commit
in this repository is that import, with file contents unchanged, so every later commit shows what
was changed on top of it. Its original README is kept at `app/UPSTREAM_README.md`.

Licence note: the upstream README says the project is MIT-licensed and links to a `LICENSE` file, but
no `LICENSE` file exists in the upstream repository, and its `backend/package.json` declares
`"license": "UNLICENSED"`. No licence text has therefore been copied here.
