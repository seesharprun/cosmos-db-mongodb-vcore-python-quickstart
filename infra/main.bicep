metadata description = 'Provisions resources for a web application that uses MongoDB driver for .NET to connect to Azure Cosmos DB for MongoDB vCore.'

targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
@description('Name of the environment that can be used as part of naming resource convention.')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

@description('Name of the pipeline executing the deployment in unattended scenarios.')
param pipelineName string = ''

@description('(Optional) Principal identifier of the identity that is deploying the template.')
param deploymentIdentityPrincipalId string = deployer().objectId

var resourceToken = toLower(uniqueString(resourceGroup().id, environmentName, location))

var tags = {
  'azd-env-name': environmentName
  repo: 'https://github.com/azure-samples/cosmos-db-mongodb-vcore-python-quickstart'
}

module managedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = {
  name: 'user-assigned-identity'
  params: {
    name: 'managed-identity-${resourceToken}'
    location: location
    tags: tags
  }
}

module mongoCluster 'mongo.bicep' = {
  name: 'mongo-cluster'
  params: {
    name: 'cosmos-db-mongodb-vcore-${resourceToken}'
    location: location
    tags: tags
    managedIdentityPrincipalId: managedIdentity.outputs.principalId
    deploymentIdentityPrincipalId: deploymentIdentityPrincipalId
    pipeline: !empty(pipelineName)
  }
}

module containerRegistry 'br/public:avm/res/container-registry/registry:0.9.1' = {
  name: 'container-registry'
  params: {
    name: 'containerreg${resourceToken}'
    location: location
    tags: tags
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
    acrSku: 'Standard'
    roleAssignments: [
      {
        principalId: managedIdentity.outputs.principalId
        roleDefinitionIdOrName: '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
      }
      {
        principalId: deploymentIdentityPrincipalId
        roleDefinitionIdOrName: '8311e382-0749-4cb8-b61a-304f252e45ec' // AcrPush
      }
    ]
  }
}

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.11.0' = {
  name: 'container-apps-env'
  params: {
    name: 'container-env-${resourceToken}'
    location: location
    tags: tags
    publicNetworkAccess: 'Enabled'
    zoneRedundant: false
  }
}

module containerAppsApiApp 'br/public:avm/res/app/container-app:0.16.0' = {
  name: 'container-apps-api-app'
  params: {
    name: 'container-app-api-${resourceToken}'
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'api' })
    ingressTargetPort: 8000
    ingressExternal: true
    ingressTransport: 'auto'
    stickySessionsAffinity: 'sticky'
    scaleSettings: {
      minReplicas: 1
      maxReplicas: 1
    }
    corsPolicy: {
      allowCredentials: true
      allowedOrigins: [
        '*'
      ]
    }
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [
        managedIdentity.outputs.resourceId
      ]
    }
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: managedIdentity.outputs.resourceId
      }
    ]
    secrets: [
      {
        name: 'azure-cosmos-db-mongodb-vcore-endpoint'
        value: mongoCluster.outputs.endpoint
      }
      {
        name: 'azure-tenant-id'
        value: subscription().tenantId
      }
      {
        name: 'user-assigned-managed-identity-client-id'
        value: managedIdentity.outputs.clientId
      }
    ]
    containers: [
      {
        image: 'mcr.microsoft.com/dotnet/samples:aspnetapp-9.0'
        name: 'api-back-end'
        resources: {
          cpu: '0.25'
          memory: '.5Gi'
        }
        env: [
          {
            name: 'ASPNETCORE_HTTP_PORTS'
            value: '8000'
          }
          {
            name: 'AZURE_CLIENT_ID'
            secretRef: 'user-assigned-managed-identity-client-id'
          }
          {
            name: 'SETTINGS__ENDPOINT'
            secretRef: 'azure-cosmos-db-mongodb-vcore-endpoint'
          }
          {
            name: 'SETTINGS__TENANTID'
            secretRef: 'azure-tenant-id'
          }
        ]
      }
    ]
  }
}

module containerAppsWebApp 'br/public:avm/res/app/container-app:0.16.0' = {
  name: 'container-apps-web-app'
  params: {
    name: 'container-app-web-${resourceToken}'
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'web' })
    ingressTargetPort: 8080
    ingressExternal: true
    ingressTransport: 'auto'
    stickySessionsAffinity: 'sticky'
    scaleSettings: {
      minReplicas: 1
      maxReplicas: 1
    }
    corsPolicy: {
      allowCredentials: true
      allowedOrigins: [
        '*'
      ]
    }
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [
        managedIdentity.outputs.resourceId
      ]
    }
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: managedIdentity.outputs.resourceId
      }
    ]
    secrets: [
      {
        name: 'azure-container-apps-api-endpoint'
        value: 'https://${containerAppsApiApp.outputs.fqdn}'
      }
    ]
    containers: [
      {
        image: 'mcr.microsoft.com/dotnet/samples:aspnetapp-9.0'
        name: 'web-front-end'
        resources: {
          cpu: '0.25'
          memory: '.5Gi'
        }
        env: [
          {
            name: 'SETTINGS__APIROOTENDPOINT'
            secretRef: 'azure-container-apps-api-endpoint'
          }
          {
            name: 'SETTINGS__HEADERSUFFIX'
            value: 'Azure Cosmos DB for MongoDB vCore - Python'
          }
        ]
      }
    ]
  }
}

// Azure Container Registry outputs
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer

// Application configuration outputs
output SETTINGS__ENDPOINT string = mongoCluster.outputs.endpoint
