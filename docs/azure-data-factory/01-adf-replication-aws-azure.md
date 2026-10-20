# Azure Data Factory for AWS ⇄ Azure replication: directions, network path, authentication, runtime

The same questions as for AWS DataSync ([`../datasync/02-…md`](../datasync/02-datasync-replication-aws-azure-network-auth.md)),
answered for **Azure Data Factory (ADF)**: how to replicate, whether traffic goes over the public
internet, whether a VPN can be used, how authentication works, and what ADF uses instead of an agent.

> From the Microsoft docs. Not tested. ⚠️ marks points to check.

## Short answer

- **S3 → Azure:** ✅ with the normal **Copy activity**, privately possible with a **self-hosted
  integration runtime (SHIR)**.
- **Azure → S3:** ⚠️ **not with the Copy activity** (the ADF S3 connector is source-only there). It works
  only with **Mapping data flows**, which rewrite the data and reach S3 over its **public endpoint**.
  For byte-for-byte, private replication to S3, use **AWS DataSync** or **Fabric Data Factory**.
- ADF's equivalent of the DataSync agent is the **self-hosted integration runtime**.

## Directions

| ADF feature | Amazon S3 as source | Amazon S3 as destination (sink) |
|---|---|---|
| **Copy activity** (normal file replication) | ✅ | ❌ Not supported |
| **Mapping data flow** | ✅ | ✅ Supported |
| **Fabric Data Factory** (pipeline Copy activity) | ✅ | ✅ Supported |

### S3 → Azure (Copy activity)

| Step | What |
|---|---|
| 1 | **Linked service** to Amazon S3 (access key or temporary credentials, secrets in Key Vault) |
| 2 | **Linked service** to ADLS Gen2 / Blob (managed identity recommended) |
| 3 | **Copy activity**: binary copy, preserve folder structure |
| 4 | **Incremental:** filter by **last-modified time** (watermark window per run), or tumbling-window triggers |
| 5 | **Schedule**: schedule or tumbling-window trigger (event triggers only fire on Azure storage events, not S3) |

ADF doesn't **mirror deletes** by itself: removing files deleted on the source needs extra logic (Get
Metadata, compare lists, Delete activity).

### Azure → S3 (Mapping data flow)

| Point | Detail |
|---|---|
| How it works | Spark-based transformation that **reads rows and writes new files**, not a byte-for-byte copy |
| File types | Formats data flows support (Parquet, CSV, JSON, Avro, Delta… ⚠️ check the S3 sink list). **No binary copy** ⚠️ |
| Network | Runs only on the **Azure IR** (optionally managed VNet), **not on a self-hosted IR**, so S3 is reached over its **public endpoint** ⚠️ |
| Cost | Spark cluster time (vCore-hours) |
| Fit for Delta / Iceberg folders | ❌ Not as a replica: `_delta_log` and Iceberg metadata aren't copied as they are |

## Does traffic go over the public internet?

| Integration runtime | Path to S3 | Path to Azure storage | Private? |
|---|---|---|---|
| **Azure IR** (default, serverless) | S3's **public endpoint** (HTTPS) | Public endpoint or trusted-services access | ❌ |
| **Managed VNet IR** | Still the public S3 endpoint. Managed private endpoints only reach Azure services ⚠️ | ✅ Managed private endpoint | Partly (Azure side only) |
| **Self-hosted IR** on a VM in your VNet | Over **VPN / ExpressRoute ⇄ Direct Connect** to an **S3 interface VPC endpoint** | ✅ Private endpoint in the VNet | ✅ **No public internet** (a VPN tunnel itself runs over the internet, encrypted) |

**VPN: yes, with a SHIR.** You need:

- Azure VPN Gateway ↔ AWS Site-to-Site VPN (or ExpressRoute ⇄ Direct Connect)
- an **S3 interface endpoint** in the AWS VPC, with a bucket policy limited to that endpoint
- DNS so the SHIR resolves S3 to the endpoint (custom service URL in the linked service ⚠️)
- a private endpoint on the storage account.

## Authentication

