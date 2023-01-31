# Use the Azure Key Vault Provider for Secrets Store CSI Driver in an AKS cluster
## References 
[Use the Azure Key Vault Provider for Secrets Store CSI Driver in an AKS cluster](https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-driver#upgrade-an-existing-aks-cluster-with-azure-key-vault-provider-for-secrets-store-csi-driver-support)

[Provide an identity to access the Azure Key Vault Provider for Secrets Store CSI Driver](https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-identity-access)

[Set up Secrets Store CSI Driver to enable NGINX Ingress Controller with TLS](https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-nginx-tls)

## Prerequisites
1. Azure Subscription 
2. Fill up all variables in sample.env file
3. Run the following command to install jq on Ubuntu.
```sh
$ sudo apt-get install jq
```

### Enable Workload Identity preview and setup Key Vault 
```sh
./s0-enablePreview-AKVpolicy.sh
```
### Import the test certificate 
```sh
./s1-importTestcert.sh
```
### Create AKS with service account and federated identity 
```sh
./s2-createAKSwithIdentity.sh
```

### Create serviceproviderclass and the pods to test cert and secret
```sh
./s3-serviceProviderClass.sh
```
Verify the secret and cert through the test pod
```sh
kubectl exec <pod name> -- ls <mnt path>
#kubectl exec busybox-secrets-store-inline-workload-identity -- ls /mnt/secrets-store/
kubectl exec <pod name>  -- cat <mnt path>/<secret/cert name>
#kubectl exec busybox-secrets-store-inline-workload-identity -- cat /mnt/secrets-store/secret1
```

### Install ingress-nginx controller with config. We use the secretproviderclass azure-tls-keys as example 
```sh
./s4-installingress-nginx.sh
```
You can verify the ingress controller status through portal or run the command 
```sh
kubectl get pods --all-namespaces 
```
![image](https://user-images.githubusercontent.com/20976896/215640332-f4fe3165-ac72-4cef-95ad-e1af539c0190.png)

### Deploy the hello-world-ingress.yaml to access test App helloworldone and  helloworldone with cert
```sh
./s5-deployTestPods.sh
```

### Generate publicIP and validate cert 
```sh
./s6-validation.sh
```
