using './main.bicep'

param location = 'eastus2'
param env = 'poc'

// Two payers is the minimum that proves physical isolation. Contracts inside a
// payer are logical - Contoso holds two, which is what makes the _tag filter
// demonstrable rather than theoretical.
param payers = [
  {
    key: 'payera'
    displayName: 'Contoso Health Plan'
    contracts: [ 'CT-3456', 'CT-7788' ]
  }
  {
    key: 'payerb'
    displayName: 'Fabrikam Medicare Advantage'
    contracts: [ 'CT-9001' ]
  }
]

// BasicV2 deploys in ~10 min. Developer is ~1/3 the price but takes ~40 min and
// would burn the first half of a demo slot.
param apimSku = 'BasicV2'
param apimPublisherEmail = 'jaypadhya@microsoft.com'
param apimPublisherName = 'Providence St. Joseph Health - CMS DQM POC'

// Signed-in operator. Gets FHIR Data Contributor + Storage Blob Data Contributor
// + Key Vault Secrets Officer so the seed and demo scripts work unattended.
param operatorObjectId = '2b8ea1b5-28b1-4f81-8b29-2a72e3373890'

param deployApim = true
