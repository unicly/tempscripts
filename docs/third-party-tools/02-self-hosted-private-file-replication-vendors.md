# Self-hosted file replication between AWS and Azure in a private network: vendor research

Research on 6 products for **file replication between S3 and Azure Blob / ADLS**, with two hard requirements:

1. **Self-hosted:** runs on **your own infrastructure** (VMs or containers in your VPC / VNet / data center).
2. **Private network:** data does **not** go over the public internet (VPN or ExpressRoute ⇄ Direct Connect,
   S3 interface/gateway endpoints, Azure Private Endpoints).

Vendors: CData **Arc**, Signiant, Flexify, Resilio, Coviant Software, NetApp.

> From vendor docs, vendor marketing and third-party articles (October 2026). Not tested. Many points
> weren't confirmed or come only from vendor marketing. Confirm with each vendor before deciding (see the
> question list at the end).

## Summary

| Vendor / product | Self-hosted | Private data path | S3 ⇄ Azure, both directions | Copies files as-is | Control plane needs internet? | Fit |
|---|---|---|---|---|---|---|
| **NetApp Copy and Sync** | ✅ Data brokers (VMs) in AWS, Azure or on-premises | ✅ S3 private link, Azure VNet service endpoints. Azure **Private Endpoint** not confirmed | ✅ S3 → Blob and Blob → S3 | ✅ | **Yes**: brokers poll the NetApp SaaS over outbound 443 (SQS) | ⭐ **Good** |
| **Resilio Active Everywhere** | ✅ Management Console + agents, all yours | ✅ Agent-to-agent in your network. Storage via private endpoints (to test) | ✅ S3 and Azure Blob via agents | ✅ | License checks (offline/air-gapped licence not confirmed) | ⭐ **Good** |
| **Flexify.IO** (Standard Edition) | ✅ Management server + engines in your Azure subscription, or elsewhere | ✅ Engines in your VPC / VNet (private endpoint setup not documented) | ✅ Migration and cross-cloud replication | ✅ (object copy) | Not documented | ✅ Possible |
| **Coviant Diplomat MFT** | ✅ Windows / Linux servers | ✅ Runs in your network | ✅ S3 and Azure Blob connectors | ✅ | No (self-contained) | For scheduled transfer jobs, not data-lake scale |
| **Signiant Jet / SDCX Server** | Partly: SDCX servers yours, platform is SaaS | Private-network SDCX deployment from v7.3.1 (June 2026). **Cloud-to-cloud transfers coordinated by Signiant-hosted servers** | S3 and Blob, but **ADLS (hierarchical namespace) not supported** | ✅ | **Yes** (SaaS control) | ❌ Weak |
| **CData Arc** | ✅ On-premises or private cloud (Windows / Java). Connectors can also run in **Docker** | ✅ Runs in your network (private endpoints to check) | ✅ **S3 connector** + **Azure Blob connector** in one flow, both directions | ✅ (files staged on the Arc server) | No | Like Coviant: job-based file flows, not data-lake scale |

**Shortlist:** **NetApp Copy and Sync** and **Resilio Active Everywhere**, then **Flexify.IO**. **Coviant
Diplomat MFT** or **CData Arc** if your volumes are moderate and job-based. Signiant
doesn't fit file replication between S3 and Azure in a private network.

## Details per vendor

### NetApp Copy and Sync (formerly Cloud Sync / BlueXP Copy and Sync)

| Topic | Finding |
|---|---|
| What it is | Sync service: you create **sync relationships** (source → target) run by **data brokers** |
| Deployment | Data broker = VM you deploy in **AWS, Azure, GCP or on-premises**. Grouped in **data broker groups** for scale and availability |
| S3 ⇄ Azure | ✅ Both directions are in the supported relationships matrix. Broker for S3 must run **in AWS or on-premises**. Broker for Azure Blob can run **anywhere** |
| Private data path | ✅ **S3 private link** option (broker copies through the endpoint, needs `ec2:DescribeVpcEndpoints`). FAQ lists **Amazon private S3 endpoints** and **Azure VNet service endpoints**. **Azure Private Endpoint** not named in the docs found |
| Network between clouds | Source and target must be reachable from the broker: **VPN / Direct Connect / ExpressRoute** |
| Control plane | Brokers need **outbound internet on 443** to poll the Copy and Sync service (via **Amazon SQS**). Data doesn't go through NetApp, but the control traffic does |
| ADLS Gen2 | Not confirmed (Blob is documented) |
| Region limits | No China regions. Azure Blob: no US Gov / US DoD |
| Verdict | Closest to DataSync. Data path can be private. Control plane is SaaS |

