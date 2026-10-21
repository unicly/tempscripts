# File replication between AWS and Azure with Databricks Lakeflow (classic compute)

How to replicate **files** between S3 and ADLS in **both directions** using **Lakeflow Jobs** on
**classic compute**, with Databricks on both clouds. Covers network (private), authentication, copy
methods, parallelism and orchestration. This is the Databricks counterpart of the DataSync study
([`../datasync/03-…md`](../datasync/03-scalable-parallel-datasync-aws-azure.md)).

> A design based on Databricks and Microsoft docs. Not tested. ⚠️ marks points that are unconfirmed or
> could change. Check them in your workspaces.

## Short answer

- **Lakeflow Jobs** is the orchestrator: schedule, **for-each** task with `concurrency`, job clusters
  (classic compute), retries, alerts. **Lakeflow Declarative Pipelines** and **Lakeflow Connect** build
  **tables**, not file copies, so they're not the right tool to replicate raw files.
- **Key constraint:** Unity Catalog on **Azure Databricks can read S3 but not write to it** (S3 support is
  read-only). Databricks on **AWS has no Unity Catalog credential for ADLS** (none found in the docs ⚠️).
- So use a **pull model: each cloud's workspace reads the remote cloud and writes locally.**

| Direction | Runs on | Reads remote with | Writes locally with | Governed by Unity Catalog? |
|---|---|---|---|---|
| **AWS → Azure** | **Azure** workspace | UC **S3 external location (read-only)**, IAM role | UC ADLS external location (access connector) | ✅ Fully |
| **Azure → AWS** | **AWS** workspace | **Entra service principal** (OAuth, secret in a secret scope), Spark config on **dedicated** classic compute | UC S3 external location (IAM role) | ⚠️ Remote read **not** governed by UC |
| Azure → AWS, tables only | AWS workspace | **Delta Sharing** (Databricks-to-Databricks) from the Azure metastore, then `DEEP CLONE` | UC | ✅ |

## Target architecture

```
              AWS                                                       Azure
 ┌──────────────────────────────────┐                     ┌──────────────────────────────────┐
 │ Databricks AWS workspace         │                     │ Azure Databricks workspace       │
 │  Lakeflow Job: azure_to_aws      │                     │  Lakeflow Job: aws_to_azure      │
 │  classic job cluster (dedicated) │                     │  classic job cluster             │
 │  in customer-managed VPC         │                     │  in VNet injection               │
 │      │ writes   ▲ S3 interface ◄─┼── VPN / ExpressRoute ⇄ Direct Connect ──┼─ reads S3       │
 │      ▼          │ endpoint       │                     │      │ writes                    │
 │  S3 (lake + replica_azure/)      │──── reads ADLS ────►│  private endpoint → ADLS          │
 │                                  │  (private endpoint) │  (lake + replica_aws/)            │
 └──────────────────────────────────┘                     └──────────────────────────────────┘
   Control plane: back-end PrivateLink (both sides), secure cluster connectivity (no public IPs)
```

## 1. Network (private, no public internet)

| Element | AWS side | Azure side |
|---|---|---|
| Workspace compute | **Customer-managed VPC**, secure cluster connectivity, **back-end PrivateLink** to the control plane | **VNet injection**, secure cluster connectivity (no public IP), **back-end Private Link** |
| Cross-cloud link | VPN gateway or **Direct Connect** (via a partner/interconnect to ExpressRoute) | VPN gateway or **ExpressRoute** |
| Remote storage reachable privately | **S3 interface endpoint** (PrivateLink) in the AWS VPC, reachable from Azure over the link | **Private endpoints** for the storage account (`dfs` **and** `blob`), reachable from AWS over the link |
| Local storage | S3 gateway endpoint for the AWS cluster | Private endpoints for the Azure cluster |
| DNS from the other cloud | Route 53 Resolver **inbound** endpoint: Azure forwards `s3.<region>.amazonaws.com` to it | Azure DNS Private Resolver **inbound** endpoint: AWS forwards `dfs.core.windows.net` / `blob.core.windows.net` (privatelink zones) to it |
| Block public paths | Bucket policy `aws:sourceVpce`, no internet route for storage | Storage account **public network access disabled** |
| Egress cost | AWS → Azure billed by AWS | Azure → AWS billed by Azure |

Things to check ⚠️:

- **Unity Catalog control plane access:** creating or validating an external location is done from the
  Databricks **control plane**, not your cluster. A storage firewall can block it. On Azure, allow the
  **access connector** as a resource instance (trusted service). On S3, an `aws:sourceVpce`-only bucket
  policy may break validation of the S3 external location in the Azure workspace. Test it.
