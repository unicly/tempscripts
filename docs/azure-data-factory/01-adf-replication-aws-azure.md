# Azure Data Factory for AWS ⇄ Azure replication: directions, network path, authentication, runtime

The same questions as for AWS DataSync ([`../datasync/02-…md`](../datasync/02-datasync-replication-aws-azure-network-auth.md)),
answered for **Azure Data Factory (ADF)**: how to replicate, whether traffic goes over the public
internet, whether a VPN can be used, how authentication works, and what ADF uses instead of an agent.

> From the Microsoft docs. Not tested. ⚠️ marks points to check.

## Short answer

- **S3 → Azure:** ✅ with the normal **Copy activity**, privately possible with a **self-hosted
  integration runtime (SHIR)**.
- **Azure → S3:** ⚠️ **not with the Copy activity** (the ADF S3 connector is source-only there). It works
  only with **Mapping data flows**, which rewrite the data. By default they reach S3 over its **public
  endpoint**; a **private path is possible** with a managed VNet, a managed private endpoint to a
  Private Link Service and forwarding VMs over VPN, but it's complex (see below). For byte-for-byte,
  private replication to S3, **AWS DataSync** or **Fabric Data Factory** are simpler.
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
| Network | Runs only on the **Azure IR** (optionally in a managed VNet), **not on a self-hosted IR**. By default S3 is reached over its **public endpoint**. A **private path** is possible with a managed VNet + Private Link Service + forwarding VMs + VPN (see "Private path for Mapping data flows") ⚠️ |
| Cost | Spark cluster time (vCore-hours) |
| Fit for Delta / Iceberg folders | ❌ Not as a replica: `_delta_log` and Iceberg metadata aren't copied as they are |

## Does traffic go over the public internet?

| Integration runtime | Path to S3 | Path to Azure storage | Private? |
|---|---|---|---|
| **Azure IR** (default, serverless) | S3's **public endpoint** (HTTPS) | Public endpoint or trusted-services access | ❌ |
| **Managed VNet IR** | Public S3 endpoint, **unless** a managed private endpoint points to a **Private Link Service** in your VNet that forwards to AWS over VPN (see below) | ✅ Managed private endpoint | Partly by default. ✅ With the Private Link Service setup ⚠️ |
| **Self-hosted IR** on a VM in your VNet | Over **VPN / ExpressRoute ⇄ Direct Connect** to an **S3 interface VPC endpoint** | ✅ Private endpoint in the VNet | ✅ **No public internet** (a VPN tunnel itself runs over the internet, encrypted) |

**VPN: yes, with a SHIR.** You need:

- Azure VPN Gateway ↔ AWS Site-to-Site VPN (or ExpressRoute ⇄ Direct Connect)
- an **S3 interface endpoint** in the AWS VPC, with a bucket policy limited to that endpoint
- DNS so the SHIR resolves S3 to the endpoint (custom service URL in the linked service ⚠️)
- a private endpoint on the storage account.

## Private path for Mapping data flows (Azure → S3 or S3 → Azure)

Data flows can't use a self-hosted IR, but a **managed VNet IR** can reach resources outside Azure
through a **managed private endpoint to a Private Link Service** in your own VNet. Microsoft documents
this for an on-premises SQL Server; using it for S3 is an adaptation ⚠️ (not documented for S3, test
first).

```
ADF managed VNet (data flow Spark)
  └─ managed private endpoint (FQDN: <bucket>.bucket.vpce-xxx.s3.<region>.vpce.amazonaws.com)
        ▼
Your Azure VNet
  └─ Private Link Service → Standard Load Balancer → forwarding VM(s) (TCP 443 → S3 VPC endpoint IPs)
        ▼  VPN Gateway / ExpressRoute
AWS VPC
  └─ S3 interface VPC endpoint → S3 bucket (bucket policy: only this endpoint)
```

