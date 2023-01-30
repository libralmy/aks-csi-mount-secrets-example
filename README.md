# publicAKSwithAKV-CSIDriver
```sh
az group create -n myResourceGroup -l eastus

az aks create -n myAKSCluster -g myResourceGroup --enable-addons azure-keyvault-secrets-provider --enable-managed-identity

az account set --subscription 89a596f0-5a62-4e8d-8c80-6b396faa037c

az aks get-credentials --resource-group myResourceGroup --name myAKSCluster

kubectl get pods --all-namespaces=true

kubectl get pods -n kube-system -l 'app in (secrets-store-csi-driver, secrets-store-provider-azure)'

az keyvault create -n kv20230124 -g myResourceGroup -l eastus
```
## Your Azure key vault can store keys, secrets, and certificates. In this example, you'll set a plain-text secret called ExampleSecret
```sh
az keyvault secret set --vault-name kv20230124 -n ExampleSecret --value MyAKSExampleSecret
```
## Create workload identity
```sh
az extension add --name aks-preview
az extension update --name aks-preview
az feature register --namespace "Microsoft.ContainerService" --name "EnableWorkloadIdentityPreview"
az provider register --namespace Microsoft.ContainerService
```
```sh
az aks update -n myAKSCluster -g myResourceGroup --enable-oidc-issuer --enable-workload-identity --generate-ssh-keys
```
```sh
export subscriptionID=89a596f0-5a62-4e8d-8c80-6b396faa037c
export resourceGroupName=myResourceGroup
export UAMI=kvidy
export KEYVAULT_NAME=kv20230124
export clusterName=myAKSCluster

az account set --subscription $subscriptionID
az identity create --name $UAMI --resource-group $resourceGroupName
export USER_ASSIGNED_CLIENT_ID="$(az identity show -g $resourceGroupName --name $UAMI --query 'clientId' -o tsv)"
export IDENTITY_TENANT=$(az aks show --name $clusterName --resource-group $resourceGroupName --query aadProfile.tenantId -o tsv)

az keyvault set-policy -n $KEYVAULT_NAME --key-permissions get --spn $USER_ASSIGNED_CLIENT_ID
az keyvault set-policy -n $KEYVAULT_NAME --secret-permissions get --spn $USER_ASSIGNED_CLIENT_ID
az keyvault set-policy -n $KEYVAULT_NAME --certificate-permissions get --spn $USER_ASSIGNED_CLIENT_ID

export AKS_OIDC_ISSUER="$(az aks show --resource-group $resourceGroupName --name $clusterName --query "oidcIssuerProfile.issuerUrl" -o tsv)"
echo $AKS_OIDC_ISSUER
```
## a1 Use a user-assigned managed identity
```sh
az aks update -n myAKSCluster -g myResourceGroup --enable-managed-identity
export USER_ASSIGNED_CLIENT_ID="$(az aks show -g $resourceGroupName -n $clusterName --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv)"
az aks get-credentials --resource-group $resourceGroupName --name $clusterName --overwrite-existing

cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-kvname-user-msi-new
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"         
    userAssignedIdentityID: "${USER_ASSIGNED_CLIENT_ID}" 
    keyvaultName: kv20230124 
    cloudName: ""
    objects:  |
      array:
        - |
          objectName: ExampleSecret
          objectType: secret              
          objectVersion: ""               
    tenantId: "${IDENTITY_TENANT}"    
EOF

kind: Pod
apiVersion: v1
metadata:
  name: busybox-secrets-store-inline-user-msi
spec:
  containers:
    - name: busybox
      image: k8s.gcr.io/e2e-test-images/busybox:1.29-1
      command:
        - "/bin/sleep"
        - "10000"
      volumeMounts:
      - name: secrets-store01-inline
        mountPath: "/mnt/secrets-store"
        readOnly: true
  volumes:
    - name: secrets-store01-inline
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: "azure-kvname-user-msi-new"
```
## a2 Use workload identity
```sh
kubectl create namespace csi
export serviceAccountName="workload-identity-sa" 
export serviceAccountNamespace="csi" 

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${USER_ASSIGNED_CLIENT_ID}
  labels:
    azure.workload.identity/use: "true"
  name: ${serviceAccountName}
  namespace: ${serviceAccountNamespace}
EOF
```
## fed identity
```sh
export federatedIdentityName="aksfederatedidentity"
az identity federated-credential create --name $federatedIdentityName --identity-name $UAMI --resource-group $resourceGroupName --issuer ${AKS_OIDC_ISSUER} --subject system:serviceaccount:${serviceAccountNamespace}:${serviceAccountName}
```
## Deploy a SecretProviderClass by using the following YAML script
```sh
cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-kvname-workload-identity 
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "false"          
    clientID: "${USER_ASSIGNED_CLIENT_ID}" 
    keyvaultName: kv20230124    
    cloudName: ""                      
    objects:  |
      array:
        - |
          objectName: ExampleSecret
          objectType: secret              
          objectVersion: ""               
    tenantId: "${IDENTITY_TENANT}"      
EOF
```
## Deploy a sample pod. Notice the service account reference in the pod definition:
```sh
cat <<EOF | kubectl -n $serviceAccountNamespace --format -
kind: Pod
apiVersion: v1
metadata:
  name: busybox-secrets-store-inline-user-msi
spec:
  serviceAccountName: ${serviceAccountName}
  containers:
    - name: busybox
      image: k8s.gcr.io/e2e-test-images/busybox:1.29-1
      command:
        - "/bin/sleep"
        - "10000"
      volumeMounts:
      - name: secrets-store01-inline
        mountPath: "/mnt/secrets-store"
        readOnly: true
  volumes:
    - name: secrets-store01-inline
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: "azure-kvname-workload-identity"
EOF
```
## show secrets held in secrets-store
```sh
kubectl exec busybox-secrets-store-inline-user-msi -- ls /mnt/secrets-store/
```
## Error message
### the new pod we created that try to access the KV is always under "ContainerCreating"
![MicrosoftTeams-image (10)](https://user-images.githubusercontent.com/20976896/214369234-dff1ba57-ee0e-45aa-8c1f-ebd1704cded6.png)
### pod/busybox-secrets-store-inline-user-msi   MountVolume.SetUp failed for volume "secrets-store01-inline" : rpc error: code = Unknown desc = failed to get secretproviderclass csi/azure-kvname-workload-identity, error: SecretProviderClass.secrets-store.csi.x-k8s.io "azure-kvname-workload-identity" not found
![Screenshot 2023-01-24 125022](https://user-images.githubusercontent.com/20976896/214369768-dc17accf-76fc-44df-b70d-8fcc462e3647.png)

## print a test secret 'ExampleSecret' held in secrets-store
```sh
kubectl exec busybox-secrets-store-inline -- cat /mnt/secrets-store/ExampleSecret
```


# Trying to use Cert instead of secret: Set up Secrets Store CSI Driver to enable NGINX Ingress Controller with TLS
### Generate a TLS certificate
```sh
export CERT_NAME=aks-ingress-cert
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -out aks-ingress-tls.crt \
    -keyout aks-ingress-tls.key \
    -subj "/CN=demo.azure.com/O=aks-ingress-tls"
```

### Import the certificate to AKV (steps below are under "default" namespace)
```sh
export AKV_NAME="kv20230124"
openssl pkcs12 -export -in aks-ingress-tls.crt -inkey aks-ingress-tls.key  -out $CERT_NAME.pfx 
# skip Password prompt
az keyvault certificate import --vault-name $AKV_NAME -n $CERT_NAME -f $CERT_NAME.pfx --password pw

### Deploy a SecretProviderClass
```sh
export NAMESPACE=ingress-basic
kubectl create namespace $NAMESPACE
export USER_ASSIGNED_CLIENT_ID="$(az aks show -g $resourceGroupName -n $clusterName --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv)"

# secretProviderClass.yaml
# tenantid = 0eed5976-cc28-4341-92e2-b5991a3531b2
# echo $USER_ASSIGNED_CLIENT_ID = 06abbd21-3921-4e17-b804-cf1cebd8ac63
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-tls
spec:
  provider: azure
  secretObjects:                           
  - secretName: ingress-tls-csi
    type: kubernetes.io/tls
    data: 
    - objectName: aks-ingress-cert
      key: tls.key
    - objectName: aks-ingress-cert
      key: tls.crt
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"
    userAssignedIdentityID: 06abbd21-3921-4e17-b804-cf1cebd8ac63
    keyvaultName: kv20230124              
    objects: |
      array:
        - |
          objectName: aks-ingress-cert
          objectType: secret
    tenantId: 0eed5976-cc28-4341-92e2-b5991a3531b2

```
```sh
kubectl apply -f secretProviderClass.yml -n $NAMESPACE
```

### Deploy the ingress controller, Add the official ingress chart repository
```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx/ingress-nginx --generate-name \
    --namespace $NAMESPACE \
    --set controller.replicaCount=2 \
    --set controller.nodeSelector."kubernetes\.io/os"=linux \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
    --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux
    
helm install ingress-nginx/ingress-nginx --generate-name \
    --set controller.replicaCount=2 \
    --set controller.nodeSelector."kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
    -f - <<EOF
controller:
  extraVolumes:
      - name: secrets-store-inline
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: "azure-tls"
  extraVolumeMounts:
      - name: secrets-store-inline
        mountPath: "/mnt/secrets-store"
        readOnly: true
EOF
```