### Resilio Active Everywhere (formerly Resilio Connect)

| Topic | Finding |
|---|---|
| What it is | Peer-to-peer sync and replication: **Management Console** + **agents** |
| Deployment | Fully **self-hosted**: console and agents on your servers. Optional self-hosted tracker server |
| S3 ⇄ Azure | ✅ Agents read and write **Amazon S3, Azure Blob**, GCS, Wasabi and others (cloud agents have documented characteristics and limitations) |
| Private network | ✅ Agents talk to each other over your network (ports: console 8443, agent control 8444, tracker 3000, data 3839, all configurable). Put agents in your VPC and VNet and reach storage through private endpoints (to test) |
| Control plane | Self-hosted. The console **checks for licence updates** (every 10 min when agents are unlicensed). Offline / air-gapped licensing not confirmed |
| Sync modes | One-way, two-way, continuous or scheduled (check modes for cloud storage agents) |
| Scale | Vendor claims up to **50,000 agents** per console |
| Verdict | Best fit for a **fully self-hosted** control plane. Check cloud-agent limitations and licensing |

### Flexify.IO

| Topic | Finding |
|---|---|
| What it is | Multi-cloud **S3-compatible virtual endpoint** plus **migration** and **replication** across clouds |
| Deployment | **Standard Edition** self-hosted as Azure-native resources in **your subscription** (ARM templates), or hosted outside Azure. **Community Edition** as a single Docker container. Flexify doesn't store data or metadata |
| S3 ⇄ Azure | ✅ Azure Blob ↔ S3, migration (copy or move) and replication |
| Private network | ✅ Engines run in your network. Private endpoint / VNet setup not documented in the sources found |
| Sizing | **One engine per Gbps** of peak throughput, at least two engines in different availability zones |
| Pricing | 2020 figures: $2,500/year management server + $1,000/year per engine (Azure Standard Edition). Check current pricing |
| Verdict | Possible. Strong for migrations. Check replication mode details and private setup |

### Coviant Software Diplomat MFT

| Topic | Finding |
|---|---|
| What it is | **Managed File Transfer** (MFT): scheduled, audited file transfer jobs, built-in SFTP server |
| Deployment | ✅ **Self-hosted** on Windows or Linux, on-premises, in the cloud or hybrid |
| S3 ⇄ Azure | ✅ Connectors for **Amazon S3** (and S3-compatible) and **Azure Blob**. Number of connectors depends on the tier (Professional: 1, Enterprise: 5) |
| Private network | ✅ Fully in your network |
| Pricing | Vendor: Standard $3,999/year, Professional $8,499/year |
| Fit | Built for business file transfers (partners, SFTP, PGP, audit), not for syncing **millions of files** in a data lake |
| Verdict | Good if volumes are moderate and job-based. Not a data-lake sync engine |

### Signiant (Jet, SDCX Server)

| Topic | Finding |
|---|---|
| What it is | Accelerated file transfer platform (media focus). SaaS platform + **SDCX Server** software on your servers |
| Deployment | SDCX servers on-premises or in your cloud. Platform is **SaaS** |
| Private network | SDCX 7.3.1 (June 2026) supports deployment in a **private network without direct internet access**. Before that, servers need access to Signiant and Amazon domains |
| Cloud storage | S3 (role ARN or keys), Azure Blob (**access key**). **Hierarchical namespace (ADLS Gen2) must be off**: Data Lake storage isn't supported |
| Cloud-to-cloud | Transfers to and from cloud storage are coordinated by **cloud SDCX servers hosted by Signiant** |
| Verdict | ❌ Weak fit: SaaS coordination, no ADLS, key-based Azure auth |

