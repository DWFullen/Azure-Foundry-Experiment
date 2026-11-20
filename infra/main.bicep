targetScope = 'resourceGroup'

@description('Lowercase alphanumeric prefix used for resource names (3-10 characters).')
@minLength(3)
@maxLength(10)
param namePrefix string
param location string = resourceGroup().location
param tags object = {}
param vnetAddressPrefix string = '10.40.0.0/16'
param privateEndpointSubnetPrefix string = '10.40.0.0/24'
param applicationSubnetPrefix string = '10.40.1.0/24'
@description('Object ID of an existing application service principal or managed identity; leave empty to skip role assignments.')
param applicationPrincipalId string = ''
@description('Model name; leave empty to skip model deployment.')
param modelName string = ''
param modelVersion string = ''
param modelDeploymentName string = 'default-model'
param modelSku string = 'GlobalStandard'
@minValue(1)
param modelCapacity int = 1

var suffix = take(uniqueString(subscription().id, resourceGroup().id), 12)
var baseName = '${namePrefix}${suffix}'
var vnetName = 'vnet-${baseName}'
var accountName = 'ai-${baseName}'
var storageName = 'st${baseName}'
var projectName = 'project'
var privateSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'private-endpoints')
var zoneNames = [
  'privatelink.services.ai.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.blob.${environment().suffixes.storage}'
]

module network 'br/public:avm/res/network/virtual-network:0.6.1' = {
  name: 'network'
  params: {
    name: vnetName
    location: location
    tags: tags
    enableTelemetry: false
    addressPrefixes: [vnetAddressPrefix]
    subnets: [
      {
        name: 'private-endpoints'
        addressPrefix: privateEndpointSubnetPrefix
      }
      {
        name: 'application'
        addressPrefix: applicationSubnetPrefix
      }
    ]
  }
}

module workspace 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  name: 'workspace'
  params: {
    name: 'log-${baseName}'
    location: location
    tags: tags
    enableTelemetry: false
    dataRetention: 30
    skuName: 'PerGB2018'
  }
}

module foundry 'br/public:avm/res/cognitive-services/account:0.15.0' = {
  name: 'foundry'
  params: {
    name: accountName
    location: location
    tags: tags
    enableTelemetry: false
    kind: 'AIServices'
    sku: 'S0'
    customSubDomainName: accountName
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    managedIdentities: {
      systemAssigned: true
    }
  }
}

module storage 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'storage'
  params: {
    name: storageName
    location: location
    tags: tags
    enableTelemetry: false
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
    }
  }
}

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundryAccount
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: projectName
  }
  dependsOn: [foundry]
}

resource model 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = if (!empty(modelName)) {
  parent: foundryAccount
  name: modelDeploymentName
  sku: {
    name: modelSku
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
  dependsOn: [foundry]
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zoneName in zoneNames: {
  name: zoneName
  location: 'global'
  tags: tags
}]

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zoneName, i) in zoneNames: {
  parent: zones[i]
  name: 'vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: network.outputs.resourceId
    }
  }
}]

resource foundryEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${accountName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'foundry'
        properties: {
          privateLinkServiceId: foundry.outputs.resourceId
          groupIds: ['account']
        }
      }
    ]
  }
  dependsOn: [network]
}

resource foundryZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: foundryEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for i in range(0, 3): {
      name: 'zone-${i}'
      properties: {
        privateDnsZoneId: zones[i].id
      }
    }]
  }
}

resource storageEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageName}-blob'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storage.outputs.resourceId
          groupIds: ['blob']
        }
      }
    ]
  }
  dependsOn: [network]
}

resource storageZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: storageEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: zones[3].id
        }
      }
    ]
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${baseName}'
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.outputs.resourceId
  }
}

resource foundryDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: foundryAccount
  properties: {
    workspaceId: workspace.outputs.resourceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
  dependsOn: [foundry]
}

resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: blobService
  properties: {
    workspaceId: workspace.outputs.resourceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'Transaction', enabled: true }]
  }
  dependsOn: [storage]
}

resource foundryRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(applicationPrincipalId)) {
  name: guid(foundryAccount.id, applicationPrincipalId, '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
  scope: foundryAccount
  properties: {
    principalId: applicationPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
  }
  dependsOn: [foundry]
}

resource storageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(applicationPrincipalId)) {
  name: guid(storageAccount.id, applicationPrincipalId, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccount
  properties: {
    principalId: applicationPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
  dependsOn: [storage]
}

output projectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${project.name}'
output foundryResourceId string = foundry.outputs.resourceId
output storageResourceId string = storage.outputs.resourceId
output applicationSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'application')
output applicationInsightsResourceId string = appInsights.id
output logAnalyticsResourceId string = workspace.outputs.resourceId
