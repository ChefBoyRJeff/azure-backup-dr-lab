# Project 5 Plan: Azure Backup and Recovery Lab

**Status:** Plan v2 approved 2026-10-30 (Disk Backup + Blob backup; VM backup with a Recovery Services vault was evaluated and declined on cost). Nothing deployed yet.

## Business Problem

A backup is only proven by a **restore**. This lab defines recovery objectives, takes real backups, simulates data loss, restores, verifies the data by checksum, and records the **measured** recovery time against the target. It completes the portfolio's operations story: Project 2 detects incidents, Project 3 prevents bad changes, Project 5 recovers when something is lost anyway.

## Recovery Objectives

| Term | Meaning | Target in this lab |
|---|---|---|
| **RPO** (Recovery Point Objective) | Maximum acceptable data loss, measured in time | **≤ 24 h** (daily disk backup policy; on-demand backups for the tests) |
| **RTO** (Recovery Time Objective) | Maximum acceptable time from detection to working again | **≤ 30 min** for the OS disk restore + swap; **≤ 15 min** for blob point-in-time restore |

Both are **measured** in M3 and M4 and reported against these targets, pass or fail.

## Scope

| Workload | Protection | Vault |
|---|---|---|
| OS disk of `vm-spoke-lab2` (Lab 2, `rg-hubspoke-vms`; Ubuntu, Standard SSD 30 GB, security type Standard, platform-managed key) | **Azure Disk Backup**: operational tier, incremental snapshots | **Backup vault** |
| Test data in a new storage account | **Blob operational backup**: point-in-time restore (uses versioning, soft delete, change feed) | Same Backup vault |

**Out of scope (cost):** Azure VM backup in a Recovery Services vault ($10/month protected-instance meter, East US), vaulted backups, cross-region restore, Azure Site Recovery. A Recovery Services vault may be created **with no protected items** ($0) for portal familiarity only.

**Design consequence to document:** operational-tier backups are snapshots that stay in the **same subscription and region**. They protect against deletion, corruption, and bad changes, **not** against losing the region or the subscription. That's the trade-off for near-zero cost.

## Architecture

| Resource group | Contents | Vault managed identity role (least privilege, per Microsoft Learn) |
|---|---|---|
| `rg-backup-lab` | Backup vault `bv-backup-lab`; storage account for the blob workload | *Storage Account Backup Contributor* on the storage account |
| `rg-hubspoke-vms` (existing, Lab 2) | Source disk | *Disk Backup Reader* on the **disk** only |
| `rg-backup-snapshots` | Incremental snapshots created by Disk Backup | *Disk Snapshot Contributor* on this RG |
| `rg-backup-restore` | Disks restored from recovery points | *Disk Restore Operator* on this RG |

Microsoft Learn: "Use only the role definitions provided in the documentation. Use of other roles like owner, contributor, and so on, isn't supported."

## Milestones

| # | Milestone | Acceptance criteria | Billable? |
|---|---|---|---|
| M0 | Repo, plan, **budget** ($5/month, alerts at 50% actual, 100% actual, 100% forecast) on the three backup RGs, portal first, then Bicep | Budget visible in Cost Management; Bicep what-if NoChange vs. the portal build | $0 |
| M1 | Backup vault + disk and blob policies (portal first, then Bicep); vault managed identity role assignments (**approval: RBAC**) | What-if NoChange; role assignments listed at the exact scopes above, nothing broader | $0 |
| M2 | Disk backup: VM started, marker data + SHA-256 written, VM deallocated, **on-demand backup**, recovery point listed | Backup job Completed; duration recorded | Cents (snapshot) |
| M3 | **Incident: marker data destroyed** → restore recovery point as a new disk → **swap OS disk** on `vm-spoke-lab2` (**approval: modifies Lab 2**) → boot → checksum matches → RTO measured | Hash match; RTO vs. target; original disk kept until verified | Cents |
| M4 | Blob operational backup: data + hashes → overwrite and delete → **point-in-time restore** → hashes match → RTO measured | Hash match; RTO vs. target | < $0.01 |
| M5 | Monitoring of backup jobs, teardown (snapshots deleted explicitly), README, RCAs, interview guide | Bill for the project under $1; nothing left billing | — |

## Cost

| Item | Basis | Estimate |
|---|---|---|
| Backup vault, disk and blob operational backup | No protected-instance fee, no backup storage charge (Microsoft Learn) | $0 |
| Disk snapshots | Incremental, billed on used GB, standard storage | Cents while kept |
| Restored disk | Standard SSD 30 GB, billed hourly until deleted | Cents |
| VM runtime | B1s, about 1–2 h total (billed in `rg-hubspoke-vms`, outside the budget's filter) | ~$0.02 |
| Blob storage + point-in-time restore | MB of data; restore billed per GB processed | < $0.01 |
| **Total** | | **Target < $1; budget cap $5** |

Price reference (Azure Retail Prices API, East US, 2026-10-30): Azure VM Protected Instance $10.00/month; Standard LRS backup storage $0.02/GB-month; Azure Blob (vaulted) Protected Instance $10.00/month. Not used by this design, recorded as the basis for declining VM backup.

## Safety and Approvals

- Separate approval before: role assignments (M1), the OS disk swap on Lab 2's VM (M3), and any deletion.
- VMs deallocated after every test; power state checked after every run.
- The original OS disk is never deleted until the restored disk is verified, and the swap can be reversed.
- Evidence sanitized (GUIDs, emails) before every commit.

## Tooling

Azure CLI 2.90.0 with the **`dataprotection` extension 1.14.0** (approved 2026-10-30; Backup vault operations), Bicep 0.48.1, PowerShell 7, Git.

## Teardown (planned before creating anything)

1. Delete backup instances (soft delete keeps them 14 days at no backup charge; **snapshots keep billing at resource rates** until deleted, so delete them explicitly).
2. Delete restored disks and the storage account.
3. Remove role assignments; delete the vault once soft-deleted items have expired.
4. Delete the three backup resource groups and the budget.
