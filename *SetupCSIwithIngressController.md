# Use az command to Set up Secrets Store CSI Driver to enable NGINX Ingress Controller with TLS

```sh
export SUBSCRIPTION=<<<<your subscription id>>>>> # your subscription id
export RESOURCEGROUPNAME=csiResourceGroupSecond
export LOCATION=eastus

export KEYVAULT_NAME=kv01302023 # needs to be globally unique
export KEYVAULT_SECRET_NAME1="secret1"
export KEYVAULT_KEY_NAME1="key1"
export AKS_CLUSTER_NAME=csiAKSClusterSecond
export nodeCount=1

# environment variables for the Kubernetes Service account & federated identity credential
export SERVICE_ACCOUNT_NAMESPACE="default"
export SERVICE_ACCOUNT_NAME="workload-identity-sa"

# environment variables for the Federated Identity
# user assigned identity name
export UAID="fic-test-ua"
# federated identity name
export FICID="fic-test-fic-name"
export CERT_NAME="samplecert"

export INGRESS_CLASS_NAME="nginx-app-1"
```

### Set up Preview and resource group
```sh
az account set --subscription $SUBSCRIPTION

### --- as needed register provider -- ###
az extension add --name aks-preview
az extension update --name aks-preview
az feature register --namespace "Microsoft.ContainerService" --name "EnableWorkloadIdentityPreview"
# wait till registered
#az feature show --namespace "Microsoft.ContainerService" --name "EnableWorkloadIdentityPreview"
wait_for_output "az feature show --namespace Microsoft.ContainerService --name EnableWorkloadIdentityPreview | jq -r .properties.state" "Registered"

# when done
az provider register --namespace Microsoft.ContainerService
```

```sh
### --- create resource group --- ###
az group create --name $RESOURCEGROUPNAME --location $LOCATION

### --- create user assigned identity --- ###
az identity create --name "$UAID" --resource-group "$RESOURCEGROUPNAME" --location "$LOCATION" --subscription "$SUBSCRIPTION"
### --- assign keyvault policy to user assigned identity --- ###
export USER_ASSIGNED_CLIENT_ID="$(az identity show --resource-group "$RESOURCEGROUPNAME" --name "$UAID" --query 'clientId' -otsv)"
```

### Set up AKV
```sh
### --- create keyvault --- ###
az keyvault create --resource-group $RESOURCEGROUPNAME --name $KEYVAULT_NAME --location $LOCATION
### --- set up keyvault policy --- ###
az keyvault set-policy --name "$KEYVAULT_NAME" --secret-permissions get --spn "$USER_ASSIGNED_CLIENT_ID"
az keyvault set-policy --name "$KEYVAULT_NAME" --key-permissions get --spn "$USER_ASSIGNED_CLIENT_ID"
az keyvault set-policy --name "$KEYVAULT_NAME" --certificate-permissions get --spn "$USER_ASSIGNED_CLIENT_ID"
```

```sh
### --- create sample cert under HOSTNAME --- ###
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -out aks-ingress-tls.crt \
    -keyout aks-ingress-tls.key \
    -subj "/CN=$HOSTNAME/O=$SecretName"
   # -subj "/CN=aks-app-05.eastus.cloudapp.azure.com/O=aks-ingress-tls"

echo "hit enter to continue -- to skip password prompt"
openssl pkcs12 -export -in aks-ingress-tls.crt -inkey aks-ingress-tls.key  -out $CERT_NAME.pfx
# skip Password prompt
### --- import cert into Keyvault --- ###
az keyvault certificate import --vault-name $KEYVAULT_NAME -n $CERT_NAME -f $CERT_NAME.pfx
```
### Set up AKS
```sh
### --- create cluster --- ###
#create aks cluster -- with workload identity
az aks create -g $RESOURCEGROUPNAME \
    --name $AKS_CLUSTER_NAME \
    --location $LOCATION \
    --node-count $nodeCount \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --enable-addons azure-keyvault-secrets-provider

export AKS_OIDC_ISSUER="$(az aks show -n $AKS_CLUSTER_NAME -g $RESOURCEGROUPNAME --query "oidcIssuerProfile.issuerUrl" -otsv)"
export IDENTITY_TENANT=$(az aks show --name $AKS_CLUSTER_NAME --resource-group $RESOURCEGROUPNAME --query identity.tenantId -o tsv)

az aks get-credentials -n $AKS_CLUSTER_NAME -g "${RESOURCEGROUPNAME}"

## --- create service account --- ##
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${USER_ASSIGNED_CLIENT_ID}
  labels:
    azure.workload.identity/use: "true"
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
EOF

### --- setup federated credential linkage --- ###
# TEMP -- exists already...
az identity federated-credential create \
    --name ${FICID} \
    --identity-name ${UAID} \
    --resource-group ${RESOURCEGROUPNAME} \
    --issuer ${AKS_OIDC_ISSUER} \
    --subject system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}
```

