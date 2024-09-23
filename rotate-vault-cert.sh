#!/bin/bash

# (c) Copyright 2023 Cloudera, Inc. All rights reserved.
# This script renews the Vault certificate for an ECS cluster.

export APP_DOMAIN=$1
if [ -z "$APP_DOMAIN" ]; then
  echo "USAGE: $0 APP_DOMAIN"
  echo "Missing app domain. In Cloudera Manager, go to the ECS service and retrieve the value of the 'Application Domain' configuration"
  exit 1
fi

KEYTOOL=${JAVA_HOME}/bin/keytool
if ! command -v "$KEYTOOL"; then
  echo "Could not find keytool. Please export JAVA_HOME to a valid java installation and ensure JAVA_HOME/bin/keytool exists."
  exit 1
fi

set -x
set -e

ECS_HOME=/opt/cloudera/parcels/ECS
KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"

echo "Cleaning up any previous CSRs"
$KUBECTL delete csr vault-csr -n vault-system || exit_code=$?

TMPDIR=$(mktemp -d -t rotate-vault-cert.XXXXXXXX)

echo "Generating new key"
openssl genrsa -out ${TMPDIR}/vault.key 2048

echo "Generating CSR"
cat $ECS_HOME/vault/csr.conf | envsubst > ${TMPDIR}/csr.conf
openssl req -new -key ${TMPDIR}/vault.key -subj "/CN=system:node:vault.vault-system.svc;/O=system:nodes" -out ${TMPDIR}/server.csr -config ${TMPDIR}/csr.conf
cat <<EOF >${TMPDIR}/csr.yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: vault-csr
spec:
  signerName: kubernetes.io/kubelet-serving
  groups:
  - system:authenticated
  request: $(cat ${TMPDIR}/server.csr | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

echo "Signing certificate"
$KUBECTL create -f ${TMPDIR}/csr.yaml
$KUBECTL certificate approve vault-csr
# the approval is not synchronous
while [ -z $serverCert ]
do
  sleep 1
  serverCert=$($KUBECTL get csr vault-csr -o jsonpath='{.status.certificate}')
done

echo "${serverCert}" | openssl base64 -d -A -out ${TMPDIR}/vault.crt
$KUBECTL config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d > ${TMPDIR}/vault.ca

# Convert to JKS for vault-jks
$KEYTOOL -importcert -keystore ${TMPDIR}/truststore.jks -storepass changeit -file ${TMPDIR}/vault.crt -noprompt

echo "Backing up old secrets"
$KUBECTL get secret vault-server-tls -n vault-system -o yaml > ${TMPDIR}/secret_vault-server-tls.backup.yaml
$KUBECTL get secret vault -n cdp -o yaml > ${TMPDIR}/secret_vault.backup.yaml
$KUBECTL get configmap vault-jks -n cdp -o yaml > ${TMPDIR}/configmap_vault-jks.backup.yaml

echo "Replacing vault secrets"
$KUBECTL create secret generic vault-server-tls \
        --save-config \
        --dry-run=client \
        --namespace vault-system \
        --from-file=vault.key=${TMPDIR}/vault.key \
        --from-file=vault.crt=${TMPDIR}/vault.crt \
        --from-file=vault.ca=${TMPDIR}/vault.ca \
        -o yaml | $KUBECTL apply -f -

$KUBECTL create secret generic vault \
        --save-config \
        --dry-run=client \
        --namespace cdp \
        --from-file=vault.pem=${TMPDIR}/vault.crt \
        -o yaml | $KUBECTL apply -f -

$KUBECTL create configmap vault-jks \
        --save-config \
        --dry-run=client \
        --namespace cdp \
        --from-file=truststore.jks=${TMPDIR}/truststore.jks \
        -o yaml | $KUBECTL apply -f -

echo "Restarting vault"
$KUBECTL scale statefulset vault -n vault-system --replicas=0 --timeout=300s
$KUBECTL scale statefulset vault -n vault-system --replicas=1 --timeout=300s

set +x

echo "Vault TLS certificate has been sucessfully rotated"
echo
echo "To complete the process, perform the following actions:"
echo "* Restart CDP pods"
echo "* In the ECS service, run the 'Unseal Vault' action from the Actions dropdown"
echo
echo "If you are using the default self-signed ingress controller certificate, afterwards you must perform the following steps:"
echo "* Copy ${TMPDIR}/vault.crt and ${TMPDIR}/vault.key to your Cloudera Manager Server host and chown them to the cloudera-scm user"
echo "* In the configuration of the ECS service, edit the configuration 'Ingress Controller TLS/SSL Server Certificate File' to be the path to vault.crt on the CM host"
echo "* In the configuration of the ECS service, edit the configuration 'Ingress Controller TLS/SSL Server Private Key File' to be the path to vault.key on the CM host"
echo "* In the ECS service, run the 'Update Ingress Controller Certificate' action from the Actions dropdown"