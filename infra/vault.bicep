// Project 5 (azure-backup-dr-lab), M1: Backup vault and backup policies as code.
// Built in the portal/CLI first, then exported (infra/export/, gitignored) and codified to match what Azure stored.
// Acceptance: what-if against the existing resources reports no changes (drift check).
//
// Not managed here: the vault identity's role assignments (Disk Backup Reader, Disk Snapshot Contributor,
// Disk Restore Operator). They were created with the CLI (docs/evidence/m1-03) and span resource groups outside
// this deployment; declaring them here would generate new assignment names that collide with the existing ones.
targetScope = 'resourceGroup'

@description('Region for the vault. Must match the region of the disks and storage accounts it protects.')
param location string = resourceGroup().location

@description('Backup vault name')
param vaultName string = 'bv-backup-lab'

@description('Tags applied to the vault')
param tags object = {
  project: 'azure-backup-dr-lab'
}

@description('Retention for disk snapshots and blob operational backup (ISO 8601 duration)')
param retention string = 'P7D'

@description('Disk backup schedule: start time with offset, repeated daily (ISO 8601 repeating interval)')
param diskBackupSchedule string = 'R/2026-10-30T06:00:00-05:00/P1D'

@description('Windows time zone name for the disk backup schedule')
param diskBackupTimeZone string = 'Eastern Standard Time'

resource vault 'Microsoft.DataProtection/backupVaults@2025-07-01' = {
  name: vaultName
  location: location
  tags: tags
  identity: {
    // The vault's own identity; the roles it needs are assigned at narrow scopes (see header).
    type: 'SystemAssigned'
  }
  properties: {
    storageSettings: [
      {
        // Applies to vaulted data only. This lab uses operational tier (snapshots / in-account blob data), so
        // the choice doesn't affect cost; LRS is the cheapest and can't be changed after items are protected.
        datastoreType: 'VaultStore'
        type: 'LocallyRedundant'
      }
    ]
    securitySettings: {
      softDeleteSettings: {
        // On (reversible), not AlwaysOn (permanent): the teardown must be able to delete the vault.
        state: 'On'
        retentionDurationInDays: 14
      }
      immutabilitySettings: {
        state: 'Disabled'
      }
    }
    featureSettings: {
      crossSubscriptionRestoreSettings: {
        state: 'Disabled'
      }
    }
  }
}

// Disk Backup: daily incremental snapshots kept in the operational store (snapshot resource group), 7 days.
resource diskPolicy 'Microsoft.DataProtection/backupVaults/backupPolicies@2025-07-01' = {
  parent: vault
  name: 'pol-disk-daily'
  properties: {
    objectType: 'BackupPolicy'
    datasourceTypes: [
      'Microsoft.Compute/disks'
    ]
    policyRules: [
      {
        name: 'Default'
        objectType: 'AzureRetentionRule'
        isDefault: true
        lifecycles: [
          {
            deleteAfter: {
              objectType: 'AbsoluteDeleteOption'
              duration: retention
            }
            sourceDataStore: {
              objectType: 'DataStoreInfoBase'
              dataStoreType: 'OperationalStore'
            }
            targetDataStoreCopySettings: []
          }
        ]
      }
      {
        name: 'BackupDaily'
        objectType: 'AzureBackupRule'
        backupParameters: {
          objectType: 'AzureBackupParams'
          backupType: 'Incremental'
        }
        dataStore: {
          objectType: 'DataStoreInfoBase'
          dataStoreType: 'OperationalStore'
        }
        trigger: {
          objectType: 'ScheduleBasedTriggerContext'
          schedule: {
            repeatingTimeIntervals: [
              diskBackupSchedule
            ]
            timeZone: diskBackupTimeZone
          }
          taggingCriteria: [
            {
              isDefault: true
              taggingPriority: 99
              tagInfo: {
                tagName: 'Default'
              }
            }
          ]
        }
      }
    ]
  }
}

// Blob operational backup: continuous, point-in-time restore within the storage account, 7 days.
// Operational only. The portal and the CLI default template (dataprotection 1.14.0) both add a vaulted rule,
// which carries a protected-instance fee; this definition deliberately has a single OperationalStore rule.
resource blobPolicy 'Microsoft.DataProtection/backupVaults/backupPolicies@2025-07-01' = {
  parent: vault
  name: 'pol-blob-operational'
  properties: {
    objectType: 'BackupPolicy'
    datasourceTypes: [
      'Microsoft.Storage/storageAccounts/blobServices'
    ]
    policyRules: [
      {
        name: 'Default'
        objectType: 'AzureRetentionRule'
        isDefault: true
        lifecycles: [
          {
            deleteAfter: {
              objectType: 'AbsoluteDeleteOption'
              duration: retention
            }
            sourceDataStore: {
              objectType: 'DataStoreInfoBase'
              dataStoreType: 'OperationalStore'
            }
            targetDataStoreCopySettings: []
          }
        ]
      }
    ]
  }
}

output vaultName string = vault.name
output vaultPrincipalId string = vault.identity.principalId
output diskPolicyId string = diskPolicy.id
output blobPolicyId string = blobPolicy.id
