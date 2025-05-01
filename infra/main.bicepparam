using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'development')
param location = readEnvironmentVariable('AZURE_LOCATION', 'westus')
param pipelineName = readEnvironmentVariable('AZURE_PIPELINE_NAME', '')
