# Interview Guide: Azure Backup and Recovery Lab

Talking points for this project. Everything happened in a **personal lab subscription**. Describe it as hands-on lab work, not production experience.

> **Framing line:** "I built a backup and recovery lab while studying for AZ-104. I didn't stop at 'the backup job succeeded.' I destroyed data on purpose, restored it, proved it by checksum, and timed it. Two of my three tests failed the first time, and I can walk you through why."

## 1. Three-to-Five-Minute Walkthrough

**Problem (30 s).** A backup is only proven by a restore. I wanted to test the whole chain: define a recovery point objective and a recovery time objective, back up, simulate data loss, restore, verify the data is exactly right, and measure the time against the target.

**What I built (60 s).**
- A **Backup vault** protecting two workloads: the OS disk of a Linux VM from my networking project, with Azure Disk Backup, and a storage account with operational blob backup.
- I chose the **operational tier** on purpose. VM backup in a Recovery Services vault costs $10 a month per protected VM. Disk Backup and operational blob backup have no protected-instance fee, so the whole lab was designed to cost under a dollar.
- The vault's **managed identity** got four narrow built-in roles, each scoped to one disk, one resource group, or one storage account. Nothing at subscription scope. I accessed blob data through Entra ID with a data role, never account keys.
- I built the vault in the portal first, then **codified it in Bicep** from the exported state, and what-if reported no changes.

**What went wrong (2 min).**
1. **The first disk restore failed verification.** The restore job succeeded, but the recovered disk had the destroyed data. I ruled out the obvious causes one at a time with evidence: wrong recovery point, wrong source snapshot, the VM still on the old disk. Then I read the disk's own boot history and the VM agent's Run Command folders. The restored disk was a genuine pre-incident copy, but **20 seconds after first boot, the VM agent replayed the destructive Run Command** I'd used to simulate the incident. The disk's record of what it had already run was older than the VM's latest command. I predicted the retry would replay a harmless read-only command instead, and it did. Hashes matched, RTO 10 minutes 23 seconds against a 30-minute target.
2. **The blob restore missed its RTO target.** The data came back perfectly, but in 26 minutes against 15. The restore job alone took 15. Microsoft documents that PITR can take up to an hour even for a few changes. **My target was wrong**, because I'd set it without checking the documented behavior. That's what restore testing is for.

**Close (15 s).** "The biggest lesson: a successful restore job isn't recovery. Only verified data is recovery, and recovery objectives have to come from documented and measured behavior, not guesses."

## 2. Ten-Minute Deep Dive (Outline)

| Minutes | Topic | Show |
|---|---|---|
| 0–2 | Architecture, the four roles and their scopes, why operational tier | README diagram, `m1-03` |
| 2–3 | Portal first, then Bicep; what-if NoChange; the forced vaulted blob policy | `infra/vault.bicep`, `m1-02`, `m1-04` |
| 3–7 | RCA-001: symptoms, four hypotheses, the forensic read, the prediction and confirmation | RCA-001, `m3-02`, `m3-03` |
| 7–9 | RCA-002: PITR timeline, documented behavior, corrected target, faster tools | RCA-002, `m4-04` |
| 9–10 | Teardown order: lock, soft delete, snapshots, roles | `m5-02` |

## 3. Likely Questions and Answers

**Q: What's the difference between RPO and RTO?**
RPO, the recovery point objective, is how much data you can afford to lose, measured in time. It's set by how often you take recovery points. RTO, the recovery time objective, is how long you can be down, from detection to working again. In my lab the disk RPO was up to 24 hours with daily backups, and the blob RPO was effectively continuous. I measured RTO end to end, including time in the portal.

**Q: Backup vault or Recovery Services vault?**
Different workloads. A Recovery Services vault handles Azure VM backup, SQL in a VM, and Azure Files. A Backup vault handles newer workloads like Azure Disks, Blobs, PostgreSQL, and AKS. I used a Backup vault because I protected a disk and blobs, which was also the cost decision: no protected-instance fee.

**Q: Why not just back up the VM?**
Cost and scope. VM backup is $10 a month per VM in that region, plus storage. For a lab whose goal was proving restores, Disk Backup gave me the same restore practice for cents. The trade-off: Disk Backup is crash-consistent at the disk level, with no application-consistent snapshots or file-level restore, and it restores to a new disk, not in place.

