# RCA-003: Site Recovery Couldn't Register the VM From a Private Subnet

| | |
|---|---|
| **Date** | 2026-11-07 |
| **Milestone** | Lab 8 M4, Azure Site Recovery East US → West US |
| **Impact** | Enable replication failed after about 33 minutes. The VM reached Protected about an hour later than it would have with outbound access. Lab only, no data at risk. |
| **Status** | Resolved. After an outbound path was added, the retry reached **Protected** in about 35 minutes. |
| **Evidence** | [lab8-01](../evidence/lab8-01-build.txt) (sections 2–4), [lab8-04](../evidence/lab8-04-asr.txt) (sections 1–10) |

## Summary

`vm-dr01` was built on purpose in a **private subnet** (`defaultOutboundAccess: false`) with no public IP and no NAT gateway. Azure VM backup worked from that subnet (M2 and M3). Site Recovery didn't. The Mobility service agent installed in the guest, then failed to **register** with the Site Recovery service, because the VM had no outbound HTTPS. I predicted this before enabling replication (A1). The fix confirmed it: the agent registered as soon as the VM had an outbound path.

## Prediction (recorded before enabling)

> A1: enabling replication fails while vm-dr01 is in the private subnet with no public IP: the Mobility agent cannot reach Entra ID / the ASR service, and the job fails with a connectivity error code in the 151xxx range.

## Timeline (UTC, 2026-11-07)

| Time | Event |
|---|---|
| 14:52 | Build check: `curl` to `login.microsoftonline.com` and `www.microsoft.com` returns `000` (timeout); the platform address `168.63.129.16` returns 200 |
| 16:25–16:34 | Enable replication from the VM's **Disaster recovery** blade: vault, cache storage account, target VNet, policy, protection containers and network mappings all created |
| 16:46:43 | `AzureRcmCli --registermachine` attempt: `error code 20507` after about 5 minutes |
| 16:51:53 | Second attempt: same error after about 5 minutes |
| 16:57:03 | `Agent registration has failed`; extension `SiteRecovery-LinuxUBUNTU2404` reports `Installation and configuration failed` |
| 16:58:17 | ARM deployment fails: `151192` "Site recovery configuration failed" |
| 17:12–17:19 | Standard public IP `pip-vm-dr01` attached to the NIC; outbound now returns 302 / 200 |
| 17:19:04 | Retry: Enabling protection |
| 17:54:48 | **Protected**, health Normal |

## Symptoms

- Portal: "Deployment to resource group Site-recovery-vault-RG failed … At least one resource deployment operation failed."
- Extension `SiteRecovery-LinuxUBUNTU2404`: `ProvisioningState/failed/-9999`, "Installation and configuration failed."
- Site Recovery job **Enable replication: Failed**. Every earlier job (create site, policy, containers, network mappings) had succeeded.

## Investigation

| Source | Finding |
|---|---|
| ARM deployment operations | Inner error `151192` "Site recovery configuration failed" (resource reached terminal state Failed) |
| Site Recovery jobs (vault API) | Only `Enable replication` failed; all infrastructure jobs succeeded |
| Guest folders (Run Command, read-only) | `/usr/local/ASR` and `/usr/local/InMage` exist, so **the agent was installed** |
| `/var/log/ua_install.log` | Two `AzureRcmCli --registermachine` calls, each failing with `error code 20507` after about 5 minutes (a timeout pattern), then `Agent registration has failed` |
| Outbound test from the guest | `login.microsoftonline.com` → `000`, `www.microsoft.com` → `000` |

**Conclusion:** installation succeeded and **registration** failed. Registration is the first step where the agent in the guest calls out to the service.

## Root Cause

**Site Recovery's agent runs inside the VM and needs outbound HTTPS. The subnet was designed to have none.**

Microsoft's networking guidance for Azure VM disaster recovery says the replicated VM needs outbound access to:
- `login.microsoftonline.com` (Microsoft Entra ID);
- `*.hypervrecoverymanager.windowsazure.com` (the Site Recovery service);
- `*.servicebus.windows.net` (monitoring);
- `*.blob.core.windows.net` (the cache storage account in the source region).

With NSG rules, the equivalent service tags are `Storage.<source region>`, `AzureActiveDirectory`, `EventHub.<target region>` and `AzureSiteRecovery`. The VM had no route out at all.

**Why backup worked and replication didn't:** Azure VM backup is taken by the **platform**. The snapshot happens outside the guest, so the VM's network doesn't matter (prediction A4, held). Site Recovery is **in-guest**: the Mobility agent reads disk writes and sends them out through the VM's own network.

**Contributing factor:** the portal wizard didn't check outbound connectivity before deploying. It created the vault, cache account, target VNet and policy, then failed at the agent step about 30 minutes later.

## Remediation

1. Created a Standard static public IP (`pip-vm-dr01`) and attached it to the NIC. A NAT gateway would be the usual choice, but the lab's cost policy blocks NAT gateways (preflight, [lab8-00](../evidence/lab8-00-preflight.txt) section 4).
2. Kept inbound closed: `nsg-dr-app` had **0 custom rules**, so the default `DenyAllInBound` still applied.
3. Retried Enable replication from the portal.

## Verification

- Outbound from the guest: `login.microsoftonline.com` → 302, `www.microsoft.com` → 200.
- Replication: Enabling (17:19) → Initial replication (17:23) → Waiting for first recovery point (17:40) → **Protected, health Normal (17:54)**. Job `CompletedWithInformation`.
- Extension `SiteRecovery-LinuxUBUNTU2404`: `ProvisioningState/succeeded`. Replica disk created in `rg-dr-lab-asr` (West US).

The same agent registered as soon as it had outbound HTTPS. That confirms the cause.

## Side Findings (not the cause)

- **`ParentResourceNotFound`:** a nested deployment tried to write `automationAccounts/jobs` to an automation account that was never created (0 automation accounts in the subscription), even though agent updates were set to **Manually manage**. Not investigated further.
- **`AttributeError: module 'platform' has no attribute 'linux_distribution'`:** logged by the bootstrap extension on Ubuntu 24.04 (that function was removed from newer Python). The extension still reported success. Noise.

## Prevention

- **Preflight before enabling replication:** test outbound HTTPS from the guest to the four required endpoints. This is the same `curl` check the build already ran; it now gates the ASR step.
- **Production pattern:** don't use a public IP per VM. Give the subnet an explicit outbound path (a NAT gateway, or Azure Firewall with the FQDNs above), or NSG rules with the documented service tags. Private endpoints for Site Recovery are another documented option.
- **Know which services act from inside the guest** (Site Recovery, Azure Monitor Agent, update agents) and which act from the platform (VM backup snapshots, disk snapshots). Only the in-guest ones depend on the VM's network.

## Interview Takeaway

Backup and replication look alike in the portal, but they work differently. Backup snapshots the disks from outside the VM. Site Recovery runs an agent inside the VM that streams changes out, so it inherits the VM's network restrictions. I predicted the failure before enabling replication. I then traced it from the generic ARM error (`151192`) down to the agent's own log (`registermachine`, `20507`, 5-minute timeouts), and the fix confirmed the cause.