### Create SecretProviderClass
```sh
### --- create SecretProviderClass azure-tls-keys--- ###
cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-tls-keys # needs to be unique per namespace
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
spec:
  provider: azure
  secretObjects:                            # secretObjects defines the desired state of synced K8s secret objects
  - secretName: ingress-tls-csi
    type: kubernetes.io/tls
    data: 
    - objectName: $CERT_NAME
      key: tls.key
    - objectName: $CERT_NAME
      key: tls.crt
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "false"          
    clientID: "${USER_ASSIGNED_CLIENT_ID}" # Setting this to use workload identity
    keyvaultName: ${KEYVAULT_NAME}       # Set to the name of your key vault
    cloudName: ""                         # [OPTIONAL for Azure] if not provided, the Azure environment defaults to AzurePublicCloud
    objects: |
      array:
        - |
          objectName: $CERT_NAME
          objectType: secret
    tenantId: "${IDENTITY_TENANT}"        # The tenant ID of the key vault
EOF
```
### (Optional) Create pod to test the access to AKV cert
```sh
### --- create pod that "mounts" -- WORKING --- ### 
cat <<EOF | kubectl apply -f -
# This is a sample pod definition for using SecretProviderClass and the user-assigned identity to access your key vault
kind: Pod
apiVersion: v1
metadata:
  name: quick-start-busybox-secrets-store
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: ${SERVICE_ACCOUNT_NAME}
  containers:
    - name: busybox
      image: k8s.gcr.io/e2e-test-images/busybox:1.29-1
      command:
        - "/bin/sleep"
        - "10000"
      volumeMounts:
      - name: key-store01-inline
        mountPath: "/mnt/key-store"
        readOnly: true
  volumes:
    - name: key-store01-inline
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: "azure-tls-keys"
EOF
```

### Create Nginx-Ingress Controller 
```sh
SECRET_PROVIDER_CLASS="azure-tls-keys"
# SECRET_PROVIDER_CLASS="azure-kvname-workload-identity"
INGRESS_CLASS_NAME="nginx-app-1"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx-app-1 ingress-nginx/ingress-nginx \
    --namespace default \
    --set controller.replicaCount=1 \
    --set controller.nodeSelector."kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
     --set serviceAccount.create=false \
    --set serviceAccount.name=$SERVICE_ACCOUNT_NAME \
    --set controller.enableTLSPassthrough=true \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
    -f - <<EOF
metadata:
  labels:
    azure.workload.identity/use: "true"
controller:
  ingressClassResource:                           # [OPTIONAL]
    name: $INGRESS_CLASS_NAME # default: nginx    # [OPTIONAL]
    enabled: true                                 # [OPTIONAL]
    default: false                                # [OPTIONAL]
    controllerValue: "k8s.io/ingress-$INGRESS_CLASS_NAME"  # [OPTIONAL]
  extraVolumes:
      - name: secrets-store01-inline
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: ${SECRET_PROVIDER_CLASS}
  extraVolumeMounts:
      - name: secrets-store01-inline
        mountPath: "/mnt/secrets-store"
        readOnly: true
EOF
```

### Associate with Azure Public IP address
```sh
INGRESS_PUPLIC_IP=$(kubectl get services ingress-$INGRESS_CLASS_NAME-controller -n $SERVICE_ACCOUNT_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $INGRESS_PUPLIC_IP

# configure Ingress' Public IP with DNS Name
DNS_NAME="aks-app-05"

# Get the resource-id of the public IP
AZURE_PUBLIC_IP_ID=$(az network public-ip list --query "[?ipAddress!=null]|[?contains(ipAddress, '$INGRESS_PUPLIC_IP')].[id]" -o tsv)
echo $AZURE_PUBLIC_IP_ID

# Update public IP address with DNS name
az network public-ip update --ids $AZURE_PUBLIC_IP_ID --dns-name $DNS_NAME
DOMAIN_NAME_FQDN=$(az network public-ip show --ids $AZURE_PUBLIC_IP_ID --query='dnsSettings.fqdn' -o tsv)
echo $DOMAIN_NAME_FQDN
```

### Deploy the application using an ingress controller reference
```sh
kubectl apply -f aks-helloworld-one.yaml -n $SERVICE_ACCOUNT_NAMESPACE
kubectl apply -f aks-helloworld-two.yaml -n $SERVICE_ACCOUNT_NAMESPACE
```

### Deploy an ingress resource referencing the secret

