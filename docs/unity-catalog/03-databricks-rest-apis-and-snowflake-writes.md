# Databricks REST APIs, and updating a Databricks Iceberg table from Snowflake

Questions: what can the Databricks REST API be used for? Can an Iceberg table be updated from
Snowflake, for example?

> From Databricks and Snowflake docs. Not tested. ⚠️ marks syntax and details to check.

## Short answer

Yes, Snowflake can update a Databricks Iceberg table, but not through Databricks' general REST API.
It goes through **Unity Catalog's Iceberg REST catalog**, which is a separate, standard Iceberg API that
Databricks also offers. Snowflake connects to it as an Iceberg catalog and can then read and write
Unity Catalog **managed Iceberg** tables. According to Snowflake's release notes, writes are generally
available on AWS and, since April 2026, on Azure.

## What the Databricks REST APIs are for

| API group | Used for | Examples |
|---|---|---|
| **Workspace APIs** | Automating the workspace | Clusters, jobs (`/api/2.2/jobs`), notebooks, repos, secrets, SQL warehouses, model serving |
| **SQL Statement Execution API** | Running **SQL** on a SQL warehouse over HTTP | `POST /api/2.0/sql/statements` with `INSERT`, `UPDATE`, `MERGE`, `SELECT` |
| **Unity Catalog API** | Managing **metadata and permissions** | Catalogs, schemas, tables, grants, external locations, storage credentials, shares |
| **Account APIs** | Account administration | Workspaces, users and groups, service principals, budgets |
| **Iceberg REST catalog** (`/api/2.1/unity-catalog/iceberg-rest`) | Open Iceberg API so **other engines** can read and write Unity Catalog tables | Spark, Trino, Flink, **Snowflake**, PyIceberg |
| **Unity REST API** (Delta) | Open API so external Delta clients can access Unity Catalog tables | Delta clients, delta-rs |

**Changing table data** is therefore possible in two ways:

1. **Run SQL in Databricks** through the SQL Statement Execution API. Any tool that can make an HTTP
   call can do this, and the update runs on a Databricks warehouse.
2. **Write directly as an Iceberg engine** through the Iceberg REST catalog. This is how Snowflake does
   it, with its own compute.

## Snowflake → Databricks managed Iceberg table

```
Snowflake ──(catalog integration, OAuth)──► Unity Catalog Iceberg REST catalog
    │                                          │  checks permissions, commits the new snapshot
    └──(vended temporary credentials)────────► S3 / ADLS (writes Parquet + metadata files)
```

### Setup, in outline

| Step | Where | What |
|---|---|---|
| 1 | Databricks | Enable **external data access** on the metastore. Create a **service principal** with OAuth secret. Grant it `USE CATALOG`, `USE SCHEMA`, `EXTERNAL USE SCHEMA`, `SELECT`, `MODIFY` (and `CREATE TABLE` if Snowflake should create tables) |
| 2 | Snowflake | Create a **catalog integration** of type Iceberg REST pointing at Unity Catalog, with **vended credentials** |
| 3 | Snowflake | Create a **catalog-linked database** on that integration. Unity Catalog schemas and tables appear in Snowflake |
| 4 | Snowflake | Query and write with normal SQL: `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `CREATE TABLE … AS SELECT` |

```sql
-- Snowflake (⚠️ check parameter names in the current Snowflake docs)
CREATE CATALOG INTEGRATION uc_int
  CATALOG_SOURCE = ICEBERG_REST
  TABLE_FORMAT   = ICEBERG
  REST_CONFIG = (
    CATALOG_URI            = 'https://<workspace-url>/api/2.1/unity-catalog/iceberg-rest'
    WAREHOUSE              = '<uc_catalog_name>'
    ACCESS_DELEGATION_MODE = VENDED_CREDENTIALS )
  REST_AUTHENTICATION = (
    TYPE                 = OAUTH
    OAUTH_TOKEN_URI      = 'https://<workspace-url>/oidc/v1/token'
    OAUTH_CLIENT_ID      = '<sp-client-id>'
    OAUTH_CLIENT_SECRET  = '<sp-secret>'
    OAUTH_ALLOWED_SCOPES = ('all-apis') )
  ENABLED = TRUE;

