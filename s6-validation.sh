set -x
set -euo pipefail

set -o allexport; source .env; set +o allexport


SECRET_PROVIDER_CLASS="azure-tls-keys"
INGRESS_CLASS_NAME="nginx-app-1"
INGRESS_PUPLIC_IP=$(kubectl get services ingress-$INGRESS_CLASS_NAME-controller -n $SERVICE_ACCOUNT_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $INGRESS_PUPLIC_IP

# configure Ingress' Public IP with DNS Name
DNS_NAME="aks-app-05"

# az network public-ip update -g MC_rg-aks-we_aks-cluster_westeurope -n kubernetes-af54fcf50c6b24d7fbb9ed6aa62bdc77 --dns-name $DNS_NAME


kubectl get ingress --namespace $SERVICE_ACCOUNT_NAMESPACE
# NAME                         CLASS          HOSTS                                      ADDRESS   PORTS     AGE
# hello-world-ingress          nginx-app-02   aks-app-02.westeurope.cloudapp.azure.com             80, 443   12s
# hello-world-ingress-static   nginx-app-02   aks-app-02.westeurope.cloudapp.azure.com             80, 443   11s

# check tls certificate
# curl -v -k --resolve aks-app-05.eastus.cloudapp.azure.com:443:20.237.34.253 https://aks-app-05.eastus.cloudapp.azure.com
curl -v -k --resolve $DOMAIN_NAME_FQDN:443:$INGRESS_PUPLIC_IP https://$DOMAIN_NAME_FQDN
# *  issuer: O=Acme Co; CN=Kubernetes Ingress Controller Fake Certificate
# note it is not correct, nginx ingress controller is using its default fake Certificate!

# https://github.com/kubernetes/ingress-nginx/issues/2170
# issue: TLS Secret is not found as we are deploing Ingress Controller and Ingress resources into 2 different namespaces
# Ingress Controller cannot read Secrets from another namespace
# workaround: copy and paste TLS secret from Ingress Controller namespace into app namespace:
kubectl get secret tls-secret-csi-dev --namespace=$SERVICE_ACCOUNT_NAMESPACE -o yaml \
| sed '/creationTimestamp/d' \
| sed '/namespace/d' \
| sed '/resourceVersion/d' \
| sed '/labels/d' \
| sed '/secrets-store.csi.k8s.io/d' \
| sed '/ownerReferences/d' \
| sed '/- apiVersion/d' \
| sed '/kind: SecretProviderClassPodStatus/{N;d;}' \
| sed '/kind: ReplicaSet/{N;d;}' \
| sed '/uid/d' > tls-secret-csi-dev.yaml

kubectl apply -f tls-secret-csi-dev.yaml -n $NAMESPACE_APP

# check app is working with HTTPS
curl https://$DOMAIN_NAME_FQDN
curl https://$DOMAIN_NAME_FQDN/hello-world-one
curl https://$DOMAIN_NAME_FQDN/hello-world-two

# check the tls/ssl certificate
curl -v -k --resolve $DOMAIN_NAME_FQDN:443:$INGRESS_PUPLIC_IP https://$DOMAIN_NAME_FQDN