// Project 5 (azure-backup-dr-lab), Lab 8 M6: the Recovery Services vault used for Azure VM backup, as code.
// Built in the portal first (Lab 8 M1-M2), then exported (infra/export/lab8, gitignored) and codified to match
// what Azure stored. Acceptance: what-if against the live vault reports no real drift.
//
// Recovery Services vault (Microsoft.RecoveryServices) is a different resource type from the Backup vault in
// infra/vault.bicep (Microsoft.DataProtection). VM backup with the Enhanced policy needs this one.
//
// Not managed here:
// - The Azure-created policies (DefaultPolicy, EnhancedPolicy, HourlyLogBackup). Azure adds them to every new vault;
//   incremental deployments leave them alone.
// - The backupstorageconfig and backupconfig child resources. They hold the same settings as redundancySettings and
//   securitySettings below, and storage redundancy is locked once an item has been protected.
// - Protected items. Protection is enabled per VM (portal or CLI), not deployed with the vault.
// - The ASR vault from Lab 8 M4. ASR created it in the target region (westus) and it was deleted in the teardown.
targetScope = 'resourceGroup'

@description('Region for the vault. Must be the region of the VMs it protects.')
param location string = resourceGroup().location

@description('Recovery Services vault name')
param vaultName string = 'rsv-dr-backup'

@description('Tags applied to the vault (matches what Azure stored, including the policy-required tags)')
param tags object = {
  costCenter: 'CC-1001'
  environment: 'lab'
  lab: 'lab8'
  owner: 'jeff'
  project: 'azure-backup-dr-lab'
}

@description('VM backup policy name')
param vmPolicyName string = 'pol-vm-enhanced'

@description('Daily backup time. Only the time of day is used; it is read in vmPolicyTimeZone, not UTC.')
param vmBackupTime string = '2026-11-07T22:00:00Z'

@description('Windows time zone name for the VM backup schedule')
param vmPolicyTimeZone string = 'Eastern Standard Time'

@description('Days to keep each daily recovery point in the vault')
@minValue(7)
param vmDailyRetentionDays int = 7

@description('Days to keep instant restore snapshots (Enhanced policy allows 1-30)')
@minValue(1)
@maxValue(30)
param vmInstantRpDays int = 1

resource vault 'Microsoft.RecoveryServices/vaults@2024-04-01' = {
  name: vaultName
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    redundancySettings: {
      // Cheapest option. Locked after the first protected item (StorageModelModifyError in Lab 8 M2).
      standardTierStorageRedundancy: 'LocallyRedundant'
      crossRegionRestore: 'Disabled'
    }
    securitySettings: {
      softDeleteSettings: {
        // Secure by default: soft delete is AlwaysON on new vaults and can't be turned off. Soft-deleted
        // data is free for 14 days, and the vault can't be deleted until that data is purged.
        softDeleteState: 'AlwaysON'
        softDeleteRetentionPeriodInDays: 14
        enhancedSecurityState: 'AlwaysON'
      }
      immutabilitySettings: {
        state: 'Disabled'
      }
    }
    restoreSettings: {
      crossSubscriptionRestoreSettings: {
        crossSubscriptionRestoreState: 'Enabled'
      }
    }
  }
}

// Enhanced policy (V2). Required for Trusted Launch VMs; the Standard policy (V1) is refused for them.
resource vmPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = {
  parent: vault
  name: vmPolicyName
  properties: {
    backupManagementType: 'AzureIaasVM'
    policyType: 'V2'
    instantRpRetentionRangeInDays: vmInstantRpDays
    timeZone: vmPolicyTimeZone
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicyV2'
      scheduleRunFrequency: 'Daily'
      dailySchedule: {
        scheduleRunTimes: [
          vmBackupTime
        ]
      }
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          vmBackupTime
        ]
        retentionDuration: {
          count: vmDailyRetentionDays
          durationType: 'Days'
        }
      }
    }
    tieringPolicy: {
      // No archive tier: recovery points stay in the vault-standard tier until they expire.
      // duration 0 / durationType 'Invalid' are the values Azure stores for DoNotTier. Declaring them keeps
      // what-if clean (Lab 8 M6: without them, what-if reported both as Delete on an unchanged policy).
      ArchivedRP: {
        tieringMode: 'DoNotTier'
        duration: 0
        durationType: 'Invalid'
      }
    }
  }
}

output vaultId string = vault.id
output vmPolicyId string = vmPolicy.id