Verify the Kubernetes secret has been created:
```sh
kubectl get secret -n $NAMESPACE

#NAME                                             TYPE                                  DATA   AGE
#ingress-tls-csi                                  kubernetes.io/tls                     2      1m34s
```
```sh
TLS_SECRET="ingress-tls-csi"

cat <<EOF >hello-world-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /\$2
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
  labels:
    azure.workload.identity/use: "true"
spec:
  ingressClassName: $INGRESS_CLASS_NAME # default is nginx  [Optional]
  tls:
  - hosts:
    - $DOMAIN_NAME_FQDN
    # - aks-app-05.eastus.cloudapp.azure.com
    secretName: $TLS_SECRET
  rules:
  - host: $DOMAIN_NAME_FQDN
  # aks-app-05.eastus.cloudapp.azure.com
    http:
      paths:
      - path: /hello-world-one(/|$)(.*)
        pathType: Prefix
        backend:
          service:
            name: aks-helloworld-one
            port:
              number: 80
      - path: /hello-world-two(/|$)(.*)
        pathType: Prefix
        backend:
          service:
            name: aks-helloworld-two
            port:
              number: 80
      - path: /(.*)
        pathType: Prefix
        backend:
          service:
            name: aks-helloworld-one
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world-ingress-static
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /static/\$2
  labels:
    azure.workload.identity/use: "true"
spec:
  ingressClassName: $INGRESS_CLASS_NAME # default is nginx  [Optional]
  tls:
  - hosts:
    - $DOMAIN_NAME_FQDN #aks-app-05.eastus.cloudapp.azure.com
    secretName: $TLS_SECRET
  rules:
  - host: $DOMAIN_NAME_FQDN #aks-app-05.eastus.cloudapp.azure.com
    http:
      paths:
      - path: /static(/|$)(.*)
        pathType: Prefix
        backend:
          service:
            name: aks-helloworld-one
            port: 
              number: 80
EOF

kubectl apply -f hello-world-ingress.yaml --namespace $SERVICE_ACCOUNT_NAMESPACE
```
### Validation: Test ingress secured with TLS
```sh
kubectl get ingress --namespace $SERVICE_ACCOUNT_NAMESPACE
#NAME                         CLASS         HOSTS                                  ADDRESS         PORTS     AGE
#hello-world-ingress          nginx-app-1   aks-app-05.eastus.cloudapp.azure.com   20.237.34.253   80, 443   6h29m
#hello-world-ingress-static   nginx-app-1   aks-app-05.eastus.cloudapp.azure.com   20.237.34.253   80, 443   6h29m

# check tls certificate
# curl -v -k --resolve aks-app-05.eastus.cloudapp.azure.com:443:20.237.34.253 https://aks-app-05.eastus.cloudapp.azure.com
curl -v -k --resolve $DOMAIN_NAME_FQDN:443:$INGRESS_PUPLIC_IP https://$DOMAIN_NAME_FQDN
```
### Result
```sh
* Added aks-app-05.eastus.cloudapp.azure.com:443:20.237.34.253 to DNS cache
* Hostname aks-app-05.eastus.cloudapp.azure.com was found in DNS cache
*   Trying 20.237.34.253:443...
* TCP_NODELAY set
* Connected to aks-app-05.eastus.cloudapp.azure.com (20.237.34.253) port 443 (#0)
* ALPN, offering h2
* ALPN, offering http/1.1
* successfully set certificate verify locations:
*   CAfile: /etc/ssl/certs/ca-certificates.crt
  CApath: /etc/ssl/certs
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* TLSv1.3 (OUT), TLS change cipher, Change cipher spec (1):
* TLSv1.3 (OUT), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* ALPN, server accepted to use h2
* Server certificate:
*  subject: CN=aks-app-05.eastus.cloudapp.azure.com; O=aks-ingress-tls
*  start date: Jan 30 19:20:37 2023 GMT
*  expire date: Jan 30 19:20:37 2024 GMT
*  issuer: CN=aks-app-05.eastus.cloudapp.azure.com; O=aks-ingress-tls
*  SSL certificate verify result: self signed certificate (18), continuing anyway.
* Using HTTP2, server supports multi-use
* Connection state changed (HTTP/2 confirmed)
* Copying HTTP/2 data in stream buffer to connection buffer after upgrade: len=0
* Using Stream ID: 1 (easy handle 0x560a97b4c8c0)
> GET / HTTP/2
> Host: aks-app-05.eastus.cloudapp.azure.com
> user-agent: curl/7.68.0
> accept: */*
> 
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
* old SSL session ID is stale, removing
* Connection state changed (MAX_CONCURRENT_STREAMS == 128)!
< HTTP/2 200 
< date: Tue, 31 Jan 2023 02:35:18 GMT
< content-type: text/html; charset=utf-8
< content-length: 629
< strict-transport-security: max-age=15724800; includeSubDomains
< 
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <link rel="stylesheet" type="text/css" href="/static/default.css">
    <title>Welcome to Azure Kubernetes Service (AKS)</title>

    <script language="JavaScript">
        function send(form){
        }
    </script>

</head>
<body>
    <div id="container">
        <form id="form" name="form" action="/"" method="post"><center>
        <div id="logo">Welcome to Azure Kubernetes Service (AKS)</div>
        <div id="space"></div>
        <img src="/static/acs.png" als="acs logo">
        <div id="form">      
        </div>
    </div>     
</body>
* Connection #0 to host aks-app-05.eastus.cloudapp.azure.com left intact
```
