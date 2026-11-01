# RCA-002: Blob Restore Missed Its RTO Target

| | |
|---|---|
| **Date** | 2026-11-01 |
| **Milestone** | M4, blob point-in-time restore |
| **Impact** | The data was fully recovered, but in **26:27** against a target of **≤ 15:00** |
| **Status** | Closed. The target was corrected and improvements identified. |
| **Evidence** | [m4-03](../evidence/m4-03-blob-baseline.txt), [m4-04](../evidence/m4-04-incident-restore.txt) |

## Summary

The point-in-time restore (PITR) worked exactly as designed: an overwritten blob and a deleted blob were both restored, and the control blob was unchanged, all verified by SHA-256. The **restore job alone took 15:22**, more than the whole target. The target was wrong: it was set without checking how long Microsoft documents PITR restores take.

## Timeline (UTC, 2026-11-01)

| Time | Event |
|---|---|
| 21:07:13 | Baseline uploaded (3 blobs), hashes recorded |
| 21:09:15 | Known-good restore point |
| 21:11:30–21:11:31 | **Incident:** `doc1.txt` overwritten, `doc2.txt` deleted |
| 21:11:36 | T0, damage detected |
| 21:22:07 | Restore job started, after navigating the portal and validating |
| 21:37:29 | Restore job completed (**15:22**) |
| 21:38:03 | All three hashes verified. **RTO 26:27.** |

## Root Cause

**The RTO target wasn't grounded in the service's documented behavior.** Microsoft Learn (*Perform a point-in-time restore on block blob data*):

> "The time that it takes to restore a set of data is based on the number of write and delete operations made during the restore period after up to one hour for the restore job to be picked up… A restore with a small number of changes would require up to one hour to restore."

A target of 15 minutes for a service documented at up to an hour was going to fail regardless of how the restore was run.

**Contributing factor:** 10:31 passed between detection and the restore job starting, mostly navigating the portal's restore wizard (selecting the instance, picking the point in time, choosing containers, validating). A 15-minute target can't absorb that either.

## What Went Right

- The recovery itself was correct: 2 of 2 damaged blobs restored, 1 of 1 untouched blobs unchanged.
- The restore was scoped to the affected container (`labdata`), not the whole account, which limits the blast radius.
- The miss was found in a test, before anyone relied on the target.

## Corrective Actions

| Action | Type |
|---|---|
| Set the PITR RTO from documented **and** measured behavior: **about 1 hour** | Target correction |
| Script the restore with the CLI (`az dataprotection backup-instance restore`), with the restore point and ranges as parameters | Removes most of the 10:31 navigation time |
| For a single damaged or deleted blob, use **soft-delete undelete** or **promote a previous version** instead of PITR. These take seconds and don't block the container. | Faster tool for the common case |
| Document that PITR **blocks reads and writes** on the restored ranges for the duration and **can't be cancelled** | Operational awareness |

## Lessons

- Recovery objectives are **requirements to verify**, not guesses. Before committing to a number, check the service's documented limits, then measure.
- RTO is end to end. Time spent in a wizard counts as much as time spent in the job.
- Picking the right recovery tool matters: PITR is for rolling back many changes across a container. It's the wrong tool for a single bad file in a hurry.
