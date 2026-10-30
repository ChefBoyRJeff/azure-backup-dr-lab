// Project 5 (azure-backup-dr-lab), M0: cost guardrail before anything billable exists.
// Subscription-scope budget filtered to the lab's resource groups.
//
// Why code instead of the portal: the portal's resource-group filter only lists groups that already have cost
// data, so brand-new empty groups can't be selected. The API accepts the names directly (M0 finding).
// Why a resource-group filter instead of a tag filter: Azure Disk Backup creates its own snapshots, which don't
// inherit our tags; a tag filter would miss the resources that actually cost money in this lab.
targetScope = 'subscription'

@description('Budget name')
param budgetName string = 'budget-backup-dr-lab'

@description('Monthly budget amount in the billing currency (USD)')
@minValue(1)
param amount int = 5

@description('First day of the budget period (must be the first of a month). Defaults to the current month.')
param startDate string = '${utcNow('yyyy-MM')}-01'

@description('Resource groups whose cost counts toward this budget')
param resourceGroupNames array = [
  'rg-backup-lab'
  'rg-backup-snapshots'
  'rg-backup-restore'
]

@description('Email for budget alerts. Supplied from a gitignored *.local.bicepparam file; @secure() keeps it out of deployment history.')
@secure()
param alertEmail string

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: budgetName
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    filter: {
      dimensions: {
        name: 'ResourceGroupName'
        operator: 'In'
        values: resourceGroupNames
      }
    }
    notifications: {
      Actual_50: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: [
          alertEmail
        ]
      }
      Actual_100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: [
          alertEmail
        ]
      }
      Forecasted_100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: [
          alertEmail
        ]
      }
    }
  }
}

output budgetName string = budget.name
output filteredResourceGroups array = resourceGroupNames
