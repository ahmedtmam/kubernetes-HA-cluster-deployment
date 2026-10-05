# 01. OS Preparation (ALL NODES)

Run these steps on **every** node (masters, workers, and, where noted, the load balancer). Commands are shown for **RHEL-family** (RHEL / Rocky / Alma 9) and **Ubuntu**.

> **Shortcut:** [`scripts/prepare-node.sh`](../scripts/prepare-node.sh) automates steps 1 to 4 (hosts, swap, SELinux, kernel modules, sysctl). Run it as root, then continue from step 5.

## Prerequisites

| Requirement | Minimum (lab) | Recommended |
|---|---|---|
| Control plane node | 2 vCPU, 2 GB RAM | 4 vCPU, 8 GB RAM |
| Worker node | 2 vCPU, 2 GB RAM | sized to workload |
| Network | All nodes reach each other | Static IPs on one subnet |
| Uniqueness | Unique hostname, MAC, `product_uuid` per node | |
| Time | Synchronised (chrony) | |

Check uniqueness and time sync:

```bash
cat /sys/class/dmi/id/product_uuid
ip link show | grep ether
timedatectl            # "System clock synchronized: yes"
```

## 1. Hostnames and /etc/hosts

Kubernetes uses the hostname as the node name, so it must be **lowercase** and unique.

```bash
sudo hostnamectl set-hostname master1     # change per node
```

Add all nodes to `/etc/hosts` on every machine (or use DNS). Contents are in [`configs/hosts.example`](../configs/hosts.example):

```bash
cat <<EOF | sudo tee -a /etc/hosts
10.31.8.41 master1 k8s-master-01
10.31.8.42 master2 k8s-master-02
10.31.8.43 master3 k8s-master-03
10.31.8.44 worker1 k8s-worker-01
10.31.8.45 worker2 k8s-worker-02
10.31.8.46 worker3 k8s-worker-03
10.31.8.47 loadbalancer k8s-ha-loadbalancer
EOF
```

## 2. Disable swap and set SELinux

The kubelet will not start with swap enabled (default behaviour).

```bash
sudo swapoff -a
sudo sed -i '/\sswap\s/ s/^\([^#]\)/#\1/' /etc/fstab     # comment out swap, survives reboot
```

**RHEL-family only:**

```bash
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
```

> **Lab shortcut:** permissive SELinux is what the upstream kubeadm docs describe. Red Hat's own platform, OpenShift, runs with SELinux **enforcing**, so if you are heading that way, treat permissive as a stepping stone and see [07-openshift-mapping.md](07-openshift-mapping.md).

## 3. Kernel modules

```bash
sudo modprobe overlay && sudo modprobe br_netfilter       # now (runtime)

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf         # persistent
overlay
br_netfilter
EOF
```

## 4. Sysctl for bridged traffic and forwarding

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

## 5. Firewall

Pick **one** approach.

### Option A (recommended): keep the firewall on and open only what is needed

> The original notes disabled firewalld and then added rules to it. Those two instructions contradict each other, so choose one approach.

**Control-plane nodes**

| Port | Proto | Purpose |
|---|---|---|
| 6443 | TCP | Kubernetes API server |
| 2379-2380 | TCP | etcd client / peer |
| 10250 | TCP | kubelet API |
| 10257 | TCP | kube-controller-manager |
| 10259 | TCP | kube-scheduler |
| 179 | TCP | Calico BGP (default IPIP/BGP mode) |
| 4789 | UDP | Calico VXLAN (only if you use VXLAN) |
| IP protocol 4 | n/a | Calico IPIP encapsulation (default mode) |

**Worker nodes**

| Port | Proto | Purpose |
|---|---|---|
| 10250 | TCP | kubelet API |
| 10256 | TCP | kube-proxy health check |
| 30000-32767 | TCP | NodePort services |
| 179 / 4789 / proto 4 | | Calico, same as above |

> Ports 10251 and 10252 appear in older guides. They belonged to the legacy insecure scheduler / controller-manager endpoints and are replaced by 10259 and 10257.

**RHEL-family (firewalld):**

```bash
# Control plane
sudo firewall-cmd --permanent --add-port={6443,2379-2380,10250,10257,10259,179}/tcp
sudo firewall-cmd --permanent --add-port=4789/udp
sudo firewall-cmd --permanent --add-rich-rule='rule protocol value="4" accept'   # IPIP
sudo firewall-cmd --reload

# Workers
sudo firewall-cmd --permanent --add-port={10250,10256,179,30000-32767}/tcp
sudo firewall-cmd --permanent --add-port=4789/udp
sudo firewall-cmd --permanent --add-rich-rule='rule protocol value="4" accept'
sudo firewall-cmd --reload
```

**Ubuntu (ufw):**

```bash
# Control plane
for p in 6443 2379:2380 10250 10257 10259 179; do sudo ufw allow ${p}/tcp; done
sudo ufw allow 4789/udp
# Workers
for p in 10250 10256 179 30000:32767; do sudo ufw allow ${p}/tcp; done
sudo ufw allow 4789/udp
sudo ufw allow from 10.31.8.0/24      # simplest way to also allow IPIP between nodes
sudo ufw reload
```

**Simplest for an isolated lab:** trust the node subnet entirely (this opens everything between nodes):

```bash
sudo firewall-cmd --permanent --zone=trusted --add-source=10.31.8.0/24 && sudo firewall-cmd --reload
```

### Option B (lab only): disable the host firewall

```bash
sudo systemctl disable --now firewalld     # RHEL-family
sudo ufw disable                           # Ubuntu
```

## 6. Install containerd (ALL NODES except the load balancer)

**RHEL-family**

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y containerd.io          # package name in the Docker repo is containerd.io
```

**Ubuntu**

```bash
sudo apt-get update && sudo apt-get install -y containerd
```

**Both: generate the config and switch to the systemd cgroup driver** (the kubelet and the runtime must agree, and a mismatch causes unstable pods):

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable containerd && sudo systemctl restart containerd
systemctl is-active containerd
```

## 7. Install kubeadm, kubelet, kubectl (ALL kubernetes nodes)

Set the minor version once, then use it in the repo definition:

```bash
export K8S_MINOR=v1.36
```

**RHEL-family**

```bash
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
sudo systemctl enable --now kubelet
```

**Ubuntu**

```bash
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl      # prevent accidental upgrades
sudo systemctl enable --now kubelet
```

> The kubelet will restart in a crash loop until `kubeadm init` or `kubeadm join` runs. That is expected.

**Ubuntu note:** if your system does not use `systemd-resolved`, set the kubelet resolver path in `/var/lib/kubelet/config.yaml` (after init/join) to `resolvConf: /etc/resolv.conf`, then `sudo systemctl restart kubelet`.

## 8. kubectl convenience (optional)

```bash
sudo tee /etc/bash_completion.d/kubernetes > /dev/null <<'EOF'
source <(kubectl completion bash)
source <(kubeadm completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
EOF
source /etc/bash_completion.d/kubernetes
```

---

Next: [02. Load balancer](02-load-balancer.md)
