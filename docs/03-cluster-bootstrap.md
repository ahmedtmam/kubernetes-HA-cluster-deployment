# 03. Cluster Bootstrap

Order of operations: **first control-plane node, then CNI, then the other control-plane nodes, then workers.**

## 1. Initialise the first control-plane node (master1, 10.31.8.41)

Cluster settings live in [`configs/kubeadm-config.yaml`](../configs/kubeadm-config.yaml): API endpoint (the load balancer), pod CIDR, service CIDR, and the systemd cgroup driver.

```bash
sudo kubeadm init --config configs/kubeadm-config.yaml --upload-certs
```

Equivalent one-liner without a config file:

```bash
sudo kubeadm init \
  --control-plane-endpoint "10.31.8.47:6443" \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12
```

`--upload-certs` encrypts the control-plane certificates into a Secret so the other masters can fetch them when they join (the key expires after **2 hours**).

Set up kubectl for your user:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**Save the two `kubeadm join` commands** printed at the end of init (one for control planes, one for workers). Keep them in a password manager or a local file that is **not** in this repository.

## 2. Install the CNI (Calico), from master1

Nodes stay `NotReady` until a CNI is installed.

```bash
curl -fsSLO https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml

# Set the pod CIDR to match kubeadm (default in the manifest is 192.168.0.0/16)
sed -i 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|; s|#   value: "192.168.0.0/16"|  value: "10.244.0.0/16"|' calico.yaml
grep -A1 'CALICO_IPV4POOL_CIDR' calico.yaml      # confirm both lines are uncommented

kubectl apply -f calico.yaml
kubectl get pods -n kube-system -w               # wait for calico-node to be Running
kubectl get nodes -o wide                        # master1 -> Ready
```

## 3. Join master2 and master3

Tokens last 24 hours and the certificate key 2 hours. Generate fresh ones on master1 if yours have expired:

```bash
# On master1
CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs | tail -1)
sudo kubeadm token create --print-join-command --certificate-key "$CERT_KEY"
```

Run the printed command **on master2 and then master3**. Its shape is:

```bash
sudo kubeadm join 10.31.8.47:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --control-plane \
  --certificate-key <CERT_KEY>
```

Then set up kubectl on each new master (same three `mkdir/cp/chown` commands as in step 1).

Wait for each join to finish before starting the next. Etcd adds members one at a time.

## 4. Join the workers

```bash
# On master1: print a worker join command
sudo kubeadm token create --print-join-command

# On worker1, worker2, worker3:
sudo kubeadm join 10.31.8.47:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

Optionally label the workers so `kubectl get nodes` shows a role:

```bash
for n in worker1 worker2 worker3; do kubectl label node $n node-role.kubernetes.io/worker=; done
```

## 5. Verify

Run [`scripts/verify-cluster.sh`](../scripts/verify-cluster.sh), or manually:

```bash
kubectl get nodes -o wide                     # 6 nodes Ready (3 control-plane, 3 worker)
kubectl get pods -A -o wide                   # system pods Running
kubectl get --raw='/readyz?verbose'           # every check ok
kubectl get ns

# etcd membership and health, run through the etcd pod (etcd-<node-name>)
kubectl -n kube-system exec etcd-master1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint health --cluster -w table

# the same flags with `member list -w table` show the three members
```

> `kubectl get componentstatuses` is **deprecated**. Use `/readyz?verbose` instead.

### Test high availability

1. Power off **one** control-plane node (for example master1).
2. From another machine, `kubectl get nodes` must still work (served through the load balancer by master2/master3).
3. The HAProxy stats page shows the stopped backend as DOWN.
4. Create a test deployment and confirm it schedules.
5. Power the node back on and confirm it returns to `Ready` and that etcd shows 3 healthy members.

> **Never stop two control-plane nodes at once.** Etcd needs a majority (2 of 3). With two down, the API becomes read-only/unavailable.

---

Next: [04. Add-ons](04-addons.md)
