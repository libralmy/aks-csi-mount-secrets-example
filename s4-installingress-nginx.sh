set -x
set -euo pipefail

set -o allexport; source .env; set +o allexport

export USER_ASSIGNED_CLIENT_ID="$(az identity show --resource-group "$RESOURCEGROUPNAME" --name "$UAID" --query 'clientId' -otsv)"
export KEYVAULT_URL="$(az keyvault show -g $RESOURCEGROUPNAME -n $KEYVAULT_NAME --query properties.vaultUri -o tsv)"
export IDENTITY_TENANT=$(az aks show --name $AKS_CLUSTER_NAME --resource-group $RESOURCEGROUPNAME --query identity.tenantId -o tsv)



# kubectl apply -f aks-helloworld-one.yaml --namespace ${SERVICE_ACCOUNT_NAMESPACE}
# # deployment.apps/aks-helloworld-one created
# # service/aks-helloworld-one created

# kubectl apply -f aks-helloworld-two.yaml --namespace ${SERVICE_ACCOUNT_NAMESPACE}
# # deployment.apps/aks-helloworld-two created
# # service/aks-helloworld-two created
kubectl apply -f aks-helloworld-one.yaml --namespace $SERVICE_ACCOUNT_NAMESPACE

kubectl apply -f aks-helloworld-two.yaml --namespace $SERVICE_ACCOUNT_NAMESPACE

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
  ingressClassResource:
    name: $INGRESS_CLASS_NAME # default: nginx
    enabled: true
    default: false
    controllerValue: "k8s.io/ingress-$INGRESS_CLASS_NAME"
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

# helm upgrade --install ingress-nginx-app-5 ingress-nginx/ingress-nginx \
#      --namespace $SERVICE_ACCOUNT_NAMESPACE \
#      --set controller.replicaCount=1 \
#      --set controller.nodeSelector."kubernetes\.io/os"=linux \
#      --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
#      --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
#      -f - <<EOF
# controller:
#   admissionWebhooks:
#     enabled: true
#     timeoutSeconds: 45
# #   ingressClassResource:
# #     name: $INGRESS_CLASS_NAME 
# #     enabled: true
# #     default: false
# #     controllerValue: "k8s.io/ingress-$INGRESS_CLASS_NAME"
#   extraVolumes:
#       - name: secrets-store01-inline
#         csi:
#           driver: secrets-store.csi.k8s.io
#           readOnly: true
#           volumeAttributes:
#             secretProviderClass: $SECRET_PROVIDER_CLASS
#   extraVolumeMounts:
#       - name: secrets-store01-inline
#         mountPath: "/mnt/secrets-store"
#         readOnly: true
#  #serviceAccount:
#  #  annotations:
#  #    "azure.workload.identity/client-id": $USER_ASSIGNED_CLIENT_ID
#  #  labels:
#   #   azure.workload.identity/use: "true"
#  #  name: workload-identity-sa
# EOF

