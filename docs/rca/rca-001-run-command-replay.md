# RCA-001: Restored Disk Came Back Already Damaged (Run Command Replay)

| | |
|---|---|
| **Date** | 2026-10-30 |
| **Milestone** | M3, disk restore |
| **Impact** | The first restore failed verification. The recovered data was destroyed again about 20 seconds after the restored disk's first boot. |
| **Status** | Resolved. The retry passed, with an RTO of 10:23. |
| **Evidence** | [m3-01](../evidence/m3-01-incident-restore.txt), [m3-02](../evidence/m3-02-diagnosis.txt), [m3-03](../evidence/m3-03-retry.txt), [m5-02](../evidence/m5-02-teardown.txt) |

## Summary

The backup and the restore both worked. The restored disk was a correct copy from before the incident. But when the VM booted from it, the Azure VM agent ran the **incident script again**. The disk's record of which Run Command scripts it had already executed was older than the VM's latest Run Command, so the agent treated the incident script as new and ran it.

## Timeline (UTC, 2026-10-30)

| Time | Event |
|---|---|
| 15:59:49 | Baseline written through Run Command: `marker.txt` and `payload.bin`, SHA-256 recorded |
| 16:22:06 | Disk Backup snapshot (recovery point 16:24:02) |
| 16:29:50 | **Incident** through Run Command: `marker.txt` deleted, `payload.bin` overwritten with zeros |
| 16:30:11 | T0, damage detected |
| 16:34:03–16:37:40 | Restore job: new disk from the 16:22 snapshot |
| 16:39:03 | OS disk swapped to the restored disk |
| 16:39:28 | Restored disk's first boot |
| **16:39:48** | **Run Command folder `12`, the incident script, created on the restored disk; `payload.bin` modified** |
| 16:40:20 | Verification Run Command: marker missing, payload zeros. **FAIL.** |

## Symptoms

After the restore and the swap, verification showed exactly the post-incident state: `marker.txt` missing and `payload.bin` with the hash of 5 MB of zeros (`c036cbb7…`).

## Investigation

Each hypothesis was tested with evidence, in order of likelihood:

| # | Hypothesis | Check | Result |
|---|---|---|---|
| 1 | A newer recovery point (taken after the incident) was used | Recovery points, jobs, snapshots | **Ruled out:** exactly one recovery point (16:24:02), one backup job, one snapshot |
| 2 | The restored disk wasn't created from the recovery point | `creationData` of the restored disk | **Ruled out:** `Copy` from snapshot `…2026-10-30T16-22-06` |
| 3 | The VM was still running on the original disk | VM model, instance view, `diskState` and `managedBy` of both disks, activity log | **Ruled out:** the restored disk was `Reserved` by the VM; the original was `Unattached`; the order was swap, then start, then Run Command |
| 4 | The restored disk's contents changed after boot | The disk's own history: `journalctl --list-boots`, `/var/lib/waagent/run-command/download/N` folders, file timestamps | **Confirmed** (below) |

The disk's own history, read in the forensic step ([m3-02](../evidence/m3-02-diagnosis.txt)):

- **Boots:** 15:58, then **16:39:28**, then 16:47. There was **no boot at 16:29**, so this disk had never experienced the incident boot. It was a genuine pre-incident copy.
- **Run Command folders:** `11` (15:59:49, baseline script) was the last one present when the snapshot was taken. Folder **`12` was created at 16:39:48** on this disk and contains `rm -f marker.txt` and `dd if=/dev/zero`.
- **`payload.bin` mtime:** 16:39:48.78, immediately after folder `12`.

## Root Cause

Run Command v1 is delivered to the VM as an extension. Its **latest configuration lives with the VM in Azure, not on the disk.** The guest agent keeps a record **on the disk** of which configuration it has already executed.

Restoring the disk rolled back the agent's record to "last run: #11." Azure still offered the latest configuration, #12, the incident script. The agent saw a configuration it had never executed, and ran it.

**Contributing factor:** the incident was injected with a non-idempotent Run Command, which a replay would repeat.

## Resolution

1. Tried to remove the Run Command extension before the retry: `az vm extension list` showed **nothing**. Run Command v1 is platform-managed and doesn't appear in the VM's extension list, so it can't be deleted that way. This corrected an assumption in the first fix plan.
2. **Mitigation used:** the latest Run Command issued since the incident was a **read-only** forensic script. A replay of it is harmless.
3. Retry ([m3-03](../evidence/m3-03-retry.txt)): new restore to `vm-spoke-lab2-osdisk-restored2`, swap, boot, **90-second agent settle wait**, then verification with a **one-time token** echoed back, to prove the output came from a fresh run.

## Verification

- Both SHA-256 hashes matched the baseline, the marker nonce matched, and `payload.bin` had mtime 15:59:49. **RTO 10:23, PASS.**
- **The prediction was confirmed:** on the retry disk, folder `14` (the read-only forensic script) was created 21 seconds after first boot. Folders `12` and `13` didn't exist.
- **Observed a third time** during teardown (G6): booting the original disk, last executed #12, replayed #15, the read-only verification, as folder `15`, about 30 seconds after boot.

## Prevention

- **Make every Run Command and Custom Script Extension script idempotent**, so running it twice is safe. Destructive one-off actions shouldn't go through a mechanism that can replay.
- **Before booting a restored disk**, make sure the VM's latest Run Command is harmless. For example, issue a no-op Run Command first.
- Prefer **managed Run Commands** (`az vm run-command create`) for scripted operations; they have explicit lifecycle and status.
- **Verify after an agent settle period**, and prove the result is fresh, with a token or a timestamp, before trusting a recovery check.
- Treat "the restore job succeeded" as a step, not as the result. Only data verification proves recovery.

## Lessons

- A disk restore restores the **guest's state**, but not the **platform's view of that VM**. Anything that reconciles the two at boot (extensions, agents, configuration management) can act on restored data.
- The diagnosis came from evidence the disk kept about itself. Ruling out the obvious causes first (wrong recovery point, wrong source, wrong disk attached) is what made the unusual one credible.
