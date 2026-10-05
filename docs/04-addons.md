# 04. Add-ons

Run all `kubectl` commands from a control-plane node (or your admin workstation).

## 1. MetalLB: `Service type=LoadBalancer` on bare metal

Cloud providers give you a load balancer IP when you create a `LoadBalancer` Service. On bare metal nothing does that, so services stay `<pending>`. MetalLB fills the gap by assigning IPs from a pool you define and announcing them on your LAN (layer 2 / ARP).

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml
kubectl -n metallb-system get pods -w        # controller + speaker pods Running
```

Edit [`configs/metallb-pool.yaml`](../configs/metallb-pool.yaml) so the range is **free IPs on your LAN, outside DHCP and not used by any node**, then:

```bash
kubectl apply -f configs/metallb-pool.yaml
```

Test:

```bash
kubectl create deployment web --image=nginx
kubectl expose deployment web --port=80 --type=LoadBalancer
kubectl get svc web          # EXTERNAL-IP comes from the pool
curl http://<EXTERNAL-IP>
kubectl delete svc,deployment web
```

> If kube-proxy runs in IPVS mode, MetalLB needs `strictARP: true` in the kube-proxy ConfigMap. The kubeadm default (iptables mode) needs no change.

## 2. Ingress controller (Ingress-NGINX)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/baremetal/deploy.yaml
kubectl -n ingress-nginx get pods,svc
```

> The original notes applied two versions (v0.49.0 and v1.15.1) one after the other. Apply **only one**. Never stack manifests from different versions.

Two choices for exposing it:

| Manifest | Service type | Use when |
|---|---|---|
| `provider/baremetal/deploy.yaml` | NodePort | No MetalLB; reach it on `<node-ip>:<nodePort>` |
| `provider/cloud/deploy.yaml` | LoadBalancer | MetalLB installed; you get a real IP on ports 80/443 |

With MetalLB in place, the `cloud` manifest is usually the better fit.

> **Check project status before building on it.** The Kubernetes project announced the retirement of the community **ingress-nginx** controller (best-effort maintenance ending around March 2026). Verify its current state, and for new designs evaluate the **Gateway API** and its implementations, or a vendor-supported ingress. On OpenShift this role is played by the built-in Ingress Operator and Routes.

## 3. Metrics Server

Gives you `kubectl top nodes/pods` and is required for the Horizontal Pod Autoscaler.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

kubeadm kubelets use self-signed serving certificates, so Metrics Server cannot verify them. **Lab fix** (patch the Deployment, with no manual file editing):

```bash
kubectl -n kube-system patch deployment metrics-server --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,ExternalIP"}
]'
kubectl -n kube-system rollout status deployment metrics-server
kubectl top nodes
```

**Production fix:** enable `serverTLSBootstrap: true` in the kubelet configuration (it is present, commented out, in [`configs/kubeadm-config.yaml`](../configs/kubeadm-config.yaml)), approve the kubelet serving CSRs (`kubectl get csr`, then `kubectl certificate approve <name>`), and drop `--kubelet-insecure-tls`.

## 4. Helm

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod +x get_helm.sh && ./get_helm.sh
helm version
```

> Inspect `get_helm.sh` before running it, and pin the Helm version for repeatable builds.

## 5. Optional platforms

| Tool | Purpose |
|---|---|
| Rancher | Multi-cluster management UI, installed with Helm |
| Kubernetes Dashboard | Basic web UI |
| Portworx / Longhorn / Rook-Ceph | Persistent storage with replication and backup |

---

Next: [05. Day-2 operations](05-day2-operations.md)
