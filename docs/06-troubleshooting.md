# 06. Troubleshooting

Work from the bottom up: **host, runtime, kubelet, control plane, network, workloads.**

## Quick triage

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide | grep -v Running
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl get --raw='/readyz?verbose'
kubectl describe node <node>          # Conditions, Taints, Allocated resources
kubectl describe pod <pod> -n <ns>    # Events at the bottom
kubectl logs <pod> -n <ns> --previous # logs of the crashed container
kubectl top nodes && kubectl top pods -A
```

## Symptom guide

| Symptom | Likely cause | Check / fix |
|---|---|---|
| Node `NotReady` right after join | CNI not installed or not ready | `kubectl get pods -n kube-system`; `ls /etc/cni/net.d`; apply Calico |
| `kubelet` crash-looping before init/join | Normal until `kubeadm init/join` | After join: `journalctl -u kubelet -f` |
| Kubelet error about cgroup driver | containerd `SystemdCgroup = false` | Set to `true`, `systemctl restart containerd kubelet` |
| Kubelet refuses to start | Swap enabled | `swapoff -a`; comment swap in `/etc/fstab` |
| `kubeadm init` preflight fails on bridge/forward | Missing modules or sysctl | `lsmod \| grep br_netfilter`; `sysctl net.ipv4.ip_forward` |
| `kubeadm join` times out | Firewall blocks 6443 to the LB, or LB backends DOWN | `nc -zv 10.31.8.47 6443`; HAProxy stats page |
| `token ... not found` / `invalid` | Join token expired (24 h) | `kubeadm token create --print-join-command` |
| Control-plane join: certificate key error | Certificate key expired (2 h) | `kubeadm init phase upload-certs --upload-certs` |
| `kubectl` hangs or `connection refused` | API unreachable or LB down | `curl -k https://10.31.8.47:6443/readyz`; `systemctl status haproxy` |
| `x509: certificate is valid for ..., not <ip/name>` | Connecting to an address not in the API cert SANs | Use the LB endpoint; add `apiServer.certSANs` in the kubeadm config |
| Pods on different nodes cannot talk | Firewall blocks Calico (179/tcp, 4789/udp, IPIP proto 4) | Open ports, or `kubectl -n kube-system logs ds/calico-node` |
| `ImagePullBackOff` | No internet/registry access, wrong name, auth | `kubectl describe pod`; `crictl pull <image>` on the node |
| `Pending` pod | No node fits (resources, taints, PVC) | `kubectl describe pod`, "Events" section |
| `CrashLoopBackOff` | App crash or bad config | `kubectl logs --previous`; check env, ConfigMaps, probes |
| Service `EXTERNAL-IP <pending>` | No MetalLB, or empty address pool | [04-addons.md](04-addons.md) |
| `kubectl top` returns "metrics not available" | Metrics Server cannot reach kubelets | Check args and TLS (see 04-addons) |
| DNS fails inside pods (Ubuntu) | `systemd-resolved` not in use | Set `resolvConf: /etc/resolv.conf` in `/var/lib/kubelet/config.yaml`, restart kubelet |
| Etcd unhealthy / API read-only | Lost quorum (2+ masters down) | Bring masters back; do not remove members blindly |

## Node-level commands

```bash
systemctl status kubelet containerd
journalctl -u kubelet --since "15 min ago" --no-pager
journalctl -u containerd --since "15 min ago" --no-pager

sudo crictl ps -a                         # all containers (control-plane static pods too)
sudo crictl logs <container-id>
sudo ss -tlnp | grep -E '6443|2379|2380|10250'
ls /etc/kubernetes/manifests              # static pod manifests
```

If `crictl` cannot find the runtime socket:

```bash
sudo crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
```

## Load balancer checks

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl status haproxy
curl -s http://127.0.0.1:8404/ | head          # stats
curl -ks https://10.31.8.41:6443/readyz        # hit each master directly: expect "ok"
```

## Control-plane health

```bash
kubectl -n kube-system get pods -l tier=control-plane -o wide
kubectl -n kube-system logs kube-apiserver-master1 --tail=50

kubectl -n kube-system exec etcd-master1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint status --cluster -w table
```

## Networking and DNS

```bash
kubectl run -it --rm dbg --image=busybox:1.36 --restart=Never -- sh
#   nslookup kubernetes.default
#   wget -qO- http://<service>.<ns>.svc.cluster.local
kubectl -n kube-system get pods -l k8s-app=kube-dns       # CoreDNS
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=30
```

## Starting over on a node

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d $HOME/.kube
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
sudo systemctl restart containerd
```

If the node was a control-plane member, remove it from the cluster first (`kubectl delete node <node>`) and confirm its etcd member is gone before re-joining.

---

Next: [07. Mapping this lab to OpenShift](07-openshift-mapping.md)
