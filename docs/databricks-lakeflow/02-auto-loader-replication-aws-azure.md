# Databricks Auto Loader for replication between AWS and Azure

Can **Auto Loader** replicate files between S3 and ADLS, in both directions, on **classic compute**, in a
**private** network? Same analysis as for DataSync, Azure Data Factory, Storage Mover and Lakeflow Jobs
([`01-…md`](01-lakeflow-classic-file-replication-aws-azure.md)).

> Based on Databricks and Microsoft docs. Not tested. ⚠️ marks points that are unconfirmed or depend on
> your setup.

## Short answer

**Yes, but as the "new file detection" part of a job, not as a replication tool on its own.**

- Auto Loader (`cloudFiles`) is a **streaming source** that finds **new files** in a folder and processes
  each one **exactly once**, using a **checkpoint**. It's meant to **ingest files into Delta tables**.
- For **file replication**, combine it with `foreachBatch` to copy each new file (the pattern in doc 01), and
  run it from a **Lakeflow Job** with `trigger(availableNow=True)`.
- It does **not** handle **deletes**, and only partly handles **overwritten** files. It's the wrong tool for
  **Delta / Iceberg tables** (use `DEEP CLONE` or Delta Sharing).
- Best fit: **append-only landing zones** with many immutable files (raw exports, logs, images, Parquet
  drops).

## Two ways to use it

| Variant | What lands in the other cloud | When |
|---|---|---|
| **A. File copy** (`binaryFile` + `foreachBatch` + `dbutils.fs.cp`) | **Identical files**, same folder layout | You need the files themselves (other tools read them) |
| **B. Ingest to a table** (`cloudFiles.format = parquet/json/csv` → Delta table) | A **Delta table** built from the files, not the files | You only need the data on the other side. Simpler, also works in Lakeflow Declarative Pipelines |

## Capabilities

| Topic | Auto Loader |
|---|---|
| Directions | Both, with the **pull model**: AWS → Azure runs on the Azure workspace, Azure → AWS on the AWS workspace (Azure Databricks can read S3 through UC but **not write** to it) |
| New files | ✅ Exactly once, tracked in the checkpoint (RocksDB) |
| Overwritten files | ⚠️ Ignored by default. `cloudFiles.allowOverwrites=true` reprocesses them (latest version, not every version). Databricks recommends **immutable** files |
| Deleted files | ❌ Not propagated. Needs a separate **reconciliation** job (compare listings, delete orphans) |
| Delta / Iceberg tables | ❌ Copying their files with Auto Loader breaks ordering (`_delta_log`, absolute Iceberg paths). Use `DEEP CLONE`, Delta Sharing, or `rewrite_table_path` |
| Existing files at first run | ✅ `cloudFiles.includeExistingFiles=true` (default) does the initial full copy |
| Scale | Millions of files. Batch size with `cloudFiles.maxFilesPerTrigger` / `maxBytesPerTrigger`. One stream (and checkpoint) per dataset |
| Large files | ⚠️ Variant A copies with `dbutils.fs.cp` on the driver: fine for many files, slower for very big ones. Select only `path` so file content isn't loaded |
| Source cleanup | Optional `cloudFiles.cleanSource` (`DELETE` / `MOVE` after 30 days by default). Needs **write** access to the source. Usually **off** for replication |
| Scheduling | Lakeflow Job, `trigger(availableNow=True)`: processes what's new, then stops. Or continuous (cluster always on) |

## How new files are found

