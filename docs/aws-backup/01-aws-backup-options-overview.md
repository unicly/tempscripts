# AWS Backup: options and configurations at a glance

Short overview of what AWS Backup offers and what each option is used for.

> From AWS documentation and general knowledge. Not tested. ⚠️ marks newer features to check for
> availability in your region and for S3 specifically.

## Core building blocks

| Building block | What it is | Used for |
|---|---|---|
| **Backup plan** | A policy with one or more **rules** | Defines *when* and *how* backups are taken and kept |
| **Backup rule** | Schedule + window + lifecycle + copies, inside a plan | E.g. "daily at 01:00, keep 35 days, copy to eu-central-1" |
| **Resource assignment** | Which resources a plan covers: by **tags**, ARNs, resource type, conditions | Automatic protection of everything tagged `backup=daily` |
| **Backup vault** | Encrypted container where recovery points are stored (KMS key, access policy) | Separate storage, permissions and retention per purpose |
| **Recovery point** | One backup of one resource at one time | What you restore from |
| **On-demand backup** | A one-off backup outside any plan | Before a risky change or migration |

## Backup rule settings

| Setting | What it does | Used for |
|---|---|---|
| **Frequency / cron** | Hourly, daily, weekly, monthly, or a cron expression | Matching your recovery point objective (RPO) |
| **Backup window** | Start window and completion window | Running backups outside busy hours |
| **Continuous backup** (point-in-time recovery) | Restore to any second within up to **35 days** (S3, RDS, Aurora, SAP HANA…) | Lowest RPO; undo recent deletions or corruption |
| **Periodic snapshots** | Scheduled full/incremental recovery points with any retention | Long-term retention (months, years) |
| **Retention** | How long recovery points are kept | Compliance and cost control |
| **Lifecycle → cold storage** | Move recovery points to cheaper cold tier after N days (supported resource types only) | Cheap long-term retention |
| **Copy to another region / account** | Automatic copy of each recovery point | Disaster recovery, isolation from the main account |
| **Indexing for search** ⚠️ | Builds an index of backed-up items (S3, EBS) | Find and restore single files or objects later |

## Protection and immutability

| Option | What it does | Used for |
|---|---|---|
| **Vault access policy** | Resource policy on the vault (who may back up, restore, delete) | Deny deletes, restrict restores |
| **Vault Lock – governance mode** | Prevents deletion and shortening retention, except for privileged users | Protection against mistakes |
| **Vault Lock – compliance mode** | Immutable (WORM) after a grace period. Nobody, not even root or AWS, can delete or change it | Regulatory retention, ransomware protection |
| **Logically air-gapped vault** ⚠️ | Vault in an AWS-managed account, locked in compliance mode, shareable to other accounts | Recovering even if your own account is compromised |
| **Multi-party approval** ⚠️ | Several approvers needed to access an air-gapped vault from a recovery account | Recovery when the main account's admins are compromised |
| **Encryption** | KMS keys per vault (AWS-managed or customer-managed) | Data protection, separate keys per account |
| **Legal hold** | Keeps selected recovery points beyond their retention until released | Litigation, investigations |

## Restore options

| Option | What it does | Used for |
|---|---|---|
| **Full restore** | Restore the whole resource (new bucket, volume, DB…) or into the original | Disaster recovery |
| **Item-level restore** | Single objects, prefixes or files (S3, EFS, FSx…) | Recover only what was lost |
| **Point-in-time restore** | Any moment within the continuous backup window | Undo a deletion at 14:03 by restoring to 14:02 |
| **Restore to original or new location** | Overwrite in place, or restore next to it | Safe validation before switching |
| **Cross-account / cross-region restore** | Restore from a copy in another account or region | Recovering after a region or account loss |
| **Restore testing** | Scheduled automatic test restores, with validation hooks | Proving backups actually work (audits) |

## Governance, monitoring and audit

| Option | What it does | Used for |
|---|---|---|
| **AWS Organizations backup policies** | Central backup plans pushed to all accounts in an organization | Company-wide standards |
| **Delegated administrator** | A dedicated account manages backups for the organization | Separating backup admin from the management account |
| **Cross-account monitoring** | One view of all backup, copy and restore jobs | Central operations |
| **AWS Backup Audit Manager** | Frameworks and controls (e.g. "all resources backed up daily, retained 35 days") with daily reports | Compliance evidence |
| **Notifications** | Job events to SNS / EventBridge, metrics in CloudWatch | Alerting on failed backups or restores |
| **Malware scanning** (with GuardDuty) ⚠️ | Scans recovery points for malware | Pick a clean recovery point after an attack |

## Supported resources (selection)

S3, EBS, EC2, EFS, FSx, RDS, Aurora, DynamoDB, DocumentDB, Neptune, Redshift, Timestream, SAP HANA on
EC2, Storage Gateway, CloudFormation stacks, and on-premises VMware via **Backup gateway**.

## For S3 specifically

| Point | Detail |
|---|---|
| Requirement | **S3 versioning** on the bucket ⚠️ |
| Continuous | Point-in-time restore within 35 days. One plan per bucket for continuous backup |
| Periodic | Longer retention (snapshots) |
| Restore | Whole bucket, prefix or single objects, to the original or a new bucket |
| Not supported | Objects in Glacier Flexible Retrieval / Deep Archive |

For using AWS Backup with Iceberg and Delta tables, see
[`../iceberg/19-backup-managed-iceberg-with-aws-backup.md`](../iceberg/19-backup-managed-iceberg-with-aws-backup.md)
and [`../delta/02-backup-delta-with-aws-backup.md`](../delta/02-backup-delta-with-aws-backup.md).

## Costs (what you pay for)

Backup storage (GB-month, warm and cold), restores (per GB for some resources), cross-region copy
data transfer, continuous backup storage, Audit Manager evaluations, restore testing jobs.

## Sources

- [AWS Backup: What is AWS Backup?](https://docs.aws.amazon.com/aws-backup/latest/devguide/whatisbackup.html)
- [AWS Backup: Amazon S3 backups](https://docs.aws.amazon.com/aws-backup/latest/devguide/s3-backups.html)
- [AWS Backup: Restoring a continuous backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/point-in-time-recovery-restoring.html)
- [AWS Backup: Vault Lock](https://docs.aws.amazon.com/aws-backup/latest/devguide/vault-lock.html)
- [AWS Backup: Logically air-gapped vault](https://docs.aws.amazon.com/aws-backup/latest/devguide/logicallyairgappedvault.html)
- [AWS Backup: Restore testing](https://docs.aws.amazon.com/aws-backup/latest/devguide/restore-testing.html)
- [AWS Backup: Audit Manager](https://docs.aws.amazon.com/aws-backup/latest/devguide/aws-backup-audit-manager.html)
- [AWS Backup pricing](https://aws.amazon.com/backup/pricing/)
