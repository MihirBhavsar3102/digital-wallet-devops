# Backup strategy and restore drill

What is backed up, for how long, how to get it back, and what a restore drill on staging measured on
2026-11-12. Numbers come from that drill; anything not measured is marked as such.

## What is backed up

| What | How | Kept for | Where it is set |
|------|-----|----------|-----------------|
| **Database, automated** | RDS daily snapshot plus transaction logs, which gives point-in-time restore | Staging 1 day, production 7 days (RDS allows up to 35) | `db_backup_retention_period` in `staging.tfvars` and `prod.tfvars` |
| **Backup window** | 21:00 to 21:30 UTC, which is 02:30 to 03:00 IST. The weekly maintenance window is Sunday 22:00 to 23:00 UTC, so they do not overlap | n/a | `backup_window` and `maintenance_window` in `infra/modules/rds/variables.tf` |
| **Database, before every production deploy** | `cd.yml` takes a manual snapshot named `digital-wallet-prod-pre-<tag>-<run id>-<attempt>` and waits for it to be available before deploying | Until deleted: **keep the newest 5, delete older ones by hand** (command below) | `deploy-production` job, step 4 |
| **Database, on destroy** | Production takes a final snapshot, `digital-wallet-prod-final`. Staging takes none | Until deleted | `skip_final_snapshot` follows `deletion_protection` |
| **Terraform state** | S3 versioning on the state bucket: every apply and lock change is a new version. `prevent_destroy` guards the bucket. It is encrypted, blocks public access and refuses non-TLS requests | Old versions expire after 90 days | `infra/bootstrap/main.tf` |

**Not backed up, on purpose.** The application instances are stateless: an Auto Scaling replacement boots from the
AMI and `user_data`, pulls the release recorded in the Parameter Store entry `/<name_prefix>/deployed-tag` from ECR,
and reads its secrets from Secrets Manager. The container images are the artefact kept in ECR (the last 10 per
repository), and the code and Terraform are in git. So there is nothing on a host worth a snapshot. Logs are in
CloudWatch and S3 with their own retention and are not restored from backup.

