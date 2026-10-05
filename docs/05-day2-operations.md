# 05. Day-2 Operations

## 1. Upgrading a kubeadm HA cluster

**Rules**

- Upgrade **one minor version at a time** (1.35 to 1.36 is fine; 1.35 to 1.37 is not).
- Order: **first control-plane node, then remaining control-plane nodes, then workers, one node at a time.**
- Read the release notes, and **back up etcd first** (see section 4).
- Do not run `kubeadm upgrade apply` anywhere except the first control-plane node. All other nodes use `kubeadm upgrade node`.

Set the target (adjust to your real versions):

```bash
export NEW_MINOR=v1.37          # next minor repo
export NEW_VER=1.37.0           # exact patch version to install
```

**Pre-checks**

```bash
kubectl get nodes
kubectl get pods -A -o wide
kubectl version
```

### 1.1 Repo and kubeadm package (on EVERY node, before its turn)

**Ubuntu**

```bash
sudo apt-mark unhold kubeadm kubelet kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/deb/Release.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubeadm="${NEW_VER}-*"
sudo apt-mark hold kubeadm
```

**RHEL-family**

```bash
sudo sed -i "s#stable:/v[0-9.]*/#stable:/${NEW_MINOR}/#g" /etc/yum.repos.d/kubernetes.repo
sudo dnf install -y kubeadm-${NEW_VER} --disableexcludes=kubernetes
kubeadm version
```

### 1.2 First control-plane node (master1)

```bash
sudo kubeadm upgrade plan                  # shows available versions and checks
sudo kubeadm upgrade apply v${NEW_VER}     # ONLY on the first control-plane node

kubectl drain master1 --ignore-daemonsets   # from any admin shell
```

Upgrade kubelet and kubectl:

```bash
# Ubuntu
sudo apt-get install -y kubelet="${NEW_VER}-*" kubectl="${NEW_VER}-*" && sudo apt-mark hold kubelet kubectl
# RHEL-family
sudo dnf install -y kubelet-${NEW_VER} kubectl-${NEW_VER} --disableexcludes=kubernetes

sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon master1
kubectl get nodes                           # master1 shows the new version and Ready
```

### 1.3 Remaining control-plane nodes (master2, then master3, one at a time)

On each, after doing step 1.1 (repo and kubeadm package):

```bash
sudo kubeadm upgrade node                   # NOT "upgrade apply"
kubectl drain <node> --ignore-daemonsets    # from any admin shell
# upgrade kubelet + kubectl packages (as in 1.2), then:
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon <node>
```

Wait for `kubectl get nodes` to show the node `Ready` at the new version before moving to the next one.

### 1.4 Workers (worker1, worker2, worker3, one at a time)

```bash
# On the worker: repo + kubeadm package (step 1.1)
# From a control-plane node:
kubectl drain <worker> --ignore-daemonsets --delete-emptydir-data

# On the worker:
sudo kubeadm upgrade node
# upgrade kubelet package (as in 1.2), then:
sudo systemctl daemon-reload && sudo systemctl restart kubelet

# From a control-plane node:
kubectl uncordon <worker>
```

> Drain first, then upgrade. The original notes ran `kubeadm upgrade node` before the drain. Draining first is the order the upstream docs use and keeps workloads off a node that is about to change.

After the last node: upgrade the CNI (Calico) if its release notes require it for the new Kubernetes version, and re-run `scripts/verify-cluster.sh`.

---

## 2. Adding and removing nodes

**Add a worker**

```bash
# on a control-plane node
sudo kubeadm token create --print-join-command
# run the printed command on the new node (after doc 01 preparation)
```

**Remove a worker**

```bash
# on a control-plane node
kubectl drain <node> --delete-emptydir-data --ignore-daemonsets
kubectl delete node <node>

# on the node being removed
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
```

**Removing a control-plane node** also requires removing its etcd member. `kubeadm reset` on that node does this automatically while the cluster is healthy. Always keep an **odd** number of members and never drop below 3 in production.

---

## 3. Safe shutdown and startup of the whole cluster

**Shutdown: workers first, then control plane, then load balancer**

```bash
kubectl get nodes && kubectl get --raw='/readyz?verbose'      # confirm healthy first

# for each worker
kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data
# then on the worker: sudo shutdown -h now        (repeat for worker2, worker3)

# control plane, one at a time: master3, master2, master1
# then on the node: sudo shutdown -h now
# finally the load balancer VM
```

**Startup: load balancer first, then control plane, then workers**

1. Start the **load balancer**.
2. Start **master1, master2, master3** and wait until `kubectl get nodes` responds. Etcd needs a majority (2 of 3) before the API serves requests.
3. Start **worker1 to worker3**.
4. **Uncordon** each worker that was drained:
   ```bash
   kubectl uncordon worker1 worker2 worker3
   ```
5. Verify: `kubectl get nodes`, `kubectl get pods -A`, `kubectl get --raw='/readyz?verbose'`.

> Differences from the original notes: the load balancer starts first (kubelets and clients reach the API through it), all masters start together so etcd reaches quorum quickly, and drained workers are explicitly uncordoned. Otherwise they stay `SchedulingDisabled`.

---

## 4. etcd backup and certificate health

Take a snapshot **before every upgrade** and on a schedule. Run on a control-plane node:

```bash
sudo mkdir -p /var/backups/etcd
sudo ETCDCTL_API=3 etcdctl snapshot save /var/backups/etcd/etcd-$(date +%F-%H%M).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

(`etcdctl` is not installed by default. Install it from your distro/etcd release, or run the snapshot through the etcd pod.) **Copy snapshots off the node.** A backup on the same disk is not a backup.

Check control-plane certificate expiry (kubeadm certificates last one year and are renewed automatically on each `kubeadm upgrade`):

```bash
sudo kubeadm certs check-expiration
sudo kubeadm certs renew all        # then restart the control-plane static pods
```

---

## 5. Managing multiple clusters from one workstation

Install kubectl on an admin VM:

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

Copy each cluster's kubeconfig:

```bash
mkdir -p ~/.kube
scp root@master-dev:/etc/kubernetes/admin.conf  ~/.kube/cluster-dev.yaml
scp root@master-test:/etc/kubernetes/admin.conf ~/.kube/cluster-test.yaml
```

**Before merging, edit each file** so the names are unique. Every kubeadm cluster uses `kubernetes`, `kubernetes-admin`, and `kubernetes-admin@kubernetes`, so merging without renaming makes them collide. In each file, change:

- `clusters[].name` to `cluster-dev` (and `cluster-test`)
- `contexts[].name`, `contexts[].context.cluster`, `contexts[].context.user` to match
- `users[].name` to `admin-dev` (and `admin-test`)
- `clusters[].cluster.server` to that cluster's **load balancer address**, not a single master IP

Merge and use:

```bash
export KUBECONFIG=~/.kube/cluster-dev.yaml:~/.kube/cluster-test.yaml
kubectl config view --flatten > ~/.kube/config && chmod 600 ~/.kube/config
unset KUBECONFIG

kubectl config get-contexts           # list contexts
kubectl config use-context cluster-dev
kubectl config current-context
```

> `admin.conf` is cluster-admin. Delete the per-cluster copies after merging, protect `~/.kube/config` (mode 600), and prefer per-user certificates or OIDC for team access.

---

Next: [06. Troubleshooting](06-troubleshooting.md)
