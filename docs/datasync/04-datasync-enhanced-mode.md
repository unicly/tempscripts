# AWS DataSync Enhanced mode

What Enhanced mode is, how it differs from Basic mode, what it supports (including Azure Blob since
July 2026), and what it means for scalable AWS ⇄ Azure replication
([`03-…md`](03-scalable-parallel-datasync-aws-azure.md)).

> From AWS docs and announcements plus a few third-party guides. Not tested. ⚠️ marks points that are
> unconfirmed, come from third parties, or where AWS sources disagree.

## Short answer

DataSync tasks run in one of two **task modes**:

- **Basic mode:** the original engine. Steps run **one after another** (prepare → transfer → verify),
  with limits on the number of files per task. Supports **every** location type.
- **Enhanced mode:** newer engine. **Lists, prepares, transfers and verifies in parallel**, handles
  **virtually unlimited objects** per execution, and gives more detailed reports. Supports a growing
  set of locations. Since **July 2026** it also supports **Azure Blob, HDFS and self-managed object
  storage with an agent**, including agents on **Hyper-V**.

For a large data lake with many files, Enhanced mode is usually the better choice, if your locations
and options are supported.

## Basic vs. Enhanced

| | Basic mode | Enhanced mode |
|---|---|---|
| How a run works | Prepare (scan and compare everything) → transfer → verify, **sequentially** | Listing, preparing, transferring and verifying **in parallel** (streaming) |
| Scale | Quotas on files/objects per task (a third party cites ~50 million ⚠️) | **Virtually unlimited** objects per execution |
| Performance | Slower start for many files (long Preparing phase) | Faster, especially with many small files |
| Supported locations | **All** DataSync location types | S3 ↔ S3, other clouds ↔ S3, NFS/SMB ↔ S3, and (July 2026) Azure Blob, HDFS, self-managed object storage with an agent |
| Agents | Basic mode agent (VMware, KVM, Hyper-V, EC2) | **Separate Enhanced mode agent** type ⚠️. Some transfers (e.g. S3 ↔ S3, some other-cloud transfers) need **no agent** |
| Agents per location | Up to 4 | Up to 4 (separate from Basic agents) |
| Verification | Verify transferred files, verify all, or none | Verify **transferred data only** ⚠️ (third party) |
| Bandwidth limit | ✅ | ⚠️ Reported as not available (third party). Check before relying on throttling |
| Reports | Task reports | More detailed task reports and metrics |
| Pricing | Per GB transferred | Per GB (higher rate) **plus a fee per task execution** ⚠️ (a third party cites $0.015/GB + $0.55 per execution vs. $0.0125/GB for Basic; check the AWS pricing page) |
| Choosing it | Task mode is set when you **create the task** ⚠️ (likely can't be changed afterwards; create a new task to switch) | Same |

## Azure Blob in Enhanced mode

| Point | Detail |
|---|---|
| Agentless | Older AWS docs: Azure Blob ↔ S3 in Enhanced mode **without an agent**. The DataSync service reaches the storage account's **public endpoint** (not usable if public access is disabled) |
| With an agent (July 2026) | Enhanced mode **agents** now support Azure Blob (to and from), plus HDFS and self-managed object storage. Agents can run on **Hyper-V**, so they can be deployed in Azure via the Hyper-V image. Available in all regions where DataSync is offered |
| Private network | DataSync supports **VPC endpoints**. With a VPC endpoint, **all agents of a location must use the same endpoint and subnet**. ⚠️ Not explicitly confirmed for Enhanced mode Azure Blob agents yet |
| Hyper-V setup | ⚠️ Enhanced mode Hyper-V deployment steps not found yet. Basic mode uses a `.vhdx` image, converted to VHD for Azure |
| Agent availability | All agents of a location must be **online** before a task starts. Several agents don't give high availability |

## What it means for a scalable data lake setup

| Topic | Effect of Enhanced mode |
|---|---|
| Many files per dataset | No long scan phase, no per-task file limit, so fewer, larger tasks are possible |
| Parallel jobs | Each execution is internally parallel. ⚠️ Whether an Enhanced mode agent can run **several tasks at the same time** isn't confirmed. Plan as in doc 03 (one task per agent at a time) until verified |
| Private AWS ⇄ Azure path | Use **Enhanced mode agents** in Azure with a VPC endpoint (July 2026). Check that your region and options support it |
| Throttling during business hours | ⚠️ May not be available. Use network-level limits or schedules instead |
| Cost | Per-execution fee: many small, frequent executions cost more. Prefer fewer, larger executions |
| Delta / Iceberg ordering | Unchanged: copy data before `_delta_log`. Use manifests or filters for Iceberg file lists |

## How to use it

```bash
# Task in Enhanced mode (TaskMode is set at creation) ⚠️ check parameter support for your locations
aws datasync create-task \
  --source-location-arn <s3-location-arn> \
  --destination-location-arn <azure-blob-location-arn> \
  --task-mode ENHANCED \
  --name sales-orders-aws-to-azure-enh \
  --options TransferMode=CHANGED,VerifyMode=ONLY_FILES_TRANSFERRED \
  --task-report-config '…'
```

**Checklist before switching a data lake to Enhanced mode:**

1. Are all your **location types** supported in Enhanced mode, in your region?
2. Do you need a **private path**? Then deploy **Enhanced mode agents** in Azure (Hyper-V image) with the VPC endpoint, and test it.
3. Do you rely on **bandwidth limits** or **"verify all"**? Then check that they're available, or keep those tasks in Basic mode.
4. Calculate cost with the **per-execution fee** for your schedule.
5. Run one dataset in both modes and compare duration, cost and reports.

## Related

- [`01-datasync-azure-aws-private-network.md`](01-datasync-azure-aws-private-network.md): private network and how the agent works
- [`02-datasync-replication-aws-azure-network-auth.md`](02-datasync-replication-aws-azure-network-auth.md): network path, authentication, sharing agents
- [`03-scalable-parallel-datasync-aws-azure.md`](03-scalable-parallel-datasync-aws-azure.md): scalable parallel setup

## Sources

- [AWS DataSync: Choosing a task mode for your data transfer](https://docs.aws.amazon.com/datasync/latest/userguide/choosing-task-mode.html)
- [AWS DataSync: How DataSync works](https://docs.aws.amazon.com/datasync/latest/userguide/how-datasync-transfer-works.html)
- [AWS What's New (July 2026): Enhanced mode adds HDFS, Azure Blob and object storage locations with Hyper-V agent support](https://aws.amazon.com/about-aws/whats-new/2026/07/aws-datasync-hdfs-azure-blob-hyper-v/)
- [Amazon (China): Enhanced mode adds agent-based support for HDFS, Azure Blob and self-managed object storage](https://www.amazonaws.cn/en/new/2026/datasync-enhanced-mode-adds-agent-based-support/)
- [AWS DataSync: Deploying your agent](https://docs.aws.amazon.com/datasync/latest/userguide/configure-agent.html)
- [AWS DataSync FAQs](https://aws.amazon.com/datasync/faqs/)
- [AWS DataSync pricing](https://aws.amazon.com/datasync/pricing/)
- [Amazon DataSync increases performance and scalability for data transfers (Enhanced mode launch)](https://www.amazonaws.cn/en/new/2024/amazon-datasync-increases-performance-and-scalability-for-data-transfers/)
- [AWS re:Post: Optimizing DataSync costs – transfer modes and S3 storage classes](https://www.repost.aws/articles/ARCAC7G_T3S1yp89X1l7wLmg/optimizing-aws-datasync-costs-a-strategic-guide-to-transfer-modes-and-amazon-s3-storage-classes)
- [MigrationCost: DataSync pricing, Basic vs Enhanced (third party)](https://migrationcost.com/aws-datasync-pricing)
- [Tutorials Dojo: AWS DataSync cheat sheet (third party)](https://tutorialsdojo.com/aws-datasync/)
