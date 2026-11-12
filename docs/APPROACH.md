# Approach

How the task was broken down, the order it was built in, the trade-offs, and what I would do with more time.
The setup guide is the [README](../README.md); the long build record is [REFERENCE.md](REFERENCE.md) and the
problems hit along the way are in [CHALLENGES.md](CHALLENGES.md).

## How I decomposed the task

The brief is four deliverables (Terraform, CI/CD, monitoring, documentation) on top of a ready-made application.
I split it by **what depends on what**, and made each piece small enough to build, check on a real AWS account and
merge on its own: one pull request per step, with `main` protected and all nine CI jobs required from step 2.2
onward.

1. **Setup.** Tool versions, the repository, a remote-state bucket, a first CI check. Nothing later works without
   somewhere safe to keep state and a way to reach AWS.
2. **Infrastructure (Part 1), bottom-up.** State, network, security groups, ECR and IAM, compute, load balancer,
   database, then variables and the two environments. Each layer only needs the one below it, so I could `plan`
   and apply each against staging and see it work before adding the next. Quality gates (fmt, tflint, checkov,
   gitleaks) went in before the code grew. Modules are generic; the only difference between staging and
   production is two small tfvars files.
3. **Delivery (Part 2).** Containerise the app first, because the pipeline has nothing to ship without images; then
   the pull-request checks, build and push, deploy to staging, the production gate, notifications, rollback and
   hardening. The deploy step was written against staging first and rehearsed end to end before anything touched
   the approval gate.
4. **Observability (Part 3).** Log groups and the agent first (nothing to graph without data), then application
   logs and metrics, the dashboards and saved queries, the alarms, and last a load test to give the alarm
   thresholds a measured baseline instead of guesses.
5. **Documentation (Part 4).** Written as I went, then cut down to a README that someone can follow in order.

## What shaped the design

- **Everything is checked, not just written.** Staging is destroyed and rebuilt daily, so the code has to be the
  infrastructure. A step is only finished when it has run against AWS, and what was *not* run is said so (production
  has never been applied; its deploy path was tested against fakes and plans only).
- **No long-lived secrets anywhere.** GitHub talks to AWS over OIDC, the database password is created by RDS and the
  JWT key by Terraform through a write-only argument, and the repository has no GitHub secrets at all. This cost
  real time: GitHub's immutable OIDC subject format broke the first login (CHALLENGES row 16).
- **Boot must not depend on a service I do not control.** On 2026-11-11 the Snap store was unreachable and stopped every new
  instance from booting (row 17), so the AWS CLI now comes from AWS's own installer and a failing boot is reported as
  a failing boot, not a failing deploy.
- **A green check must mean something.** A module cycle silently dropped ten checkov checks while the job stayed
  green (row 20); I compare per-check totals against `main` after restructuring modules.

## Trade-offs I made on purpose

| Chose | Gave up | Because |
|-------|---------|---------|
| Staging as the only environment applied for real | Proof that production deploys work end to end | Production is about $200 a month; its configuration is plan-checked and the scripts are tested, not exercised |
| HTTP on the load balancer | Encryption between browser and ALB | No domain, so no certificate. Disclosed |
| One AWS account | Blast-radius isolation | Not attempted; the OIDC roles are scoped by environment instead |
| Single NAT gateway in staging | Availability of staging's outbound traffic | Saves about $45 a month; staging is disposable |
| Cutting scope on application changes | A more realistic app | The app is the assignment's, not mine; I changed only what deployment, security and logging required |

## What I would do with more time

- **HTTPS**: a domain, an ACM certificate, a 443 listener with a redirect, and a WAF in front.
- **Apply production for real**, run the approval, promotion, snapshot and a production rollback once, and replace
  "tested against fakes" with evidence.
- **Separate AWS accounts** for staging and production, and a Terraform plan-and-apply pipeline with an approval
  instead of applying from a laptop.
- **Supply chain**: image signing, SBOMs, and pinning the OIDC trust to the workflow file.
- **Safer releases**: blue/green or canary, and Auto Scaling policies on the metrics already collected.
- **Secret-management write-up and proof** (planned step 4.2, deferred). The controls exist and are described in the
  README, but the write-up is not done: a repeatable check that searches the repository and the state for the password and
  shows that outputs hold only ARNs, how the JWT key would be rotated, and a limited-privilege application user.