- **S3 from Azure:** with **private DNS** on the S3 interface endpoint, regional names such as
  `bucket.s3.<region>.amazonaws.com` resolve to private IPs from Azure via the forwarder. Check which
  endpoint name the cluster actually uses.
- Throughput depends on the link (VPN gateways cap bandwidth). Use ExpressRoute ⇄ Direct Connect for large
  volumes.

## 2. Authentication

| Access | Identity | Setup |
|---|---|---|
| Azure workspace **reads S3** | UC **storage credential = IAM role** (self-assuming, cross-account trust with external ID), marked **read-only** | Role in the bucket's account with `s3:GetObject`, `s3:ListBucket`, `s3:GetBucketLocation`, KMS decrypt if used. Bucket: **no ACLs, no dots** in the name. Then an **S3 external location** + `GRANT READ FILES` |
| Azure workspace **writes ADLS** | **Access connector** (managed identity) | `Storage Blob Data Contributor` on the replica container. UC external location + `WRITE FILES` |
| AWS workspace **writes S3** | UC storage credential = IAM role | `PutObject`, `DeleteObject`, `ListBucket` on `replica_azure/`. External location + `WRITE FILES` |
| AWS workspace **reads ADLS** | **Entra service principal** (client secret or certificate) | `Storage Blob Data Reader` on Azure-owned containers. Secret in a **Databricks secret scope**. Spark config on a **dedicated** (single-user / service principal) job cluster, see below ⚠️ |
| Job runs as | **Service principal** in each workspace (`run_as`) | Grant it the UC privileges above, and access to the secret scope |

Spark config for the AWS cluster (cluster-level, values from the secret scope):

```
fs.azure.account.auth.type.lakeacct.dfs.core.windows.net OAuth
fs.azure.account.oauth.provider.type.lakeacct.dfs.core.windows.net org.apache.hadoop.fs.azurebfs.oauth2.ClientCredsTokenProvider
fs.azure.account.oauth2.client.id.lakeacct.dfs.core.windows.net {{secrets/azure-repl/sp-client-id}}
fs.azure.account.oauth2.client.secret.lakeacct.dfs.core.windows.net {{secrets/azure-repl/sp-client-secret}}
fs.azure.account.oauth2.client.endpoint.lakeacct.dfs.core.windows.net https://login.microsoftonline.com/<tenant-id>/oauth2/token
```

⚠️ This bypasses Unity Catalog for the remote read. Use a **dedicated** access mode cluster, restrict it with
a **cluster policy**, and keep the job's service principal as the only user. The token endpoint
(`login.microsoftonline.com`) must be reachable from the AWS VPC (it's an internet endpoint, so allow it
in the egress firewall).

## 3. How to copy

| Method | Use for | Incremental | Notes |
|---|---|---|---|
| **Auto Loader (`binaryFile`) + `foreachBatch` copy** | Raw files (Parquet, CSV, JSON, images…) | ✅ Checkpoint remembers copied files | Recommended for files. New files only: **deletes and overwrites in place aren't propagated** ⚠️ |
| `dbutils.fs.cp(src, dst, recurse=True)` | One-off or small folders | ❌ Copies everything | Runs on the **driver**, sequential. Slow for many files |
| **`DEEP CLONE`** | **Delta** tables | ✅ Re-run copies only new files | Keeps the table consistent. Better than file copy for Delta |
| Delta Sharing + `DEEP CLONE` | **Managed** tables, Azure → AWS | ✅ | Unity Catalog governed. Needs a D2D share ⚠️ |
| File copy of a Delta / Iceberg folder | Avoid | — | Delta: copy data files **before** `_delta_log`. Iceberg: absolute paths, needs `rewrite_table_path` (see the Iceberg docs) |

### Copy notebook (Auto Loader, one dataset per run)

```python
# Parameters: src, dst, checkpoint, threads
from concurrent.futures import ThreadPoolExecutor

src  = dbutils.widgets.get("src").rstrip("/")   # e.g. s3://lake-aws/sales/orders
dst  = dbutils.widgets.get("dst").rstrip("/")   # e.g. abfss://replica-aws@lakeacct.dfs.core.windows.net/sales/orders
ckpt = dbutils.widgets.get("checkpoint")        # on local storage, e.g. a UC volume path
threads = int(dbutils.widgets.get("threads") or "16")

def rel(path):
    # Auto Loader may return s3:// or s3a:// / abfss:// with a different form: normalise ⚠️
    return path.split(src.split("://", 1)[1], 1)[1]

def copy_batch(df, batch_id):
    paths = [r.path for r in df.select("path").collect()]
    with ThreadPoolExecutor(threads) as pool:
        list(pool.map(lambda p: dbutils.fs.cp(p, dst + rel(p)), paths))

(spark.readStream.format("cloudFiles")
    .option("cloudFiles.format", "binaryFile")
    .option("cloudFiles.maxFilesPerTrigger", 10000)
    .load(src)
    .select("path")                      # content column not needed
    .writeStream
    .foreachBatch(copy_batch)
    .option("checkpointLocation", ckpt)
    .trigger(availableNow=True)          # process what's new, then stop: fits a scheduled job
    .start()
    .awaitTermination())
```

