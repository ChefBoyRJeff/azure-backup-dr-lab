# Azure Backup and Recovery Lab

Backup **and proven restore** for two workloads: an Azure VM's OS disk (Azure Disk Backup, restored and swapped back in) and blob data (operational backup, point-in-time restore). Recovery objectives are defined up front, data loss is simulated, restores are verified by checksum, and recovery time is **measured**. A Backup vault's managed identity gets only the roles Microsoft documents for each operation. Target cost: under $1.

Built as a hands-on project while studying for **AZ-104: Microsoft Azure Administrator**. This is lab work in a personal subscription, not a production environment.

> **Status:** M0 (scaffold and budget) in progress. See [`docs/plan.md`](docs/plan.md) for the approved plan.
