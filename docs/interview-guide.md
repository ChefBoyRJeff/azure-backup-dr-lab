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

### Model answers

Check your own answers against these. Don't memorize them; an answer recited word for word sounds rehearsed.

**1. 7 AM one day, 6 AM the next.** The policy stores its schedule as an ISO 8601 repeating interval with a **fixed −05:00 offset** (`R/2026-10-30T06:00:00-05:00/P1D`), so it runs at 11:00 UTC every day. On Oct 31 the US was on daylight time (UTC−4), so 11:00 UTC was 7 AM local. After the clocks changed on Nov 1, it was 6 AM. The backup never moved; the local clock did. If a business needs a fixed local time, confirm how the service handles daylight saving, or schedule in UTC and communicate that.

**2. A 5-minute RTO for blob data.** Not with point-in-time restore: Microsoft documents it at up to an hour, and I measured a 15-minute job plus portal time. First ask which failure they mean. For a deleted or overwritten file, **soft-delete undelete or promoting a previous version** takes seconds and can be scripted, so 5 minutes is realistic. For losing the whole account or region, you need a second copy you can switch to (object replication to another account, or geo-redundant storage with read access), which costs more. Then test it and report the measured number.

**3. Only the disk instance was soft-deleted.** Soft delete protects backup data that the vault manages. The disk instance had recovery points backed by snapshots, so deleting it put them into a 14-day soft-deleted state. Operational blob backup keeps **no data in the vault**: the history lives in the storage account as versions and soft-deleted blobs, so the vault had nothing to retain. I observed this in the teardown evidence ([m5-02](evidence/m5-02-teardown.txt)); the explanation is my reading of what I saw.

**4. Why not click "Assign missing roles."** It grants roles on your behalf at scopes the portal chooses, which may be broader than what was reviewed and approved, and it leaves no deliberate record of the change. The message also often means a role you already assigned **hasn't propagated yet**. So check what's assigned at which scope, wait a few minutes, and revalidate. If something really is missing, assign that specific documented role at the narrowest scope, as a reviewed change.

**5. Hierarchical namespace enabled.** Then it's a Data Lake Storage Gen2 account, which Azure Backup protects as a **different datasource type** with vaulted backup and its own protected-instance cost. The operational-only blob policy wouldn't apply, and point-in-time restore support is limited for those accounts. Hierarchical namespace can't be turned off after creation, so you'd need a new account. That's why it was checked on the Advanced tab before creating the account.

**6. Proving a database restore.** Same principle: known data plus a check. Before the backup, insert marker rows with a unique value and record row counts or checksums of key tables. After the restore, confirm the database comes online cleanly, run an integrity check (`DBCC CHECKDB` for SQL Server), query the marker rows, compare the counts, and have the application connect and run a real transaction. Also make sure the backup was **application-consistent**, so you aren't restoring a database caught mid-write.

**7. Crash-consistent versus application-consistent.**
- **Crash-consistent:** the backup captures whatever was on disk at one instant, like pulling the power cord. Anything still in memory is lost, and the application may need to recover when it starts.
- **Application-consistent:** the application is told to flush and pause writes first (VSS on Windows, pre and post scripts on Linux), so the backup holds a clean state that starts without recovery.

**Likely next question: "Which one did your disk backup give you?"** Crash-consistent. Azure Disk Backup snapshots the disk without coordinating with the guest OS. I **deallocated the VM before the backup**, which shut it down cleanly, so in practice the snapshot held a consistent file system.

## 5. Honest Limits to Mention If Asked

- It's a lab: one VM, one storage account, a few megabytes of data.
- I ran the restores from the portal, which inflated one RTO.
- The role assignments were made with the CLI, not in Bicep.
- The vault itself is waiting for its soft-delete window to expire before it can be deleted.
- Lab 8's test failover didn't prove the RPO, and its test VM wasn't isolated ([RCA-004](rca/rca-004-test-failover-stale-and-not-isolated.md)).
- Lab 8 used a public IP on the VM for Site Recovery outbound. That's a lab shortcut, not a production pattern.

## 6. Lab 8: VM Backup and Site Recovery

> **Framing line:** "I extended the project to the two services I'd first ruled out on cost: VM backup in a Recovery Services vault, and Site Recovery to a second region. I kept it to about a day of billing. The interesting parts were what failed: replication couldn't start from a private subnet, and my failover drill passed for the wrong reason."

### Two-minute walkthrough