| Step | What |
|---|---|
| 1 | **AWS:** S3 **interface VPC endpoint** in the VPC connected to Azure. Bucket policy limited to that endpoint |
| 2 | **Network:** site-to-site **VPN** or ExpressRoute ⇄ Direct Connect between the Azure VNet and that VPC |
| 3 | **Azure VNet:** one or two small **forwarding VMs** (iptables or HAProxy at TCP level) forwarding port 443 to the VPC endpoint's private IPs, behind a **Standard Load Balancer** |
| 4 | **Private Link Service** on that load balancer |
| 5 | **ADF:** enable the **managed VNet** on the Azure IR. Create a **managed private endpoint** to the Private Link Service and enter the **S3 endpoint FQDN** in it (managed VNets don't support custom DNS, so this FQDN mapping does the name resolution) ⚠️ |
| 6 | **ADF S3 linked service:** set the **service URL** to the VPC endpoint's DNS name ⚠️ |
| 7 | Approve the private endpoint connection on the Private Link Service. Run the data flow on the managed VNet IR |

TLS stays end to end: the forwarding VM only passes TCP through, and the VPC endpoint's certificate
matches its DNS name.

| Point | Assessment |
|---|---|
| Effort | High: forwarding VMs, load balancer, Private Link Service, DNS mapping, VPN |
| Operations | You run and patch the forwarding VMs. Potential bottleneck and failure point (use two) |
| Support | Documented for on-premises SQL Server, not for S3 ⚠️ |
| What you get | Data flows still **rewrite** the data. Not a byte-for-byte file copy |

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
| Azure → AWS | ✅ | ⚠️ Only via Mapping data flows (rewrites data; public by default, private only with a complex Private Link Service setup) |
| Private path | Agent + DataSync VPC endpoint + VPN | S3 → Azure: SHIR + S3 interface endpoint + VPN. Azure → S3 (data flows): managed VNet + Private Link Service + forwarding VMs + VPN ⚠️ |
| Agent / runtime | Linux VM appliance, one task at a time per agent | Windows SHIR, many concurrent jobs, up to 4 nodes |
| Auth to the other cloud | SAS token for Azure | Access keys for S3 (no IAM role) |
| Incremental | Built in (copies only changed files, can mirror deletes) | Last-modified filter. Deletes need extra logic |

## Which tool for which need

| Need | Best tool |
|---|---|
| S3 → Azure, files as they are, private network | ADF **Copy activity** + SHIR + VPN (or DataSync) |
| Azure → S3, files as they are, private network | **AWS DataSync** (agent in Azure, VPC endpoint), or **Fabric Data Factory** Copy activity ⚠️ (check its private-network options) |
| Azure → S3, data transformed or reformatted | ADF **Mapping data flow** (public endpoint, or privately with managed VNet + Private Link Service + VPN) |

## Sources

- [Microsoft: Managed virtual network and managed private endpoints (ADF)](https://learn.microsoft.com/en-us/azure/data-factory/managed-virtual-network-private-endpoint)
- [Microsoft: Access on-premises SQL Server from an ADF managed VNet using a private endpoint](https://learn.microsoft.com/en-us/azure/data-factory/tutorial-managed-virtual-network-on-premise-sql-server)
- [Azure blog: Azure Data Factory managed virtual network](https://azure.microsoft.com/en-us/blog/azure-data-factory-managed-virtual-network/)

- [Microsoft: Copy and transform data in Amazon S3 (ADF) – supported capabilities](https://learn.microsoft.com/en-us/azure/data-factory/connector-amazon-simple-storage-service)
- [Microsoft: Copy data from S3 compatible storage (ADF)](https://learn.microsoft.com/en-us/azure/data-factory/connector-amazon-s3-compatible-storage)
- [Microsoft: Connector capability comparison ADF vs. Fabric Data Factory](https://learn.microsoft.com/en-us/fabric/data-factory/connector-parity)
- [Microsoft Fabric: Amazon S3 connector overview](https://learn.microsoft.com/en-us/fabric/data-factory/connector-amazon-s3-overview)
- [Microsoft: Create a self-hosted integration runtime](https://learn.microsoft.com/el-gr/azure/data-factory/create-self-hosted-integration-runtime)
- [Microsoft: Monitor an integration runtime (nodes, concurrent jobs)](https://learn.microsoft.com/ms-my/azure/data-factory/monitor-integration-runtime)
- [Microsoft Q&A: High availability / multiple nodes for SHIR](https://learn.microsoft.com/en-us/answers/questions/818758/high-availability-or-multiple-node-setup-for-self)
- [Pythian: ADF self-hosted IR scaling and best practices](https://blog.pythian.com/azure-data-factory-self-hosted-ir-scaling-best-practices-and-disaster-recovery-solutions/)
- [Medium: Azure Blob to AWS S3 pipeline using ADF (Azure Function workaround)](https://medium.com/@ajjogames/azure-blob-to-aws-s3-pipeline-using-azure-data-factory-c75227470e9f)
