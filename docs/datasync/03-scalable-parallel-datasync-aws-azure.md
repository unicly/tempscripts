# Scalable, parallel AWS DataSync replication between AWS and Azure (data lake)

How to set up AWS DataSync for a data lake with **many replication jobs running in parallel**, in both
directions (AWS → Azure and Azure → AWS).

Background on the agent and the network: [`01-…md`](01-datasync-azure-aws-private-network.md),
[`02-…md`](02-datasync-replication-aws-azure-network-auth.md).

> A design based on the DataSync docs. Not tested. ⚠️ marks limits to check in your account's
> **Service Quotas** and the current docs.

## Short answer

With DataSync, **scaling means scaling agents**. An agent runs **one task at a time**, and further tasks
that use it wait in a queue ⚠️. So for many parallel replications you build an **agent pool**: several
agent VMs in Azure. You then spread your **tasks** across them and start them from an **orchestrator**
with controlled parallelism.

## Target architecture

```
                          AWS (one account + region for the replication)
  EventBridge Scheduler ─► Step Functions (Map state, MaxConcurrency = N)
                               │ StartTaskExecution (per dataset & direction)
                               ▼
  DataSync service ── VPC endpoint (PrivateLink) ── VPN / ExpressRoute ⇄ Direct Connect
        │                                                        │
  S3 buckets (lake, AWS-owned + replicas)                        ▼
                                              Azure VNet
                                                ├─ agent-01 … agent-N  (VM pool, DataSync agents)
                                                └─ private endpoints → ADLS / Blob (Azure-owned + replicas)
```

## Building blocks and how they scale

| Element | Rule | How to use it for scale |
|---|---|---|
| **Agent** (Azure VM) | Runs **one task at a time** ⚠️. Tied to one account, region and endpoint type | Parallelism ≈ **number of agents**. Start with 4–8 agents, add more when tasks queue up |
| **Location** | Each Azure Blob location lists **1 to 4 agents** ⚠️. S3 locations need no agent | Create **one Azure location per container or prefix**, each with its **own subset of agents** |
| **Task** | One source → one destination, one direction | **One task per dataset per direction** (e.g. per table folder) |
| **Task execution** | Queued if its agents are busy | Control parallelism in the orchestrator, not by hoping for free agents |
| **Account quotas** ⚠️ | Limits on tasks per account and concurrent executions | Check and raise them in **Service Quotas** before the rollout |

Since the **location** decides which agents run a task, you steer parallelism by giving different
locations different agents:

```
agent-01, agent-02  →  location az-sales-container      → tasks: sales/* (both directions)
agent-03, agent-04  →  location az-finance-container    → tasks: finance/*
agent-05, agent-06  →  location az-hr-container         → tasks: hr/*
agent-07, agent-08  →  location az-bulk-container       → big initial loads
```

## Setup step by step

| Step | What | Details |
|---|---|---|
| 1 | **Network** | ExpressRoute ⇄ Direct Connect for large volumes. A VPN is fine for moderate volumes, but VPN gateways cap throughput ⚠️. DataSync **VPC endpoint** in AWS, **private endpoints** for the storage accounts in Azure, DNS forwarding in both directions |
| 2 | **Agent pool** | N Linux VMs from the DataSync Hyper-V image in the Azure VNet, sized at least 4 vCPU / 32 GB RAM, more for millions of files ⚠️. Activate each one with the **VPC endpoint**, in the **same** AWS account and region |
| 3 | **Identities** | **IAM role** for DataSync on the S3 buckets (with KMS permissions if used). **SAS tokens** per container (read for source use, write for destination use), stored and rotated, for example via Secrets Manager plus a rotation job ⚠️ |
| 4 | **Locations** | S3 locations per bucket or prefix. Azure Blob locations per container or prefix, each assigned its agent subset |
| 5 | **Tasks** | Per dataset and direction. Options: transfer mode **changed files only**, keep or mirror deletes, **include filters** per folder, verification on transferred files only, **task reports** to S3, CloudWatch logs, bandwidth limit if the link is shared |
| 6 | **Orchestration** | **EventBridge Scheduler** starts a **Step Functions** workflow. A **Map** state over the dataset list calls `StartTaskExecution` with **`MaxConcurrency` = number of agents**, waits for each execution to finish, and retries on failure |
| 7 | **Ordering for tables** | Delta: copy data files first, then `_delta_log/`, as two tasks or two filtered executions. Iceberg: run `rewrite_table_path` first, then copy with a **manifest** of exactly the listed files |
| 8 | **Monitoring** | CloudWatch metrics (bytes, files, duration), alarms on failed executions and on queue time, task reports for audit |
| 9 | **Infrastructure as code** | Terraform or CloudFormation for locations, tasks and the Step Functions workflow. Agents are activated once, then referenced by ARN |

## Example: creating the pieces (AWS CLI)