1. **Setup.** I built one Ubuntu VM in a **private subnet** on purpose: no public IP, default outbound access off. A Recovery Services vault on LRS protected it with an **Enhanced policy**, because the VM uses Trusted Launch.
2. **Backup and restore.** The backup worked although the VM couldn't reach the internet, because the platform takes the snapshot. I deleted and corrupted files, then restored with **Replace existing**. The first attempt was refused: the VM must be deallocated first. The second attempt passed: 3 of 3 hashes, RTO 27:37 against 30 minutes.
3. **Site Recovery.** I predicted replication would fail from the private subnet, and it did. The agent installed, but registration timed out (ARM `151192`, agent `20507`). The agent runs inside the guest and needs outbound HTTPS. A public IP fixed it, and the VM reached Protected in about 35 minutes.
4. **Test failover.** The files matched in West US. But I'd started the drill while replication was still catching up from an overnight auto-shutdown, and into the default target VNet, which has internet access. The files couldn't show how old the recovery point was, because nothing had changed since the baseline. So I wrote it up as **RPO not proven**, not as a pass.
5. **As code.** I exported the vault and wrote Bicep. What-if caught two values Azure stores for "no archive tier" that my template didn't declare. After that it came back clean.

### Likely questions

**Q: Why did backup work from a private subnet but Site Recovery didn't?**
VM backup is a platform operation: Azure snapshots the disks from outside the VM, so the VM's network doesn't matter. Site Recovery runs a Mobility agent inside the guest. The agent reads disk writes and sends them to a cache storage account. It also has to authenticate with Entra ID and talk to the Site Recovery service. All of that is outbound HTTPS from the VM itself.

**Q: How would you give it outbound access in production?**
Not with a public IP per VM. I'd use a NAT gateway or Azure Firewall on the subnet, or NSG rules with the documented service tags: `Storage` for the source region, `AzureActiveDirectory`, `EventHub` for the target region, and `AzureSiteRecovery`. Private endpoints for Site Recovery are another option. I used a public IP because the lab's cost policy blocks NAT gateways, and the NSG still denied all inbound traffic.

**Q: What's the difference between a test failover and a real failover?**
A test failover creates a copy of the VM in the target region from a recovery point, while replication keeps running and the source stays up. Then you clean it up. A real failover makes the target the production VM. After that you commit it, re-protect in the other direction, and eventually fail back. I only ran a test failover.

**Q: Your drill passed. Why do you call it a gap?**
Because the check I used couldn't fail. No data had changed since the baseline, so a 19-hour-old point and a 1-minute-old point have the same hashes. The plan had a marker file for that: write it just before the drill, then check whether it's there. I skipped that step by starting the drill early from the portal. Replication health was Critical at the time, after the VM had been off overnight.

**Q: Why can't you delete the vault yet?**
New Recovery Services vaults have soft delete always on, and it can't be turned off. When I stopped protection and deleted the backup data, the item went into a 14-day soft-deleted state, and a vault can't be deleted while it holds soft-deleted items. One instant restore snapshot is also still held, and trying to delete its resource group failed. Microsoft documents that recovery points of a soft-deleted item aren't cleaned up when they expire. That's my best explanation, but the error didn't say so. I'll clean up after the purge date.

**Q: Recovery Services vault or Backup vault, now that you've used both?**
A Recovery Services vault handles Azure VMs, SQL or SAP HANA in VMs, and Azure Files, and it also hosts Site Recovery. A Backup vault handles newer workloads: managed disks, blobs, PostgreSQL, AKS. Here I used a Recovery Services vault for VM backup, and Site Recovery created its own vault in the target region.

### Follow-up challenges to practice

1. A VM is replicated with Site Recovery and has an auto-shutdown schedule. What happens to the RPO, and what would you change?
2. Your test failover VM can reach the internet. Why is that a problem, and how do you prevent it?
3. Why might Replace existing fail where "create new VM" wouldn't?
4. You stopped backup and deleted the data. What still costs money, and for how long?
5. What does `defaultOutboundAccess: false` change, and which Azure services are affected?

### Model answers

**1.** While the VM is deallocated, nothing replicates, so the RPO keeps growing. After the VM starts, replication needs time to catch up; in my lab that was about 33 minutes. For a VM with an RPO target, I'd remove the shutdown schedule, or accept the gap and schedule drills only after the catch-up. In either case I'd alert on Site Recovery RPO health.

**2.** A test VM is a copy of production. With network access, it could talk to production dependencies, send email, or process jobs twice, and there would be two machines with the same identity. The fix is to choose a separate test VNet with no outbound path and no peering, every time. Don't accept the default target network.

**3.** Replace existing swaps the disks of the existing VM, so the VM must be deallocated first; otherwise the restore fails with `UserErrorVmNotShutDown`. It also needs a staging storage account. Create new builds a separate VM, so the original isn't touched.

**4.** The protected-instance fee stops. Soft-deleted backup data is retained for 14 days at no charge. But instant restore snapshots in the `AzureBackupRG_*` resource group can stay, and they bill as snapshot storage. With Replace existing, the old OS disk is also kept as an unattached disk until you delete it.

**5.** It disables the implicit outbound internet access Azure otherwise gives VMs in a subnet, so the subnet needs an explicit method: NAT gateway, firewall, load balancer outbound rules, or a public IP. Platform operations still work, such as VM backup snapshots and the VM agent through `168.63.129.16`. Anything in the guest that calls public endpoints fails: Site Recovery's agent, package updates, and some monitoring agents.