| Mode | How | Cross-cloud use |
|---|---|---|
| **Directory listing** (default) | Lists the folder at each run, compares with the checkpoint | ✅ Works everywhere, only needs list/read. Listing cost and time grow with the folder size. Organise by date folders and use path globs |
| **File events** (managed, `cloudFiles.useManagedFileEvents`, default `if_available` from DBR 18.1) | Uses the **file events service** of a **UC external location**. One-time setup per location | ⚠️ **AWS → Azure:** the S3 external location in the Azure workspace is **read-only**, and file events need extra permissions to create S3 notifications/SQS in AWS. Not confirmed cross-cloud. **Azure → AWS:** ADLS isn't a UC external location in the AWS workspace, so **not available** |
| **Legacy file notifications** (your own queues) | SQS/SNS on AWS, Event Grid + queue on Azure | ⚠️ Possible, but needs credentials and private endpoints for the queue service on top of storage. Not worth it here |

**Recommendation:** start with **directory listing**, organised by date folders. Move to file events only if
listing becomes the bottleneck and it's supported in your setup.

## Network (private)

Same as doc 01. Auto Loader adds nothing:

| Point | Detail |
|---|---|
| Compute | Classic compute in a **customer-managed VPC** (AWS) / **VNet injection** (Azure), no public IPs, **back-end Private Link** |
| Link | VPN or ExpressRoute ⇄ Direct Connect |
| Remote storage | S3 **interface endpoint** (read from Azure), ADLS **private endpoints** `dfs` + `blob` (read from AWS), DNS forwarding both ways |
| Extra for notification modes | ⚠️ Queue endpoints (SQS, Azure Queue Storage `queue` private endpoint) must also be private. Another reason to use directory listing |
| Entra token | AWS → ADLS reads with a service principal need `login.microsoftonline.com` (internet endpoint) through the egress firewall ⚠️ |

## Authentication

| Direction | Read remote | Write local | Checkpoint |
|---|---|---|---|
| AWS → Azure (Azure workspace) | UC **S3 external location**, read-only (IAM role) | UC ADLS external location (access connector) | UC volume on ADLS |
| Azure → AWS (AWS workspace) | **Entra service principal**, Spark config, **dedicated** cluster ⚠️ (not UC-governed) | UC S3 external location (IAM role) | UC volume on S3 |

## Example (variant A, one dataset)

```python
# Parameters: src, dst, checkpoint
from concurrent.futures import ThreadPoolExecutor
src, dst = dbutils.widgets.get("src").rstrip("/"), dbutils.widgets.get("dst").rstrip("/")

def copy_batch(df, _):
    paths = [r.path for r in df.select("path").collect()]
    with ThreadPoolExecutor(16) as pool:
        list(pool.map(lambda p: dbutils.fs.cp(p, dst + p.split(src.split("://", 1)[1], 1)[1]), paths))

(spark.readStream.format("cloudFiles")
    .option("cloudFiles.format", "binaryFile")
    .option("cloudFiles.useManagedFileEvents", "false")   # directory listing (see above)
    .option("cloudFiles.maxFilesPerTrigger", 10000)
    .option("pathGlobFilter", "*.parquet")                # optional
    .load(src).select("path")
    .writeStream.foreachBatch(copy_batch)
    .option("checkpointLocation", dbutils.widgets.get("checkpoint"))
    .trigger(availableNow=True).start().awaitTermination())
```

## Example (variant B, ingest to a Delta table)

```python
(spark.readStream.format("cloudFiles")
    .option("cloudFiles.format", "parquet")
    .option("cloudFiles.schemaLocation", "/Volumes/ops/repl/schema/sales_orders")
    .load("s3://lake-aws/sales/orders")
    .writeStream
    .option("checkpointLocation", "/Volumes/ops/repl/ckpt/sales_orders_tbl")
    .trigger(availableNow=True)
    .toTable("az_lake.replica_aws.sales_orders_raw"))
```

## Parallelism and orchestration

| Element | Design |
|---|---|
| One stream per dataset | Own source folder, destination and **checkpoint** |
| Lakeflow Job | **For-each** task over datasets with `concurrency`, classic job cluster, `max_concurrent_runs: 1` |
| Throughput | Driver threads (variant A), cluster size, `maxFilesPerTrigger` |
| Monitoring | Streaming progress (`numFilesOutstanding`, `numBytesOutstanding`), job run history, `cloud_files_state()` to see processed files |