### CData Arc

| Topic | Finding |
|---|---|
| What it is | **Managed file transfer (MFT)** and file automation. You build **flows** of connectors: files received by one connector are passed to the next |
| Deployment | ✅ **On-premises** on your own hardware or **private cloud** (Windows / .NET or cross-platform Java edition). Individual connectors can run as **microservices in Docker** |
| S3 connector | One connector per **bucket**. **Upload**: files arriving in the connector's Input folder are uploaded to the bucket / remote path. **Download**: polls the bucket at a set **interval** and passes new files on. Works with S3 and S3-compatible storage |
| Azure Blob connector | One connector per **storage account**. Send (upload) and receive (download), **overwrite** option, **file name / extension filters**, optional **delete after download** |
| S3 → Azure flow | `S3 connector (download)` → `Azure Blob connector (upload)`. Azure → S3 is the reverse flow. Files pass through the **Arc server's disk** |
| Private network | ✅ Arc runs in your network. Check that the S3 connector can use an **S3 interface/VPC endpoint URL** and that Azure Blob works through a **Private Endpoint** (private DNS). Auth options (IAM role vs. keys, managed identity vs. key/SAS) to check |
| Fit | Polling + staging on the server: fine for **moderate volumes** and business file flows. Not built to sync **millions of files** or mirror deletes in a data lake. Don't enable "delete after download" on the source unless you want a move |
| Verdict | ✅ Possible for job-based file flows, same category as Coviant Diplomat MFT |

## Recommended next steps

1. **Proof of concept** with **NetApp Copy and Sync** and **Resilio Active Everywhere** (optionally **CData
   Arc** or **Coviant Diplomat MFT** for job-based flows): one dataset in each
   direction, storage accounts with **public network access disabled**, S3 bucket policy restricted to your
   VPC endpoint.
2. Check network logs to confirm **no data** goes over the public internet, and list the **control-plane**
   connections each tool still needs (NetApp SaaS, Resilio licensing).
3. Measure throughput, behaviour with **millions of files**, delete handling, and restart after failure.
4. For Delta / Iceberg tables, keep the table-aware steps (`DEEP CLONE`, copy order with `_delta_log` last,
   `rewrite_table_path`). None of these tools understands table formats.

## Questions to ask each vendor

| Topic | Question |
|---|---|
| Control plane | Can it run **without any outbound internet**? If not, which endpoints (and can they go through a proxy)? |
| Licensing | Is there an **offline / air-gapped** licence? |
| Azure | **ADLS Gen2 with hierarchical namespace** supported? **Azure Private Endpoint** (not only service endpoints)? Managed identity / service principal instead of keys or SAS? |
| AWS | S3 **interface / gateway endpoints**? IAM roles instead of access keys? |
| Directions | S3 → Azure **and** Azure → S3, at the same time, without loops? |
| Deletes | Mirror deletes on/off? |
| Scale | Millions of files per job? Parallel jobs? How does it scale (brokers, agents, engines)? |
| Ordering | Can it copy in a set order or from a file list (needed for Delta / Iceberg)? |
| Cost | Licence model (per TB, per node, subscription)? Egress costs come on top |

## Related

- [`01-enterprise-cross-cloud-file-replication-tools.md`](01-enterprise-cross-cloud-file-replication-tools.md): first overview of enterprise tools
- [`../datasync/04-datasync-enhanced-mode.md`](../datasync/04-datasync-enhanced-mode.md): DataSync Enhanced mode, private mode
- [`../databricks-lakeflow/01-lakeflow-classic-file-replication-aws-azure.md`](../databricks-lakeflow/01-lakeflow-classic-file-replication-aws-azure.md): Databricks Lakeflow

## Sources