```bash
# Azure location served by two agents (destination for AWS→Azure, source for Azure→AWS)
aws datasync create-location-azure-blob \
  --container-url https://lakeacct.blob.core.windows.net/sales \
  --authentication-type SAS --sas-configuration Token="<sas-token>" \
  --agent-arns arn:aws:datasync:eu-west-1:111122223333:agent/agent-01 \
               arn:aws:datasync:eu-west-1:111122223333:agent/agent-02

# S3 location (no agent needed)
aws datasync create-location-s3 \
  --s3-bucket-arn arn:aws:s3:::lake-aws --subdirectory /sales \
  --s3-config BucketAccessRoleArn=arn:aws:iam::111122223333:role/datasync-s3

# Task: AWS → Azure, only changed files, keep deletes mirrored
aws datasync create-task \
  --source-location-arn <s3-location-arn> \
  --destination-location-arn <azure-location-arn> \
  --name sales-orders-aws-to-azure \
  --options TransferMode=CHANGED,PreserveDeletedFiles=REMOVE,VerifyMode=ONLY_FILES_TRANSFERRED,LogLevel=BASIC \
  --includes FilterType=SIMPLE_PATTERN,Value="/orders/*"
```

## Example: Step Functions with bounded parallelism (excerpt)

```jsonc
"SyncAll": {
  "Type": "Map",
  "ItemsPath": "$.tasks",
  "MaxConcurrency": 8,
  "Iterator": { "StartAt": "Start", "States": {
    "Start": { "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:datasync:startTaskExecution",
      "Parameters": { "TaskArn.$": "$.taskArn" }, "Next": "Wait" },
    "Wait":  { "Type": "Wait", "Seconds": 60, "Next": "Check" },
    "Check": { "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:datasync:describeTaskExecution",
      "Parameters": { "TaskExecutionArn.$": "$.TaskExecutionArn" }, "Next": "Done?" },
    "Done?": { "Type": "Choice", "Choices": [
      { "Variable": "$.Status", "StringEquals": "SUCCESS", "Next": "Ok" },
      { "Variable": "$.Status", "StringEquals": "ERROR",   "Next": "Fail" } ], "Default": "Wait" },
    "Ok": { "Type": "Succeed" }, "Fail": { "Type": "Fail" } } }
}
```

## Both directions

| Point | Design |
|---|---|
| Same agents for both directions | ✅ An Azure location can be the source of one task and the destination of another |
| Ownership | Each dataset has **one owner cloud**. Task names and filters make the direction explicit, for example `…-aws-to-azure` and `…-azure-to-aws` |
| Replica areas | Replicas in separate prefixes or containers (`replica_aws/`, `replica_azure/`). **Never** select a replica area as a source |
| SAS permissions | Read SAS on Azure-owned containers (Azure → AWS), write SAS on replica containers (AWS → Azure) |
| Egress | AWS bills AWS → Azure, Azure bills Azure → AWS. Only changed files are transferred |

## Scaling guidelines

| Symptom | Action |
|---|---|
| Executions often **queued** | Add agents, and spread locations over more agent subsets |
| One huge dataset is slow | Split it into several tasks by prefix, and give its location up to 4 agents ⚠️ |
| Network saturated | ExpressRoute / Direct Connect capacity, or a bandwidth limit per task during business hours |
| Long **Preparing** phase (many files) | Narrower tasks (filters per folder), more agent memory, or **Enhanced mode** ⚠️ (check agent and VPC endpoint support for Azure Blob) |
| Quota errors | Raise DataSync quotas in Service Quotas ⚠️ |

## Sizing example (starting point)

| Element | Starting point |
|---|---|
| Agents | 8 VMs in Azure (D8s/E8s class), activated against one AWS region with the VPC endpoint |
| Locations | About 4 agent groups, each with 2 agents |
| Tasks | One per table folder and direction |
| Orchestration | Step Functions with `MaxConcurrency` 8, run hourly or nightly |
| Network | ExpressRoute ⇄ Direct Connect |

Then tune by watching queue time and throughput.

## Related

- [`01-datasync-azure-aws-private-network.md`](01-datasync-azure-aws-private-network.md): private network setup and how the agent works
- [`02-datasync-replication-aws-azure-network-auth.md`](02-datasync-replication-aws-azure-network-auth.md): network path, authentication, sharing agents
- [`../iceberg/08-incremental-rewrite-table-path-explained.md`](../iceberg/08-incremental-rewrite-table-path-explained.md): Iceberg file lists for DataSync manifests

## Sources

- [AWS DataSync: Configuring transfers with Microsoft Azure Blob Storage](https://docs.aws.amazon.com/datasync/latest/userguide/creating-azure-blob-location.html)
- [AWS DataSync: Using multiple agents for a location](https://docs.aws.amazon.com/datasync/latest/userguide/multiple-agents.html)
- [AWS DataSync: Starting a task (queueing)](https://docs.aws.amazon.com/datasync/latest/userguide/run-task.html)
- [AWS DataSync: Choosing a service endpoint for your agent](https://docs.aws.amazon.com/datasync/latest/userguide/choose-service-endpoint.html)
- [AWS DataSync: CreateLocationAzureBlob API](https://docs.aws.amazon.com/datasync/latest/userguide/API_CreateLocationAzureBlob.html)
- [AWS Step Functions: Map state](https://docs.aws.amazon.com/step-functions/latest/dg/state-map.html)
- [AWS Step Functions: AWS SDK service integrations](https://docs.aws.amazon.com/step-functions/latest/dg/supported-services-awssdk.html)
- [AWS Storage blog: Best practices for setting up your DataSync agent](https://aws.amazon.com/blogs/storage/best-practices-for-setting-up-your-aws-datasync-agent/)