**Q: Why does the vault need roles at all?**
The vault acts through its own managed identity. It needs to read the source disk, write snapshots, create restored disks, and manage blob protection settings. Microsoft documents a specific built-in role for each, and says not to use Owner or Contributor. I scoped each one to the narrowest thing: one disk, one resource group, one storage account.

**Q: You're the subscription Owner. Why did you need a data role for blobs?**
Owner is a control-plane role: it manages resources. Reading and writing blob contents is the data plane, which needs a data role like Storage Blob Data Contributor. Without it, `--auth-mode login` gets an authorization error even for an Owner. Using Entra ID with a data role also meant I never touched account keys.

**Q: Walk me through RCA-001.**
The restored disk showed the post-incident state. I listed the possible causes and checked each: there was exactly one recovery point, and it predated the incident. The restored disk's creation data pointed to that snapshot. The VM's model, instance view, and disk ownership all showed it running on the restored disk. So I read the disk's own history. Its boot list had no boot from the incident time, so it really was a pre-incident copy. But the agent's Run Command folders showed the incident script appearing again 20 seconds after first boot. Run Command's latest configuration lives with the VM in Azure; the agent's record of what it has run lives on the disk. Restore the disk, and the agent sees an old command as new.

**Q: How did you fix it, and how do you prevent it?**
I tried to remove the Run Command extension, but v1 doesn't appear in the VM's extension list. So I made sure the latest Run Command was a read-only one, and the replay was harmless. Prevention: idempotent scripts, managed Run Commands, a no-op command before booting a restored disk, and verifying only after the agent settles, with a token that proves the result is fresh.

**Q: Why did the blob restore take so long?**
PITR works by replaying the change feed backwards, and Microsoft documents up to an hour for a restore job to be picked up and run, even for small changes. Mine took 15 minutes for the job, plus 10 minutes of portal navigation before it started. My 15-minute target simply didn't match the service.

**Q: What would you do for one deleted file instead?**
Not PITR. With soft delete and versioning on, I'd undelete the blob, or promote its previous version. That takes seconds and doesn't block the container. PITR is for rolling back many changes across a container to a consistent point in time.

**Q: What does this design not protect against?**
Losing the region or the subscription. Operational-tier backups are snapshots and in-account versions in the same region and subscription. For regional resilience, I'd use vaulted backups with cross-region restore. I'd also turn on immutability and a Resource Guard, so a compromised admin account couldn't delete the backups. Azure scored my vault's security level as "Poor" for exactly those reasons, which was a deliberate lab trade-off.

**Q: What made teardown tricky?**
Three things that block a simple "delete the resource group." Azure Backup puts a delete lock on a protected storage account; it removed the lock itself when I stopped protection. Soft delete keeps a deleted disk backup instance for 14 days and blocks deleting the vault. And deleting the backup instance didn't delete its snapshots, so I removed them explicitly. I also removed the vault identity's role assignments before deleting the vault, so nothing was left orphaned.

**Q: What would you change for production?**
Script the restores, set RTOs from measured behavior, idempotent automation, vaulted backups with cross-region restore, immutability and a Resource Guard, alerts on job failures and recovery-point age, and a private endpoint with shared-key access disabled on the storage account.

## 4. Follow-Up Challenges to Practice

Answer these out loud, without notes:

1. Your daily disk backup ran at 7 AM one day and 6 AM the next. Why?
2. A manager asks for a 5-minute RTO for the blob data. What do you tell them, and what would you propose?
3. Why did only the disk backup instance show up as soft-deleted, and not the blob one?
4. The portal's Backup readiness check says "Role assignment not done." Why shouldn't you just click "Assign missing roles"?
5. What would have happened if the storage account had hierarchical namespace enabled?
6. How would you prove a restore worked for a database instead of files?
7. Explain the difference between crash-consistent and application-consistent in one sentence each.

## 5. Honest Limits to Mention If Asked

- It's a lab: one VM, one storage account, a few megabytes of data.
- I ran the restores from the portal, which inflated one RTO.
- The role assignments were made with the CLI, not in Bicep.
- The vault itself is waiting for its soft-delete window to expire before it can be deleted.