⚠️ Copies run in **driver threads**. For very large volumes, use a bigger driver, more threads, and split
datasets into several runs. A fully distributed copy (copying on executors with cloud SDKs) is possible but
needs credentials on the executors.

### Delta tables

```sql
-- On the Azure workspace: AWS → Azure (path read through the S3 external location)
CREATE OR REPLACE TABLE az_lake.replica_aws.orders
  DEEP CLONE delta.`s3://lake-aws/sales/orders`
  LOCATION 'abfss://replica-aws@lakeacct.dfs.core.windows.net/sales/orders';
-- Re-running copies only new files
```

## 4. Parallelism and orchestration (Lakeflow Jobs)

| Element | Rule | How to use it for scale |
|---|---|---|
| **Job** | One per direction: `aws_to_azure` (Azure workspace), `azure_to_aws` (AWS workspace) | Schedule (hourly or nightly) or **file arrival trigger** ⚠️ |
| **For-each task** | Runs the copy notebook once per input, `concurrency` up to 100 ⚠️ | Input = list of datasets (`src`, `dst`, `checkpoint`). Concurrency = how many datasets copy at once |
| **Job cluster** (classic) | Shared by the for-each iterations of a task | Size it for the concurrency: driver threads plus autoscaling workers. Or split into several tasks with their own clusters |
| **Cluster policy** | Fixes access mode, node types, Spark config, tags | Dedicated mode for the AWS job. Spot with fallback for cost |
| **`max_concurrent_runs`** | 1 | Prevents two runs writing the same checkpoint |
| **Retries and alerts** | Per task | Retry 2–3 times, email or webhook on failure |

Job definition (Asset Bundle excerpt, Azure workspace):

```yaml
resources:
  jobs:
    aws_to_azure:
      name: aws_to_azure_file_replication
      max_concurrent_runs: 1
      run_as: { service_principal_name: "<sp-application-id>" }
      schedule: { quartz_cron_expression: "0 0 * * * ?", timezone_id: "UTC" }
      job_clusters:
        - job_cluster_key: copy
          new_cluster:
            spark_version: "<lts-version>"
            node_type_id: Standard_D16ds_v5
            autoscale: { min_workers: 1, max_workers: 4 }
            data_security_mode: SINGLE_USER   # dedicated
            policy_id: "<replication-policy-id>"
      tasks:
        - task_key: copy_all
          for_each_task:
            inputs: "{{job.parameters.datasets}}"
            concurrency: 8
            task:
              task_key: copy_one
              job_cluster_key: copy
              notebook_task:
                notebook_path: ../src/copy_files
                base_parameters:
                  src: "{{input.src}}"
                  dst: "{{input.dst}}"
                  checkpoint: "{{input.checkpoint}}"
          max_retries: 2
      parameters:
        - name: datasets
          default: '[{"src":"s3://lake-aws/sales/orders","dst":"abfss://replica-aws@lakeacct.dfs.core.windows.net/sales/orders","checkpoint":"/Volumes/ops/repl/ckpt/sales_orders"}]'