**Not done:** an AWS Backup plan and vault, copying snapshots to another region or account, and automatic pruning
of the pre-deploy snapshots. All three cost money or code and were left out; see
[APPROACH.md](APPROACH.md#what-i-would-do-with-more-time).

Two limits to know. Destroying a database also deletes its automated backups (the AWS provider's default), so only
manual and final snapshots survive a destroy. And **production has never been applied**, so its 7 day retention and
its pre-deploy snapshot step are configured and tested against fakes, not exercised; the drill below ran on staging,
whose settings are the same except for retention (1 day) and Multi-AZ (off).

## Restore procedure (what the drill did)

A restore always creates a **new** instance; it never overwrites the running one. Give it the same subnet group,
security group and parameter group as the source, and keep it private, or the application cannot reach it.
Names below are staging's.

```
# 1. Find the restore window and the snapshots.
aws rds describe-db-instance-automated-backups --query 'DBInstanceAutomatedBackups[].[DBInstanceIdentifier,RestoreWindow]'
aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime]'

# 2a. Point in time. --use-latest-restorable-time restores to the latest restorable time, not "now" (see the
#     measurements); use --restore-time <UTC time> for an earlier point.
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier digital-wallet-staging-db \
  --target-db-instance-identifier digital-wallet-drill-pitr --use-latest-restorable-time \
  --db-instance-class db.t4g.micro --db-subnet-group-name digital-wallet-staging-db-subnets \
  --vpc-security-group-ids <db security group> --db-parameter-group-name <the source's> \
  --no-publicly-accessible --no-multi-az --no-deletion-protection

# 2b. Or from a snapshot (same options).
aws rds restore-db-instance-from-db-snapshot --db-snapshot-identifier <snapshot> \
  --db-instance-identifier digital-wallet-drill-snapshot --db-instance-class db.t4g.micro \
  --db-subnet-group-name ... --vpc-security-group-ids ... --db-parameter-group-name ... \
  --no-publicly-accessible --no-multi-az --no-deletion-protection

# 3. Wait for status "available", then connect from an app instance over SSM (the database has no public address).
aws rds wait db-instance-available --db-instance-identifier digital-wallet-drill-pitr
#    Read the password from the SECRET'S ARN, never print it; psql in a container, as in docs/REFERENCE.md.
#    select count(*) from "User"; select count(*) from "Account"; select count(*) from "Transaction";

# 4. Delete the drill instance (and any drill snapshot) when done.
aws rds delete-db-instance --db-instance-identifier digital-wallet-drill-pitr --skip-final-snapshot --delete-automated-backups
```

**To recover data** (a bad migration, deleted rows): restore as above, copy the rows you need across with
`pg_dump` and `psql` or `INSERT ... SELECT`, then delete the drill instance. This is the path the drill proved.

**To replace the live database** (not drilled): restore, point the application at the new endpoint, and bring
Terraform back in line (the restored instance is not managed by the RDS secret and not in the state under its new
name). This needs care and was not tried; treat it as a plan, not a tested procedure. Also untested: if RDS
rotated the master password between the snapshot and the restore, the restored instance has the password from the
snapshot time, which may no longer match the secret.

**Pruning the pre-deploy snapshots** (production; prints the ones beyond the newest 5, delete with
`aws rds delete-db-snapshot --db-snapshot-identifier <name>` after checking the list):

```
aws rds describe-db-snapshots --snapshot-type manual --query \
  "reverse(sort_by(DBSnapshots[?starts_with(DBSnapshotIdentifier, 'digital-wallet-prod-pre-')], &SnapshotCreateTime))[5:].DBSnapshotIdentifier" --output text
```

**Recovering the state file.** List the versions with `aws s3api list-object-versions --bucket <state bucket>
--prefix staging/terraform.tfstate`, download one with `aws s3api get-object --version-id <id>`, check it, and put
it back with `terraform state push`. The `get-object` step was checked (below); `state push` was not run.

## Restore drill, 2026-11-12 (staging, 20 GiB, `db.t4g.micro`, `ap-south-1`)

Both restores were run from the real staging database while a slow traffic loop kept writing to it (about 9
transactions a minute), then connected to and counted over SSM, then deleted.

| | Point in time | From a manual snapshot |
|---|---|---|
| Restore point | Latest restorable time at the request: 08:48:57 UTC (request sent at 08:56:32) | Snapshot consistent at 08:56:41 UTC |
| Taking the snapshot | n/a | 4 min 53 s (requested 08:56:34, available 09:01:27) |
| Restore request to status `available` | **14 min 35 s** (08:56:32 to 09:11:07) | **12 min 42 s** (09:13:34 to 09:26:16) |
| Rows restored (users, accounts, transactions) | 25, 48, 4,103 | 25, 49, 4,164 |
| Newest transaction in the restored copy | 08:48:53 | 08:56:17 |
| TLS on the connection | yes | yes |

The source held 25, 49 and 4,163 at 08:56 and 25, 49 and 4,299 at 09:11. So each restored copy holds data up
to its restore point: the newest transaction in each is just before the point, and nothing newer came back. Every row
was not compared, only the counts and the newest timestamps.

**Measured recovery objectives** (this size, this instance class, and only what the drill showed):

- **Recovery time:** about 13 to 15 minutes from the request to an available database. That does **not** include
  switching the application over, which was not measured, and a larger database will take longer.
- **Recovery point, point in time:** you can restore only up to the *latest restorable time*, which was
  **2 min 51 s to 7 min 35 s** behind the clock in six samples (6:18, 7:35, 3:16, 7:30, 2:51, 4:24). AWS describes
  this as typically about five minutes; here it was sometimes longer. `--use-latest-restorable-time` takes that
  stale point, not "now". The recovery point for a snapshot is the snapshot itself (here, taken on request).
- Staging keeps 1 day of point-in-time history, production 7 (configured, not exercised).

**What else the drill showed.**

- A restored instance starts its own first backup before it reports `available`: about 4.5 minutes of the totals above.
- A snapshot restore also applied the parameter group afterwards and rebooted (about 3 more minutes).
- The account is on the AWS free plan, which refuses a second extra RDS instance (`InstanceQuotaExceeded`), so the
  two restores ran one after the other. A real recovery in such an account needs the old instance deleted or renamed first.
- The automated snapshot of the deleted drill instance took about five minutes to disappear after deleting it with
  `--delete-automated-backups`. Afterwards nothing from the drill was left (instances, snapshots, backups).
- State: staging's state file had 125 versions; an older one (from 06:59 UTC) was downloaded and read back as a valid state file.
- Cost of the drill: two `db.t4g.micro` instances for about 17 and 15 minutes: a few cents.
