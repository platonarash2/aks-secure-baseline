#!/usr/bin/env bash

# Stop exection if command fails
set -e

SCRIPT_PATH=$PWD

# Cluster Parameters. Some NEEDS to be updated manually.
LOCATION='canadacentral'
RGNAMECLUSTER='tobbenew7'
RGNAMESPOKES='tobbenew7'
TENANT_ID='72f988bf-86f1-41af-91ab-2d7cd011db47'
MAIN_SUBSCRIPTION='e9aac0f0-83bd-43cf-ab35-c8e3eccc8932'
AKS_DEPLOYMENT_NAME='cluster-stamp-20210315-160728-8245'  


AKS_CLUSTER_NAME=$(az deployment group show -g $RGNAMECLUSTER -n $AKS_DEPLOYMENT_NAME --query properties.outputs.aksClusterName.value -o tsv)
TRAEFIK_USER_ASSIGNED_IDENTITY_RESOURCE_ID=$(az deployment group show -g $RGNAMECLUSTER -n $AKS_DEPLOYMENT_NAME --query properties.outputs.aksIngressControllerPodManagedIdentityResourceId.value -o tsv)
TRAEFIK_USER_ASSIGNED_IDENTITY_CLIENT_ID=$(az deployment group show -g $RGNAMECLUSTER -n $AKS_DEPLOYMENT_NAME --query properties.outputs.aksIngressControllerPodManagedIdentityClientId.value -o tsv)
KEYVAULT_NAME=$(az deployment group show -g $RGNAMECLUSTER -n $AKS_DEPLOYMENT_NAME --query properties.outputs.keyVaultName.value -o tsv)
APPGW_PUBLIC_IP=$(az deployment group show -g $RGNAMESPOKES -n $AKS_DEPLOYMENT_NAME --query properties.outputs.appGwPublicIpAddress.value -o tsv)


az account set -s $MAIN_SUBSCRIPTION

# App Gateway Certificate
#openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
#        -out appgw.crt \
#        -keyout appgw.key \
#        -subj "/CN=tobbetobbepro.com/O=Tobbe Pro"
#openssl pkcs12 -export -out appgw.pfx -in appgw.crt -inkey appgw.key -passout pass:
#APP_GATEWAY_LISTENER_CERTIFICATE=$(cat appgw.pfx | base64 | tr -d '\n')

# AKS Ingress Controller Certificate
#openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
#        -out traefik-ingress-internal-aks-ingress-contoso-com-tls.crt \
#        -keyout traefik-ingress-internal-aks-ingress-contoso-com-tls.key \
#        -subj "/CN=*.aks-ingress.contoso.com/O=Contoso Aks Ingress"
#AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64=$(cat traefik-ingress-internal-aks-ingress-contoso-com-tls.crt | base64 | tr -d '\

#From manual instructions, as reference, with changed URL
#openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
#         -out traefik-ingress-internal-aks-ingress-contoso-com-tls.crt \
#         -keyout traefik-ingress-internal-aks-ingress-contoso-com-tls.key \
#         -subj "/CN=*.aks-ingress.tobbetobbepro.com/O=Contoso Aks Ingress"

# allow cert import for current user
az keyvault set-policy --certificate-permissions import get -n $KEYVAULT_NAME --upn $(az account show --query user.name -o tsv)

# Use created cert files to "create" ingress cert
cat traefik-ingress-internal-aks-ingress-contoso-com-tls.crt traefik-ingress-internal-aks-ingress-contoso-com-tls.key > traefik-ingress-internal-aks-ingress-contoso-com-tls.pem
az keyvault certificate import --vault-name $KEYVAULT_NAME -f traefik-ingress-internal-aks-ingress-contoso-com-tls.pem -n traefik-ingress-internal-aks-ingress-contoso-com-tls

# attach to AKS cluster and create namespace for traefik
az aks get-credentials -n ${AKS_CLUSTER_NAME} -g ${RGNAMECLUSTER} --admin

# Create namespaces
kubectl apply -f $SCRIPT_PATH/cluster-manifests/cluster-baseline-settings/ns-cluster-baseline-settings.yaml
kubectl apply -f $SCRIPT_PATH/cluster-manifests/cluster-baseline-settings/ns-traefik.yaml
kubectl apply -f $SCRIPT_PATH/cluster-manifests/cluster-baseline-settings/ns-app.yaml

# Apply manifests for "pod identity" and "csi" - TODO - split pod-identity.yaml into two, to avoid race condition
kubectl apply -f $SCRIPT_PATH/cluster-manifests/cluster-baseline-settings/rbac.yaml
kubectl apply -f $SCRIPT_PATH/cluster-manifests/cluster-baseline-settings/kured.yaml
kubectl apply -f $SCRIPT_PATH/cluster-manifests/cluster-baseline-settings/aad-pod-identity.yaml

sleep 5 # TODO: wait for resource AzurePodIdentityException has been created

kubectl apply -f $SCRIPT_PATH/cluster-manifests/cluster-baseline-settings/aad-pod-identity-2.yaml
kubectl apply -f $SCRIPT_PATH/cluster-manifests/cluster-baseline-settings/akv-secrets-store-csi.yaml

# Create pod-identity resources in AKS cluster
cat <<EOF | kubectl apply -f -
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentity
metadata:
  name: podmi-ingress-controller-identity
  namespace: a0008
spec:
  type: 0
  resourceID: $TRAEFIK_USER_ASSIGNED_IDENTITY_RESOURCE_ID
  clientID: $TRAEFIK_USER_ASSIGNED_IDENTITY_CLIENT_ID
---
apiVersion: aadpodidentity.k8s.io/v1
kind: AzureIdentityBinding
metadata:
  name: podmi-ingress-controller-binding
  namespace: a0008
spec:
  azureIdentity: podmi-ingress-controller-identity
  selector: podmi-ingress-controller
EOF

cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
kind: SecretProviderClass
metadata:
  name: aks-ingress-contoso-com-tls-secret-csi-akv
  namespace: a0008
spec:
  provider: azure
  parameters:
    usePodIdentity: "true"
    keyvaultName: "${KEYVAULT_NAME}"
    objects:  |
      array:
        - |
          objectName: traefik-ingress-internal-aks-ingress-contoso-com-tls
          objectAlias: tls.crt
          objectType: cert
        - |
          objectName: traefik-ingress-internal-aks-ingress-contoso-com-tls
          objectAlias: tls.key
          objectType: secret
    tenantId: "${TENANT_ID}"
EOF

# Start traefik (using fixed internal IP, which is known by AppGW)
kubectl apply -f $SCRIPT_PATH/workload/traefik.yaml

# Optionally, set up an example workload
kubectl apply -f $SCRIPT_PATH/workload/aspnetapp.yaml

echo 'the ASPNET Core webapp sample is all setup. Wait until is ready to process requests running'
kubectl wait --namespace app \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=aspnetapp \
  --timeout=90s
echo 'you must see the EXTERNAL-IP 10.240.4.4, please wait till it is ready. It takes a some minutes, then cntr+c'
kubectl get svc -n a0008 --watch 