CREATE DATABASE uc_linked LINKED_CATALOG = ( CATALOG = 'uc_int' );

-- write into the Databricks managed Iceberg table
UPDATE uc_linked."sales"."orders" SET status = 'shipped' WHERE order_id = 42;
INSERT INTO uc_linked."sales"."orders" SELECT * FROM staging.new_orders;
```

## Conditions and limits

| Point | Detail |
|---|---|
| **Table type** | Only **managed Iceberg** tables are writable. Delta tables (even with Iceberg reads), foreign tables and views are **read-only** for Snowflake |
| **Status** | Managed Iceberg in Databricks is **Public Preview**. Snowflake's write support for Unity Catalog is GA on AWS and Azure (Snowflake release notes) |
| **Unity Catalog stays in control** | Snowflake's writes are commits through Unity Catalog. Permissions apply, and Databricks sees the changes immediately |
| **Feature limits** | Unity Catalog's managed Iceberg limits still apply: no partition transforms, no UUID / Fixed / TIME types |
| **Older guidance** | A Databricks community post from about a year earlier said vended credentials only worked for reads, with a workaround for writes. Current Snowflake docs describe writable catalog-linked databases with vended credentials. Use the current docs |
| **Costs** | Snowflake compute for the writes. Databricks doesn't charge compute for external writes ⚠️, but storage and requests are billed by the cloud provider |

## In short

The Databricks REST APIs are mainly for automation, metadata and running SQL. Snowflake updates a
managed Iceberg table directly through **Unity Catalog's Iceberg REST catalog**, using a catalog
integration and a catalog-linked database, and Unity Catalog keeps control of permissions and commits.
Delta tables stay read-only for Snowflake.

## Related

- [`../iceberg/06-managed-iceberg-replication-deep-dive.md`](../iceberg/06-managed-iceberg-replication-deep-dive.md): external engines through the Iceberg REST catalog
- [`../iceberg/16-managed-iceberg-on-aws-glue-storage.md`](../iceberg/16-managed-iceberg-on-aws-glue-storage.md): one owner per table, engines on AWS
- [`01-managed-and-external-tables-sql.md`](01-managed-and-external-tables-sql.md): managed vs. external tables

## Sources

- [Snowflake: Write support for Databricks Unity Catalog on Azure (GA, April 2026)](https://docs.snowflake.com/en/release-notes/2026/other/2026-04-06-iceberg-write-support-azure-unity-catalog)
- [Snowflake: CTAS support for Databricks Unity Catalog (GA, March 2026)](https://docs.snowflake.com/en/release-notes/2026/other/2026-03-31-ctas-unity-catalog-external-volumes)
- [Snowflake: Tutorial – bidirectional access to Iceberg tables in Databricks Unity Catalog](https://docs.snowflake.com/en/user-guide/tutorials/tables-iceberg-set-up-bidirectional-access-to-unity-catalog)
- [Databricks Community: Databricks ↔ Snowflake interoperability with Unity Catalog](https://community.databricks.com/t5/technical-blog/how-to-set-up-databricks-snowflake-interoperability-with-unity/ba-p/128406)
- [Databricks: Access Databricks tables from Apache Iceberg clients](https://learn.microsoft.com/en-us/azure/databricks/external-access/iceberg)
- [Databricks: REST API reference](https://docs.databricks.com/api/workspace/introduction)
- [Databricks: SQL Statement Execution API](https://docs.databricks.com/aws/en/dev-tools/sql-execution-tutorial)
- [Databricksters: Write anywhere, read everywhere – Databricks and Snowflake](https://www.databricksters.com/p/write-anywhere-read-everywhere-achieving)
- [Medium (Snowflake): Iceberg interoperability between Snowflake and Databricks](https://medium.com/snowflake/iceberg-interoperability-between-snowflake-and-databricks-ba2beb45d08a)
