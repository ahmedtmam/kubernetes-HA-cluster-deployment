# 02. Load Balancer (HAProxy)

The load balancer gives the cluster **one stable API endpoint** (`10.31.8.47:6443`) that fronts all three kube-apiservers. It must exist **before** `kubeadm init`, because the endpoint is baked into every certificate and kubeconfig.

Do this on the `loadbalancer` VM (10.31.8.47).

## 1. Install

**Ubuntu**

```bash
sudo apt-get update && sudo apt-get install -y haproxy
```

**RHEL-family**

```bash
sudo dnf install -y haproxy
```

(Install `keepalived` as well only if you are building the HA pair in the last section.)

## 2. Configure

Use [`configs/haproxy.cfg`](../configs/haproxy.cfg):

```bash
sudo cp configs/haproxy.cfg /etc/haproxy/haproxy.cfg
sudo haproxy -c -f /etc/haproxy/haproxy.cfg      # syntax check
sudo systemctl enable --now haproxy
sudo systemctl restart haproxy
```

Design choices in that file:

| Setting | Why |
|---|---|
| `mode tcp` | TLS is passed straight through to the API servers, with no certificate handling on the LB. |
| `option httpchk GET /readyz` + `check-ssl` | Health check hits the API server's real readiness endpoint, not just "is the port open". |
| `fall 3 rise 2` | Three failed checks remove a backend, two good ones add it back. |
| `timeout client/server 1h` | Long-lived connections (`kubectl logs -f`, `exec`, `watch`) break if timeouts are short. |
| Stats on `127.0.0.1:8404` | Keeps the stats page off the network. Use an SSH tunnel to view it. |

> Until `kubeadm init` has run, all three backends will show **DOWN**. That is expected.

## 3. Firewall and SELinux on the load balancer

```bash
# RHEL-family
sudo firewall-cmd --permanent --add-port=6443/tcp && sudo firewall-cmd --reload
# Ubuntu
sudo ufw allow 6443/tcp
```

If SELinux is enforcing and HAProxy cannot connect to the backends:

```bash
sudo setsebool -P haproxy_connect_any 1
```

## 4. Verify

```bash
sudo ss -tlnp | grep 6443                 # haproxy listening
nc -zv 10.31.8.47 6443                    # from another node
curl -s http://127.0.0.1:8404/            # stats (on the LB itself)
```

---

## Removing the single point of failure (recommended for production)

A single HAProxy VM means a failed load balancer takes the API down, even though three control-plane nodes are healthy. Fix it with **two load balancers sharing a virtual IP (VIP)** using Keepalived (VRRP).

```
                 VIP 10.31.8.50 (floats)
                  /                \
   loadbalancer1 10.31.8.47    loadbalancer2 10.31.8.48
   (MASTER, prio 101)          (BACKUP, prio 100)
   haproxy + keepalived        haproxy + keepalived
```

1. Build a second LB VM with the same `haproxy.cfg`.
2. Install `keepalived` on both and use [`configs/keepalived.conf`](../configs/keepalived.conf) (change `state`, `priority`, `interface`, and the VIP per node).
3. Allow VRRP between the LBs: `sudo firewall-cmd --permanent --add-protocol=vrrp && sudo firewall-cmd --reload`.
4. Allow HAProxy to bind the VIP on the backup node:
   ```bash
   echo 'net.ipv4.ip_nonlocal_bind = 1' | sudo tee /etc/sysctl.d/haproxy.conf && sudo sysctl --system
   ```
5. Use the **VIP (or a DNS name pointing at it)** as `controlPlaneEndpoint` in `kubeadm-config.yaml`.

> **Plan this before bootstrapping.** Changing `controlPlaneEndpoint` on a running cluster is painful because it is embedded in certificates and kubeconfigs. If you might add the second LB later, point the cluster at a DNS name (for example `k8s-api.lab.local`) from day one.

---

Next: [03. Cluster bootstrap](03-cluster-bootstrap.md)
