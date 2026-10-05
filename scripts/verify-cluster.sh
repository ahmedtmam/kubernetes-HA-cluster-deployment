#!/usr/bin/env bash
# Quick health report for the HA cluster. Run where kubectl is configured.
# Usage: ./scripts/verify-cluster.sh
set -uo pipefail

echo "== Nodes =="
kubectl get nodes -o wide

echo
echo "== API server readiness (through the load balancer) =="
kubectl get --raw='/readyz?verbose' | tail -n 5

echo
echo "== Pods that are not Running/Succeeded (empty = good) =="
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

echo
echo "== etcd health (all members) =="
ETCD_POD=$(kubectl -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].metadata.name}')
if [[ -n "${ETCD_POD}" ]]; then
  kubectl -n kube-system exec "${ETCD_POD}" -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
    endpoint health --cluster -w table
else
  echo "No etcd pod found."
fi

echo
echo "== Control-plane node count =="
kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l
