// Example parameter file. Copy to budget.local.bicepparam (gitignored) and set your real email there.
//   Copy-Item infra\budget.example.bicepparam infra\budget.local.bicepparam
using './budget.bicep'

param alertEmail = 'you@example.com'
