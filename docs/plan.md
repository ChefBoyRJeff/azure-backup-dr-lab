# Project 5 Plan: Azure Backup and Recovery Lab

**Status:** Plan v2 approved 2026-10-30 (Disk Backup + Blob backup; VM backup with a Recovery Services vault was evaluated and declined on cost). **Executed 2026-10-30 to 2026-11-01; see [Outcomes and Deviations](#outcomes-and-deviations) at the end.**

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

## Outcomes and Deviations

Recorded after execution (2026-11-01). The plan above is kept as approved; this section records what actually happened.

| Milestone | Outcome | Deviation from plan |
|---|---|---|
| M0 | Budget deployed by Bicep; drift check clean except `@secure()` noise | Built in Bicep, not the portal: the portal budget filter can't select empty resource groups |
| M1 | Vault, policies, 3 disk roles; Bicep what-if 3 no change | The blob policy was created with the CLI from an explicit operational-only definition: the portal and the CLI default template both force the vaulted tier. The storage role was deferred to M4. Role assignments stayed CLI-managed. |
| M2 | Backup job 3:37; recovery point 16:24:02Z | None |
| M3 | Attempt 1 **FAIL** (Run Command replay, [RCA-001](rca/rca-001-run-command-replay.md)); attempt 2 **PASS**, RTO 10:23 | A second restore was needed; Lab 2 was rolled back to its original disk as planned |
| M4 | Data **PASS**; RTO 26:27 vs 15:00 **FAIL** ([RCA-002](rca/rca-002-blob-rto-target.md)) | Target corrected to about 1 h based on documented PITR behavior |
| M5 | Teardown complete except the vault and `rg-backup-lab` | Vault soft delete couldn't be turned off (`DppAlwaysOnSoftDeleteStateMandatory`); vault deletion deferred to the purge time **2026-11-15 21:45 UTC**. Snapshots survived instance deletion and were deleted explicitly. Azure Backup removed its own storage lock. |

Monitoring of backup jobs (planned for M5) was not built; it's listed as an improvement in the README. Project 2 covers alerting.

**Remaining actions after 2026-11-15 21:45 UTC:** delete policies `pol-disk-daily` and `pol-blob-operational`, vault `bv-backup-lab`, resource group `rg-backup-lab`; check the final cost; delete budget `budget-backup-dr-lab`.

## Lab 8 Extension: VM Backup and Site Recovery (2026-11-07 to 2026-11-08)

**Why it was added:** the original plan declined Azure VM backup and Azure Site Recovery on cost. Lab 8 covers both, for hands-on exposure before the AZ-104 exam, under the standing rule to keep lab costs as low as possible:
- one B1s VM with a Standard HDD disk;
- backup protection stopped the same day;
- Site Recovery torn down after the drill (its first 31 days are free).

**Objectives:**
- RTO ≤ 30:00 for a Replace existing VM restore.
- A test failover to West US with data verified by SHA-256.
- An RPO check using a marker written just before the drill.

| Milestone | Outcome | Deviation |
|---|---|---|
| M0 Preflight | Providers registered, quotas available, policy allows Recovery Services and public IPs (NAT gateway blocked), prices recorded | None |
| M1 Build | Private subnet (`defaultOutboundAccess: false`), Trusted Launch B1s VM, baseline hashes; outbound blocked as predicted | Disk changed from Standard SSD to Standard HDD (cost) |
| M2 VM backup | Vault LRS, Enhanced policy, backup Completed (27:18) with no VM outbound access; redundancy change refused | Soft delete was AlwaysON by default; the plan assumed it could be turned off |
| M3 Restore | Replace existing: attempt 1 refused (VM running), attempt 2 PASS, RTO 27:37 | Deallocation added to the runbook |
| M4 Site Recovery | Enable replication failed from the private subnet ([RCA-003](rca/rca-003-asr-registration-private-subnet.md)); Protected after a public IP was added | Default ASR policy and vault RG (the wizard offered no others) |
| M5 Test failover | Data 3 of 3 PASS in West US; RPO not proven; test VM not isolated ([RCA-004](rca/rca-004-test-failover-stale-and-not-isolated.md)) | Drill started before the health gate passed; marker never written |
| M6 Teardown and IaC | Everything deleted except the vault and one instant restore snapshot (soft-delete hold); vault codified in Bicep, what-if NoChange=2 | Resource group delete of `AzureBackupRG_eastus_1` failed (`ResourceDeletionFailed`) |
| M7 Docs | README Lab 8 section, RCA-003, RCA-004, interview guide | — |

**Remaining actions after 2026-11-21 16:10 UTC:**
1. Confirm the soft-deleted item `vm-dr01` has been purged.
2. Delete the restore point collection if it's still present, then `AzureBackupRG_eastus_1`.
3. Delete `rsv-dr-backup` and `rg-dr-lab`.
4. Check the actual Lab 8 cost in Cost Management.