Job definition: see the Asset Bundle example in doc 01.

## Verdict

| Criterion | Auto Loader |
|---|---|
| Append-only files, both directions | ✅ Good fit |
| Mirror (deletes, overwrites) | ❌ Needs a reconciliation job |
| Delta / Iceberg tables | ❌ Use `DEEP CLONE` / Delta Sharing |
| Private network | ✅ With classic compute + directory listing |
| Governance | ✅ AWS → Azure (UC). ⚠️ Azure → AWS read outside UC |
| Effort | Low if you already run Databricks (one notebook + one job per direction) |

## Comparison with the other solutions

| | Auto Loader (Lakeflow Job) | DataSync | Azure Data Factory | Azure Storage Mover |
|---|---|---|---|---|
| AWS → Azure | ✅ | ✅ | ✅ | ✅ |
| Azure → AWS | ✅ (AWS workspace pulls) | ✅ | ✅ (data flows) | ❌ |
| Incremental | ✅ Checkpoint, exactly once | ✅ Changed files | ✅ Last modified / partitions | ✅ |
| Deletes | ❌ | ✅ | ❌ ⚠️ | ⚠️ |
| Delta tables | ✅ via `DEEP CLONE` (not Auto Loader) | Files only | Files only | Files only |
| Private | ✅ Classic compute | ✅ Agent + VPC endpoint | ✅ Self-hosted IR / managed VNet | ✅ Private connections (preview) |
| Runs on | Databricks clusters (DBUs + VMs) | Managed service + agents | Managed service + IR | Managed service |

## Related

- [`01-lakeflow-classic-file-replication-aws-azure.md`](01-lakeflow-classic-file-replication-aws-azure.md): full Lakeflow setup (network, auth, job)
- [`../datasync/03-scalable-parallel-datasync-aws-azure.md`](../datasync/03-scalable-parallel-datasync-aws-azure.md): DataSync
- [`../azure-data-factory/01-adf-replication-aws-azure.md`](../azure-data-factory/01-adf-replication-aws-azure.md): Azure Data Factory
- [`../azure-storage-mover/01-storage-mover-replication-aws-azure.md`](../azure-storage-mover/01-storage-mover-replication-aws-azure.md): Azure Storage Mover

## Sources

- [Databricks: Auto Loader options](https://docs.databricks.com/en/ingestion/cloud-object-storage/auto-loader/options.html)
- [Azure Databricks: Auto Loader FAQ](https://learn.microsoft.com/en-us/azure/databricks/ingestion/cloud-object-storage/auto-loader/faq)
- [Azure Databricks: Auto Loader best practices](https://learn.microsoft.com/en-us/azure/databricks/ingestion/cloud-object-storage/auto-loader/best-practices)
- [Azure Databricks: Migrate to Auto Loader with file events](https://learn.microsoft.com/en-us/azure/databricks/ingestion/cloud-object-storage/auto-loader/migrating-to-file-events)
- [Azure Databricks: File events FAQ](https://learn.microsoft.com/en-us/azure/databricks/connect/unity-catalog/cloud-storage/file-events-faq)
- [Azure Databricks: Auto Loader file notification mode](https://docs.azure.cn/en-us/databricks/ingestion/cloud-object-storage/auto-loader/file-notification-mode)
- [Azure Databricks: AWS S3 external location (read-only)](https://learn.microsoft.com/en-us/azure/Databricks/connect/unity-catalog/cloud-storage/s3/s3-external-location-manual)
- [Databricks Community: Auto Loader managed file events](https://community.databricks.com/t5/data-engineering/autoloader-managed-file-events/td-p/139610)
- [Understanding Auto Loader file event mode (third party)](https://zoevannoppen.substack.com/p/understanding-auto-loader-file-event)