**NetApp**
- [Copy and Sync technical FAQ](https://docs.netapp.com/us-en/data-services-copy-sync/faq.html)
- [What's new with Copy and Sync (S3 private link)](https://docs.netapp.com/us-en/data-services-copy-sync/whats-new.html)
- [Supported sync relationships](https://docs.netapp.com/us-en/data-services-copy-sync/reference-supported-relationships.html)
- [Source and target requirements](https://docs.netapp.com/us-en/data-services-copy-sync/reference-requirements.html)
- [Networking overview](https://docs.netapp.com/us-en/data-services-copy-sync/reference-networking.html)
- [Create a data broker in Azure](https://docs.netapp.com/us-en/data-services-copy-sync/task-installing-azure.html)
- [Create a data broker in AWS](https://docs.netapp.com/us-en/data-services-copy-sync/task-installing-aws.html)
- [Learn about Copy and Sync](https://docs.netapp.com/us-en/data-services-copy-sync/concept-cloud-sync.html)

**Resilio**
- [Resilio Active Everywhere](https://www.resilio.com/active-everywhere/)
- [Resilio Help Center](https://docs.resilio.com/)
- [Ports and protocols](https://docs.resilio.com/content/getting-started/ports-protocols-port-forwarding/)
- [Cloud Agent: characteristics and limitations](https://www.resilio.com/documentation/content/advanced-configuration/cloud-storage/cloud_agent_-_characteristics_and_limitations/)
- [Management Console's agent](https://www.resilio.com/documentation/content/agents/Management_Consoles_Agent_/)
- [Change log Active Everywhere v4](https://www.resilio.com/documentation/content/about/changelog/change_log_resilio_active_everywhere_v4/)
- [Resilio platform security white paper](https://resilio.com/resources/assets/resilio-platform-security-white-paper.pdf)
- [Resilio blog: S3 and Azure sync](https://www.resilio.com/blog/amazon-s3-azure)

**Flexify.IO**
- [Flexify.IO](https://flexify.io/)
- [Multi-cloud storage](https://flexify.io/multi-cloud)
- [S3-Azure gateway](https://flexify.io/s3-azure)
- [Licensing policy](https://flexify.io/licensing-policy)
- [Release notes](https://flexify.io/release-notes)
- [Docker image (Community Edition)](https://hub.docker.com/r/flexifyio/ce)
- [StorageNewsletter (2020, pricing)](https://www.storagenewsletter.com/2020/09/22/flexify-io-promotes-universal-s3-gateway/)

**Coviant Software**
- [Diplomat MFT](https://www.coviantsoftware.com/diplomat-managed-file-transfer/)
- [Diplomat MFT cloud storage connector](https://www.coviantsoftware.com/diplomat-cloud-storage-connector/)
- [Diplomat MFT pricing](https://www.coviantsoftware.com/diplomat-managed-file-transfer/pricing/)
- [Azure Blob Storage and SFTP (vendor article)](https://www.coviantsoftware.com/compliance/azure-blob-storage-and-sftp-native-endpoint-true-cost-and-managed-file-transfer/)

**Signiant**
- [Jet overview](https://help.signiant.com/jet/general/overview)
- [SDCX Server release notes](https://help.signiant.com/jet/general/sdcx-release-notes)
- [SDCX Server system requirements](https://help.signiant.com/jet/general/system-requirements)
- [Jet deployment guide](https://help.signiant.com/jet/deployment/guide)
- [Endpoints overview](https://help.signiant.com/jet/administration/endpoints/overview)
- [Configuring Microsoft Azure storage](https://help.signiant.com/media-shuttle/signiant-console/storage/microsoft-azure-storage)

**CData**
- [CData Arc: S3 connector](https://cdn.cdata.com/help/AZJ/mft/S3.html)
- [CData Arc: Azure Blob connector](https://cdn.cdata.com/help/AZJ/mft/Azure-Blob.html)
- [CData Arc: application and data connectors](https://arc.cdata.com/apps/)
- [CData Arc: secure managed file transfer](https://arc.cdata.com/mft/)
- [CData Arc: scalable file transfer](https://arc.cdata.com/mft/scalability/)