- **Database password rotation**: today a running backend keeps the password it started with, so the backend needs
  a restart or deploy after each rotation. The fix is to re-read the secret when a connection fails (or use RDS
  Proxy), and an application database user with limited privileges instead of the master user.
- **Account-level audit**: a CloudTrail trail, GuardDuty and Config, VPC flow logs, and an AWS Budget with
  activated cost-allocation tags.
- **Tracing** in the application, so a slow request can be followed past the load balancer.

## Architecture decision records

One entry per decision: context, decision, alternatives, consequences.

### ADR 1: EC2 Auto Scaling group, not ECS or EKS

- **Context.** Two small containers (an nginx frontend and a NestJS backend) and one database, built and run by one person.
- **Decision.** Run both containers with Docker on EC2 instances in an Auto Scaling group behind an ALB, deployed through SSM.
- **Alternatives.** ECS on Fargate (no hosts to patch, per-task pricing); EKS (the most flexible, and by far the most to run).
- **Consequences.** Cheapest option, and the whole stack is visible and explainable (AMI, user data, instance profile,
  health checks). We own the host: patching, Docker, the agent and boot-time failures, which cost real hours (row 17).
  Moving to ECS later changes the compute module and the deploy script, not the network or the database.

### ADR 2: CloudWatch, not Grafana or Prometheus

- **Context.** The brief asks for logs, metrics, dashboards and alarms for an app whose infrastructure is all AWS.
- **Decision.** CloudWatch for all four: the agent for host metrics and logs, a metric filter for application errors,
  two dashboards, saved Logs Insights queries and ten alarms to an SNS e-mail.
- **Alternatives.** Self-hosted Grafana with Prometheus (richer dashboards and PromQL); a hosted Grafana.
- **Consequences.** Nothing extra to run, secure or pay for, and every AWS service already reports there; alarms
  were proven against real load. The cost is plainer dashboards and no application-level tracing.

### ADR 3: One directory per environment, not workspaces

- **Context.** Staging and production must differ in a few reviewable values and share all code.
- **Decision.** `infra/envs/staging` and `infra/envs/prod` call the same modules; their code files are byte-identical
  and only the state key and the tfvars differ (checked with `diff -rq`).
- **Alternatives.** Terraform workspaces with one folder and a variable file per workspace.
- **Consequences.** Each environment has its own state key and nobody can apply to the wrong workspace by forgetting
  to switch. Four files are duplicated, and the `diff` keeps that honest.

### ADR 4: SSM Run Command, not CodeDeploy

- **Context.** The instances are already managed by SSM (no SSH), and a deploy is "pull two images, run a script".
- **Decision.** The pipeline sends one `AWS-RunShellScript` command to the instances found by tag, one at a time, then
  smoke-tests through the load balancer and records the release in a Parameter Store entry that new instances read at boot.
- **Alternatives.** CodeDeploy (deployment groups, lifecycle hooks, traffic shifting); SSH from the runner.
- **Consequences.** No agent, application or deployment group to add, and the permission is a single tag-scoped
  `ssm:SendCommand`. We give up CodeDeploy's automatic rollback and traffic shifting; rollback is a manual workflow
  that redeploys an older tag, and it cannot undo database migrations.

### ADR 5: Secrets Manager, not Parameter Store

- **Context.** The database password and the JWT signing key must reach the containers without appearing in code, state or logs.
- **Decision.** The master password is an RDS-managed Secrets Manager secret (RDS creates and rotates it); the JWT key is a
  second secret that Terraform generates through a write-only argument. The instance role may read exactly those two by ARN.
- **Alternatives.** Parameter Store SecureString (cheaper, no rotation); a password passed as a variable (it would land in state).
- **Consequences.** The password is in no file and no state, and rotates on a schedule, for about $0.40 per secret
  per month. Rotation exposes a limit: a backend that is already running keeps its old password until it is restarted.

### ADR 6: HTTP, not HTTPS

- **Context.** There is no domain, and ACM will not issue a certificate for an `*.elb.amazonaws.com` name.
- **Decision.** Serve plain HTTP on port 80, say so in the README, and keep the database connection and all
  AWS-API traffic encrypted.
- **Alternatives.** A self-signed certificate (browser warnings, nothing a reviewer could trust); buying a domain for the assignment.
- **Consequences.** Traffic between a browser and the load balancer is not encrypted, so this is a demo, not a
  production posture. The fix is known and small: a domain, an ACM certificate, a 443 listener, a redirect and a 443 rule.
