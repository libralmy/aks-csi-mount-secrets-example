set -x
set -euo pipefail

set -o allexport; source .env; set +o allexport

export USER_ASSIGNED_CLIENT_ID="$(az identity show --resource-group "$RESOURCEGROUPNAME" --name "$UAID" --query 'clientId' -otsv)"
export KEYVAULT_URL="$(az keyvault show -g $RESOURCEGROUPNAME -n $KEYVAULT_NAME --query properties.vaultUri -o tsv)"
export IDENTITY_TENANT=$(az aks show --name $AKS_CLUSTER_NAME --resource-group $RESOURCEGROUPNAME --query identity.tenantId -o tsv)


SECRET_PROVIDER_CLASS="azure-tls-keys"

INGRESS_PUPLIC_IP=$(kubectl get services ingress-$INGRESS_CLASS_NAME-controller -n $SERVICE_ACCOUNT_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $INGRESS_PUPLIC_IP

# configure Ingress' Public IP with DNS Name
DNS_NAME="aks-app-05"
###########################################################
# Option 2: Name to associate with Azure DNS Zone

# Add an A record to your DNS zone
az network dns record-set a add-record \
    --resource-group rg-houssem-cloud-dns \
    --zone-name "houssem.cloud" \
    --record-set-name "*" \
    --ipv4-address $INGRESS_PUPLIC_IP

# az network public-ip update -g MC_rg-aks-we_aks-cluster_westeurope -n kubernetes-af54fcf50c6b24d7fbb9ed6aa62bdc77 --dns-name $DNS_NAME
DOMAIN_NAME_FQDN=$DNS_NAME.houssem.cloud
echo $DOMAIN_NAME_FQDN


cat <<EOF >hello-world-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /\$2
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: $INGRESS_CLASS_NAME # nginx
  tls:
  - hosts:
    - $DOMAIN_NAME_FQDN
    # - frontend.20.73.235.13.nip.io
    # - aks-app-01.westeurope.cloudapp.azure.com
    secretName: $TLS_SECRET
  rules:
  - host: $DOMAIN_NAME_FQDN
  # - host: aks-app-01.westeurope.cloudapp.azure.com
  # - host: frontend.20.73.235.13.nip.io
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
spec:
  ingressClassName: $INGRESS_CLASS_NAME # nginx
  tls:
  - hosts:
    - $DOMAIN_NAME_FQDN
    secretName: $TLS_SECRET
  rules:
  - host: $DOMAIN_NAME_FQDN
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