| Part | Methods |
|---|---|
| ADF → **S3** | **Access key** (ID + secret) or **temporary security credentials** (with session token). ⚠️ No IAM role or federation: use a dedicated IAM user limited to the bucket, rotate keys |
| ADF → **Azure storage** | **Managed identity** (recommended), service principal, account key or SAS |
| Secrets | Store S3 keys in **Azure Key Vault**, referenced from the linked service |
| SHIR ↔ ADF | Registered with an **authentication key**. Outbound HTTPS only (TCP 443) |
| In transit / at rest | TLS. S3 with SSE-S3 / SSE-KMS (IAM user needs `kms:Decrypt`). Azure with Microsoft- or customer-managed keys |
| Audit | ADF monitoring and Azure Monitor logs, CloudTrail on the AWS side |

## The self-hosted integration runtime (ADF's "agent")

| Question | Answer |
|---|---|
| What is it? | A Windows service installed on a VM (Azure or on-premises). It runs copy jobs and connects **outbound** to ADF |
| Where for S3 → Azure? | A **Windows VM in Azure**, in the VNet with the storage private endpoint and the VPN / ExpressRoute to AWS |
| One SHIR for many replications? | ✅ All pipelines and linked services can use it. It can also be **shared with other data factories** (linked IR) |
| Several jobs at the same time? | ✅ Each node runs several **concurrent jobs** (default from CPU and RAM, adjustable). No one-task-at-a-time limit, unlike DataSync |
| Several SHIRs on one VM? | ❌ One SHIR installation per machine ⚠️ |
| More capacity / high availability | Add **nodes**: up to **4 VMs** per SHIR. Concurrent-job limits add up, and no single point of failure |
| Mapping data flows | ❌ Can't run on a SHIR (Azure IR only) |

## Compared with AWS DataSync

| | AWS DataSync | Azure Data Factory |
|---|---|---|
| AWS → Azure | ✅ | ✅ (Copy activity) |
| Azure → AWS | ✅ | ⚠️ Only via Mapping data flows (rewrites data, public S3 endpoint) |
| Private path | Agent + DataSync VPC endpoint + VPN | SHIR + S3 interface endpoint + VPN (S3 → Azure only) |
| Agent / runtime | Linux VM appliance, one task at a time per agent | Windows SHIR, many concurrent jobs, up to 4 nodes |
| Auth to the other cloud | SAS token for Azure | Access keys for S3 (no IAM role) |
| Incremental | Built in (copies only changed files, can mirror deletes) | Last-modified filter. Deletes need extra logic |

## Which tool for which need

| Need | Best tool |
|---|---|
| S3 → Azure, files as they are, private network | ADF **Copy activity** + SHIR + VPN (or DataSync) |
| Azure → S3, files as they are, private network | **AWS DataSync** (agent in Azure, VPC endpoint), or **Fabric Data Factory** Copy activity ⚠️ (check its private-network options) |
| Azure → S3, data transformed or reformatted, public endpoint acceptable | ADF **Mapping data flow** |

## Sources

- [Microsoft: Copy and transform data in Amazon S3 (ADF) – supported capabilities](https://learn.microsoft.com/en-us/azure/data-factory/connector-amazon-simple-storage-service)
- [Microsoft: Copy data from S3 compatible storage (ADF)](https://learn.microsoft.com/en-us/azure/data-factory/connector-amazon-s3-compatible-storage)
- [Microsoft: Connector capability comparison ADF vs. Fabric Data Factory](https://learn.microsoft.com/en-us/fabric/data-factory/connector-parity)
- [Microsoft Fabric: Amazon S3 connector overview](https://learn.microsoft.com/en-us/fabric/data-factory/connector-amazon-s3-overview)
- [Microsoft: Create a self-hosted integration runtime](https://learn.microsoft.com/el-gr/azure/data-factory/create-self-hosted-integration-runtime)
- [Microsoft: Monitor an integration runtime (nodes, concurrent jobs)](https://learn.microsoft.com/ms-my/azure/data-factory/monitor-integration-runtime)
- [Microsoft Q&A: High availability / multiple nodes for SHIR](https://learn.microsoft.com/en-us/answers/questions/818758/high-availability-or-multiple-node-setup-for-self)
- [Pythian: ADF self-hosted IR scaling and best practices](https://blog.pythian.com/azure-data-factory-self-hosted-ir-scaling-best-practices-and-disaster-recovery-solutions/)
- [Medium: Azure Blob to AWS S3 pipeline using ADF (Azure Function workaround)](https://medium.com/@ajjogames/azure-blob-to-aws-s3-pipeline-using-azure-data-factory-c75227470e9f)