```

The AWS job is the same, with S3 and ADLS swapped, an AWS node type and the Spark config from section 2.

## 5. Both directions

| Point | Design |
|---|---|
| Ownership | Each dataset has **one owner cloud**. The owner's data is only **read** by the other workspace |
| Replica areas | `replica_aws/` in Azure, `replica_azure/` in S3. **Never** use a replica area as a source |
| Checkpoints | Stored in the workspace that runs the job, one per dataset. Deleting it means a full re-copy |
| Deletes | Not propagated by Auto Loader. Run a periodic **reconciliation** (compare listings, delete orphans) if needed ⚠️ |
| Delta tables | Use `DEEP CLONE` (or Delta Sharing + clone) instead of file copies |

## 6. Setup step by step

| Step | What |
|---|---|
| 1 | **Network:** VPN or ExpressRoute ⇄ Direct Connect. S3 interface endpoint, ADLS private endpoints, DNS forwarding both ways. Back-end Private Link for both workspaces |
| 2 | **Identities:** a service principal per workspace for `run_as`. IAM roles for S3. Access connector for ADLS. Entra service principal for the AWS → ADLS read |
| 3 | **Unity Catalog:** storage credentials and external locations: S3 (read-only) in the Azure workspace, ADLS replica in Azure, S3 replica in AWS. A UC volume for checkpoints in each |
| 4 | **Secrets:** secret scope on AWS with the Entra service principal's credentials. Rotation process |
| 5 | **Cluster policy:** dedicated access mode, node types, Spark config (AWS), tags |
| 6 | **Code:** copy notebook, `DEEP CLONE` notebook for Delta tables, deployed with **Databricks Asset Bundles** |
| 7 | **Jobs:** one per direction, for-each with concurrency, schedule, retries, alerts |
| 8 | **Test:** one dataset each way, with storage public access disabled. Check network logs, duration and egress cost |
| 9 | **Monitoring:** job run history and system tables (`system.lakeflow.*`), alerts on failures and long runs |

## Lakeflow vs. DataSync for this use case

| | Lakeflow Jobs (classic compute) | AWS DataSync |
|---|---|---|
| Fit | Already on Databricks, tables + files, one tool for both | Pure file replication |
| Delta tables | ✅ `DEEP CLONE`, Delta Sharing | File copy only (ordering by hand) |
| Deletes / mirroring | ❌ Not with Auto Loader (reconciliation needed) | ✅ `PreserveDeletedFiles=REMOVE` |
| Governance | UC for AWS → Azure. Azure → AWS read outside UC ⚠️ | IAM + SAS |
| Scale | Cluster size and for-each concurrency | Agents (one task at a time per agent) |
| Cost | DBUs + VMs + egress | Per GB (+ per execution in Enhanced mode) + egress + agent VMs |
| Private | ✅ Classic compute in your VPC/VNet | ✅ Agent + VPC endpoint |

## Related

- [`../datasync/03-scalable-parallel-datasync-aws-azure.md`](../datasync/03-scalable-parallel-datasync-aws-azure.md): DataSync scalable design
- [`../datasync/04-datasync-enhanced-mode.md`](../datasync/04-datasync-enhanced-mode.md): DataSync Enhanced mode, private mode
- [`../azure-data-factory/01-adf-replication-aws-azure.md`](../azure-data-factory/01-adf-replication-aws-azure.md): Azure Data Factory
- [`../iceberg/08-incremental-rewrite-table-path-explained.md`](../iceberg/08-incremental-rewrite-table-path-explained.md): Iceberg paths

## Sources

- [Azure Databricks: Connect to an AWS S3 external location (read-only)](https://learn.microsoft.com/en-us/azure/databricks/connect/unity-catalog/cloud-storage/s3/s3-external-location-manual)
- [Azure Databricks: Storage credentials for S3](https://learn.microsoft.com/azure/databricks/connect/unity-catalog/cloud-storage/storage-credentials-s3)
- [Azure Databricks: Connect to an ADLS Gen2 external location](https://learn.microsoft.com/en-us/azure/databricks/connect/unity-catalog/cloud-storage/external-locations-adls)
- [Databricks on AWS: Connect to an S3 external location](https://docs.databricks.com/aws/en/connect/unity-catalog/cloud-storage/s3)
- [Databricks on AWS: Connect to cloud object storage using Unity Catalog](https://docs.databricks.com/aws/en/connect/unity-catalog/cloud-storage)
- [Azure Databricks: Schedule and orchestrate workflows (Lakeflow Jobs)](https://learn.microsoft.com/azure/databricks/workflows)
- [Databricks: Pipeline task for jobs (for-each limits)](https://docs.databricks.com/aws/en/jobs/tasks/pipeline)
- [Waitingforcode: For each task in Lakeflow Jobs](https://www.waitingforcode.com/databricks/for-each-task-databricks-jobs/read)
- [Databricks Community: limit concurrent task runs](https://community.databricks.com/t5/data-engineering/how-to-limit-max-concurrent-tasks-runs-in-a-job/m-p/156143/highlight/true)
- [Databricks: Create and manage shares for Delta Sharing (volumes in D2D shares)](https://docs.databricks.com/aws/en/delta-sharing/create-share)
- [Databricks Community: external locations to Azure storage via private endpoint](https://community.databricks.com/t5/administration-architecture/external-locations-to-azure-storage-via-private-endpoint/td-p/120895)
