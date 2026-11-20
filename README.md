# Azure Foundry Experiment

A private-network foundation for a hybrid application using Microsoft Foundry. The
resource-group-scoped Bicep deployment creates:

- A Foundry **resource and project** (the current project-based experience), with
  managed identities and Microsoft Entra authentication.
- A VNet with separate private endpoint and reserved application subnets, plus
  private endpoints and linked private DNS zones for Foundry and Blob Storage.
- A private StorageV2 account for application blobs, a Log Analytics workspace,
  workspace-based Application Insights, and resource diagnostic settings.
- Optional data-plane roles for an existing application managed identity.

The VNet, Foundry account, storage account, and workspace use pinned Azure
Verified Modules (AVM); the project and networking/monitoring extensions use
native resources. Public network access and key authentication are disabled for
Foundry and storage. Azure Monitor ingestion and queries remain public: private
monitoring requires an Azure Monitor Private Link Scope and additional DNS and
network design, which this baseline does not deploy. Application Insights is
available for application instrumentation; no application is deployed here.

## Prerequisites

- Azure CLI signed in to the intended subscription, a recent Bicep CLI, and
  access to `mcr.microsoft.com` to restore AVM modules.
- An existing resource group in a region supporting Foundry projects and the
  desired models. Register `Microsoft.CognitiveServices`, `Microsoft.Network`,
  `Microsoft.Storage`, `Microsoft.OperationalInsights`, and `Microsoft.Insights`
  resource providers. Creating resources requires appropriate resource-group
  permissions; optional role assignments also require `roleAssignments/write`.
- Choose a short, lowercase alphanumeric `namePrefix` (3–10 characters). Names
  include a deterministic resource-group/subscription suffix; Foundry custom
  subdomains and storage names must still be globally unique.
- Choose non-overlapping VNet and subnet CIDRs if the defaults conflict with
  on-premises or other Azure networks. The application subnet is reserved, not
  delegated; configure it for the chosen container platform before deployment.

## Deploy locally

```bash
az account set --subscription "<subscription-id>"
az group create --name "<resource-group>" --location "<region>"
az bicep build --file infra/main.bicep
az deployment group what-if --resource-group "<resource-group>" \
  --template-file infra/main.bicep --parameters infra/main.bicepparam
az deployment group create --resource-group "<resource-group>" \
  --template-file infra/main.bicep --parameters infra/main.bicepparam
```

Edit `infra/main.bicepparam` for your environment. The optional
`applicationPrincipalId` is the **object ID** of an existing managed identity
or service principal, not its client ID. It receives Cognitive Services OpenAI
User and Storage Blob Data Contributor at the respective resource scopes; omit
it to manage roles separately. Grant human project users appropriate Foundry
roles separately. Role propagation can take time.

No model is deployed by default: model availability, versions, deployment SKUs,
and quota vary by subscription and region. To deploy one, set `modelName`,
`modelVersion`, and optionally `modelDeploymentName`, `modelSku`, and
`modelCapacity` in the parameter file after checking regional availability and
quota. The output project endpoint is for SDK clients; use Entra credentials.

## CI/CD

`.github/workflows/deploy.yml` builds on pull requests and pushes to `main`.
Manual runs also perform a what-if and incremental deployment. Configure a
GitHub environment named `azure` with required reviewers, and set its secrets
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` and variable
`AZURE_RESOURCE_GROUP`. Create an Entra application or user-assigned managed
identity with a federated credential for the repository's `azure` environment
and least-privilege resource-group deployment permissions. Do not store client
secrets. The environment approval occurs before the what-if and deployment;
review the what-if locally or in a separate approved run before deploying.

## Hybrid connectivity and operations

Private endpoints do not create on-premises connectivity. Connect your network
using an existing VPN/ExpressRoute and routing (or deploy those separately).
On-premises DNS must conditionally forward the public service zones through an
Azure DNS Private Resolver inbound endpoint or a DNS forwarder in a linked VNet;
the deployment does not create that resolver. Peered VNets need their own zone
links or a central DNS design. Avoid duplicate private DNS zones in an existing
hub-and-spoke estate; adapt the template to use your centrally managed zones.
Test DNS and HTTPS from the application network, not a public runner.

Only the Blob endpoint is provisioned for storage. Add private endpoints and DNS
for file, queue, table, or DFS if the application needs them. Foundry agent
capability hosts, model deployments beyond the optional one, private outbound
dependencies, container hosting, alert rules, backup/DR, and production network
controls are not included. Foundry portal features and model/SKU availability
vary with network isolation and region; validate your chosen workload before
production. Review diagnostics retention, costs, data residency, and access
policies for your organization.
