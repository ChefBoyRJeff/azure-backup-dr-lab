# RCA-004: The Test Failover Ran on Old Data and Wasn't Isolated

| | |
|---|---|
| **Date** | 2026-11-08 |
| **Milestone** | Lab 8 M5, Site Recovery test failover |
| **Impact** | The drill proved the data comes back (3 of 3 hashes), but **not the RPO**. It most likely used a recovery point about 19 hours old. The test VM also had internet access, so it wasn't an isolated drill. Lab only: no production traffic and no conflict with the source VM. |
| **Status** | Closed with a documented gap. T2 (the RPO marker test) was never run. Replication was torn down after the drill to stop charges, so the drill wasn't repeated. |
| **Evidence** | [lab8-04](../evidence/lab8-04-asr.txt) section 10, [lab8-05](../evidence/lab8-05-test-failover.txt) sections 1–9, [lab8-06](../evidence/lab8-06-teardown.txt) section 6 |

## Summary

Two separate problems hit the same drill:

1. **Stale recovery point.** The VM's 19:00 auto-shutdown deallocated it overnight. With the VM off, there was no replication, so the RPO grew to about 18.7 hours. The drill was started while health was still **Critical**, before replication had caught up. It therefore restored an old point.
2. **Not isolated.** The test failover went into `vnet-dr-asr`, the target VNet that Site Recovery created, instead of a separate test VNet. That subnet has default outbound access on. The test VM reached the internet (HTTP 200), although the source subnet was private.

The data check passed anyway. That doesn't prove the drill was fresh: nothing had changed on disk since the baseline, so an old point and a new point hold the same hashes. That is exactly why the plan had an RPO marker (T2). The marker was never written.

## Predictions (recorded before the drill)

| # | Prediction | Result |
|---|---|---|
| T1 | doc1, doc2, payload.bin on the test VM match the baseline | **Held** (3 of 3) |
| T2 | A marker written seconds before the drill is ABSENT on the test VM ("Latest processed" point) | **Not tested.** The marker was never written. |
| T3 | The source keeps running and replication stays Protected during the drill | **Held.** RPO was back to 48 s at 19:35 UTC. |
| T4 | The test VM re-runs the read-only Run Command, harmlessly | **Undetermined.** The folder listing was cut off (`tail -4`). |
| T5 | The test VM has no outbound internet | **Wrong.** HTTP 200 from the test VM. |

## Timeline (UTC)

| Time | Event |
|---|---|
| 11-07 17:54 | Replication Protected, health Normal |
| 11-08 00:00 (19:00 ET) | Auto-shutdown deallocates `vm-dr01`; replication stops while it's off |
| 11-08 19:02:30 | `vm-dr01` booted (Step 1 of M5) |
| 11-08 19:05–19:35 | Step 1 waits up to 30 min for health Normal |
| **11-08 19:25:56** | **Test failover started in the portal** while health was Critical |
| 11-08 19:28:23 | Test failover job Succeeded (2:27); test VM booted 19:28:09 |
| 11-08 19:35:28 | Replication caught up: RPO 48 s |
| 11-08 19:35:56 | Step 1 guard stops: health still showed Critical, `rpoInSeconds 67254` |

## Investigation

- **Replication health ([lab8-05](../evidence/lab8-05-test-failover.txt) 2b–2d):** Mobility services were running (`uarespawnd` active, `svagents` and `s2` processes), and outbound worked (302 / 200). So the agent was healthy (H1 and H2 rejected). It needed about 33 minutes after boot to catch up. Why that took so long is unconfirmed. Warning `153006` (no app-consistent point in 510 minutes) came from the default policy, which takes app-consistent snapshots, while the VM was off.
- **Which point the drill used:** the API returned `customDetails: null` and didn't name the recovery point. RPO was 67,254 s when the drill ran, so the latest processed point was from before the shutdown. **This is an inference, not a confirmed fact.**
- **Test network ([lab8-05](../evidence/lab8-05-test-failover.txt) 6–7, [lab8-06](../evidence/lab8-06-teardown.txt) 1):** the test NIC was in `vnet-dr-asr/snet-app` with no public IP, and `defaultOutboundAccess` on that subnet was unset (that is, default outbound on). The VNet Site Recovery creates in the target region didn't copy the source subnet's private setting.

## Root Cause

1. **A cost control conflicted with continuous replication.** Auto-shutdown is right for a lab VM, but a deallocated VM doesn't replicate. Every night off adds that time to the RPO, plus a catch-up period after the VM starts.
2. **Process: the drill didn't wait for its own gate.** The test failover was started from the portal while the scripted health check was still running. No one checked the recovery point age, and the marker step was skipped.
3. **Process: the test network was the portal default.** "Isolated test network" was a prediction, not a choice made in the wizard. The default target VNet isn't isolated.

## Remediation

- **Cleanup test failover** removed the test VM, its NIC and the test disk (K1). Disable replication removed the replica disk (K2). Both ASR resource groups were deleted (K4).
- The drill is recorded as it actually ran, including the deviation. T2 is reported as **not tested**, not as passed.

## Prevention: Drill Checklist

1. Replication health is **Normal** and the RPO is inside the target. Check it immediately before the drill, not just once earlier.
2. Write an **RPO marker**, wait for a recovery point newer than the marker, then choose that point (or "Latest processed") explicitly.
3. Choose the **test network explicitly**: a separate VNet with no outbound path and no peering to production. Never use the failover target VNet.
4. For VMs that must meet an RPO, **don't auto-shutdown**. If cost forces a shutdown, plan the drill for after the catch-up, and record the RPO you actually got.
5. If application consistency isn't needed, set the app-consistent snapshot frequency to 0, as warning `153006` recommends.

## Interview Takeaway

The test failover "worked": the VM came up in West US and the files matched. But the files couldn't have told me whether the point was 1 minute or 19 hours old, because nothing had changed since the baseline. The RPO marker was the test that could. I skipped it by starting the drill early from the portal, while replication was still catching up from an overnight shutdown. I wrote that up as a gap instead of a pass. I also learned that the default target network isn't isolated. In a real drill, I'd choose an isolated network on purpose, check the RPO right before starting, and use a marker to prove which point I restored.
