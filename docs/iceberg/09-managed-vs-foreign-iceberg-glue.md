# Is an Iceberg table in AWS Glue "foreign" in Databricks?

Short answer: **yes**, an Iceberg table whose catalog is AWS Glue is a **foreign** table in
Databricks' terms, but only once you've connected Glue to Unity Catalog (Lakehouse Federation).
What decides it is **which catalog owns the table's metadata**, not that the data is on AWS.

> Based on the Databricks documentation (see sources). Not tested against a real workspace.

## Classification

| Your table | What Databricks calls it | Databricks can | External engines through Unity Catalog's Iceberg REST catalog |
|---|---|---|---|
| Iceberg table created in **Unity Catalog** (data in S3, on Databricks on AWS) | **Managed** Iceberg table | Read and write | Read and write |
| Iceberg table in **AWS Glue**, with Glue connected to Unity Catalog (Lakehouse Federation) | **Foreign** Iceberg table | Read only | Read only |
| Iceberg table in **AWS Glue**, *not* connected | Not in Unity Catalog | Nothing | Not available. Engines use Glue directly |

## What this means

- A table on AWS that lives in Glue is a **standard Iceberg** table, as in
  [`07-standard-iceberg-replication-deep-dive.md`](07-standard-iceberg-replication-deep-dive.md).
  Glue stays its owner, and Databricks shows it as a foreign table you can only read.
- "Managed" only applies to Iceberg tables that **Unity Catalog itself owns**, as in
  [`06-managed-iceberg-replication-deep-dive.md`](06-managed-iceberg-replication-deep-dive.md).
  Being on AWS or S3 doesn't make a table managed.
- To make a Glue table managed, deep clone it into Unity Catalog:

  ```sql
  CREATE TABLE uc.db.t DEEP CLONE glue_fed.db.t;
  ```

  This is a full copy into new storage. Databricks says it can't convert a foreign table to a
  managed one without copying the data. After that, Unity Catalog owns the copy, and the Glue
  original is a separate table.

## Trino and other engines

The Iceberg REST catalog documentation says foreign Iceberg tables are read-only through that
endpoint too, so Trino can't write to a Glue table via Unity Catalog. It can write to it
directly through Glue.

## Related

- [`15-add-foreign-iceberg-table-to-unity-catalog.md`](15-add-foreign-iceberg-table-to-unity-catalog.md): how to add a Glue table to Unity Catalog as a foreign table
- [`05-cross-cloud-replication-aws-azure.md`](05-cross-cloud-replication-aws-azure.md) §2: which Iceberg variants work with Unity Catalog
- [`07-standard-iceberg-replication-deep-dive.md`](07-standard-iceberg-replication-deep-dive.md) §1–2: standard Iceberg and catalog topology

## Sources

- [Databricks: What is Apache Iceberg in Databricks? (managed vs. foreign tables)](https://docs.databricks.com/aws/en/iceberg/)
- [Databricks: Work with foreign tables](https://learn.microsoft.com/en-us/azure/databricks/tables/foreign)
- [Databricks: Clone a managed Iceberg table (foreign → managed, no zero-copy conversion)](https://learn.microsoft.com/en-us/azure/databricks/iceberg/clone)
- [Databricks: Access Databricks tables from Apache Iceberg clients (foreign tables read-only)](https://learn.microsoft.com/en-us/azure/databricks/external-access/iceberg)
