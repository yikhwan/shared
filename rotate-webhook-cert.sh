#!/bin/bash

# (c) Copyright 2023 Cloudera, Inc. All rights reserved.
# This script renews the ECS tolerations webhook certificate for an ECS cluster.

export NAMESPACE=ecs-webhooks
export SERVICE=ecs-tolerations-webhook

export APP_DOMAIN=$1
if [ -z "$APP_DOMAIN" ]; then
  echo "USAGE: $0 APP_DOMAIN"
  echo "Missing app domain. In Cloudera Manager, go to the ECS service and retrieve the value of the 'Application Domain' configuration"
  exit 1
fi


set -x
set -e

ECS_HOME=/opt/cloudera/parcels/ECS
KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"

echo "Cleaning up any previous CSRs"
$KUBECTL delete csr ecs-tolerations-webhook-csr || exit_code=$?

TMPDIR=$(mktemp -d -t rotate-webhook-cert.XXXXXXXX)

echo "Generating new key"
openssl genrsa -out ${TMPDIR}/ecs-tolerations-webhook.key 2048

echo "Generating CSR"
cat $ECS_HOME/ecs-tolerations-webhook/csr.conf | envsubst > ${TMPDIR}/csr.conf
openssl req -new -key ${TMPDIR}/ecs-tolerations-webhook.key -subj "/CN=system:node:ecs-tolerations-webhook.ecs-webhooks.svc;/O=system:nodes" -out ${TMPDIR}/server.csr -config ${TMPDIR}/csr.conf
cat <<EOF >${TMPDIR}/csr.yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ecs-tolerations-webhook-csr
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

echo "Signing certificates"
$KUBECTL create -f ${TMPDIR}/csr.yaml
$KUBECTL certificate approve ecs-tolerations-webhook-csr
# the approval is not synchronous
while [ -z $serverCert ]
do
  sleep 1
  serverCert=$($KUBECTL get csr ecs-tolerations-webhook-csr -o jsonpath='{.status.certificate}')
done

echo "${serverCert}" | openssl base64 -d -A -out ${TMPDIR}/ecs-tolerations-webhook.crt
$KUBECTL get configmap -n $NAMESPACE kube-root-ca.crt -o=jsonpath='{.data.ca\.crt}' > ${TMPDIR}/ecs-tolerations-webhook.ca

echo "Backing up old objects"
$KUBECTL get secret ecs-tolerations-webhook-tls -n $NAMESPACE -o yaml > ${TMPDIR}/secret_ecs-tolerations-webhook-tls.backup.yaml
$KUBECTL get deployment ecs-tolerations-webhook -n $NAMESPACE -o yaml > ${TMPDIR}/deployment_ecs-tolerations-webhook.backup.yaml
$KUBECTL get mutatingwebhookconfiguration ecs-tolerations-webhook-configuration -o yaml > ${TMPDIR}/mutatingwebhookconfiguration_ecs-tolerations-webhook-configuration.backup.yaml

echo "Replacing webhook secret"
$KUBECTL create secret generic ecs-tolerations-webhook-tls \
        --save-config \
        --dry-run=client \
        --namespace $NAMESPACE \
        --from-file=tls.key=${TMPDIR}/ecs-tolerations-webhook.key \
        --from-file=tls.crt=${TMPDIR}/ecs-tolerations-webhook.crt \
        -o yaml | $KUBECTL apply -f -

echo "Replacing webhook configuartion"
export CA_PEM_B64=$(cat ${TMPDIR}/ecs-tolerations-webhook.ca | base64 | tr -d '\n')
cat $ECS_HOME/ecs-tolerations-webhook/ecs-tolerations-webhook.yaml | envsubst > ${TMPDIR}/ecs-tolerations-webhook.yaml
$KUBECTL apply -f ${TMPDIR}/ecs-tolerations-webhook.yaml

echo "Restarting webhook"
$KUBECTL scale deployment ecs-tolerations-webhook -n $NAMESPACE --replicas=0 --timeout=300s
$KUBECTL scale deployment ecs-tolerations-webhook -n $NAMESPACE --replicas=2 --timeout=300s