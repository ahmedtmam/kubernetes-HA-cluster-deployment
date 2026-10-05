# 07. Mapping This Lab to Red Hat OpenShift

This lab builds Kubernetes **by hand**, component by component. OpenShift packages the same architecture as an opinionated, operator-driven platform. Knowing both sides is the core of a solution architect's job: explaining what you get, what you give up, and what it costs to run either way.

## Component mapping

| This lab (upstream kubeadm) | OpenShift equivalent | Architect's talking point |
|---|---|---|
| `kubeadm init/join` | OpenShift installer (IPI, UPI, Agent-based, Assisted Installer) | Installation is automated and repeatable. Choose by infrastructure (cloud, vSphere, bare metal, disconnected). |
| 3 control-plane nodes, stacked etcd | 3 control-plane (master) nodes with etcd, managed by operators | Same quorum maths. The platform manages etcd lifecycle, certificates, and rotation. |
| Manual 1.35 to 1.36 upgrade runbook | Cluster Version Operator with update channels; OS (RHCOS) updated in the same flow | Upgrades are a platform feature, not a runbook. |
| Ubuntu / Rocky / RHEL nodes | RHCOS (immutable, managed by Machine Config Operator) or RHEL workers | Nodes are treated as cattle. Config drift is controlled centrally. |
| containerd | CRI-O | Both CRI-compliant. |
| HAProxy (+ Keepalived) in front of the API | On-prem IPI uses Keepalived + HAProxy VIPs for API and ingress; UPI needs an external LB (like this lab) | The same pattern you built here. |
| Calico CNI | OVN-Kubernetes (default), with NetworkPolicy and egress controls | Network plugin is part of the supported platform. |
| MetalLB (manual install) | MetalLB Operator | Install and lifecycle through OLM. |
| Ingress-NGINX | Ingress Operator (HAProxy-based router) and **Routes** | Routes predate Ingress and add edge, passthrough, and re-encrypt TLS options. |
| Metrics Server + manual monitoring | Built-in Prometheus, Alertmanager, Grafana-style dashboards in the console | Observability ships on day one. |
| Helm + hand-applied manifests | Helm, Operators and OLM (OperatorHub), plus GitOps (Argo CD) | Operators encode day-2 knowledge (backup, scaling, upgrade). |
| `admin.conf` shared around | OAuth, identity providers, RBAC, `kubeadmin` removable | Identity is integrated (LDAP, OIDC, and others). |
| SELinux **permissive** (lab shortcut) | SELinux **enforcing**, plus Security Context Constraints | Security defaults are strict. Workloads run non-root by default. |
| Container images pulled from the internet | Integrated registry, Quay, mirroring for **disconnected** installs | Common requirement in regulated environments. |
| Portworx / Longhorn (optional) | OpenShift Data Foundation (Ceph-based) or CSI vendors | Storage design is often the biggest architecture decision. |

## What a solution architect adds on top of the build

When a customer asks for "a Kubernetes platform", the build is maybe 20% of the work. Capture these in a design document:

1. **Requirements and constraints**: workloads, scale, compliance, RTO/RPO, connected vs disconnected.
2. **Sizing and topology**: node counts, CPU/RAM, failure domains (racks, zones), control-plane placement.
3. **Networking**: pod/service CIDRs, ingress and egress, load balancing, DNS, firewall matrix, segmentation.
4. **Storage and data protection**: block, file, object, snapshots, backup and restore, DR site.
5. **Security**: identity and RBAC, image provenance, secrets management, policy, audit, patch cadence.
6. **Observability and operations**: metrics, logs, alerts, upgrade strategy, support model.
7. **Lifecycle and cost**: subscription vs engineer time, upgrade effort, skills required.

Turning this repository's README into a short **design document** (requirements, decisions, trade-offs, risks) is the best portfolio exercise you can do.

## Suggested learning path

| Step | Focus | Notes |
|---|---|---|
| 1 | RHEL administration | RHCSA, then RHCE (Ansible automation). Check current exam codes on redhat.com/training. |
| 2 | Kubernetes fundamentals | This lab, plus CNCF **CKA** (cluster admin) and **CKAD**. |
| 3 | OpenShift administration | Red Hat OpenShift administration courses and exam (EX280 is the OpenShift administrator exam; confirm current details). |
| 4 | Hands-on OpenShift | Red Hat Developer Sandbox, OpenShift Local (single-node lab), or OKD (community upstream). |
| 5 | Architecture breadth | Red Hat Ansible Automation Platform, Advanced Cluster Management, OpenShift Virtualization, Service Mesh, and GitOps. |
| 6 | Architecture practice | Write designs, run sizing exercises, and review reference architectures. Aim toward the Red Hat Certified Architect (RHCA) path. |

> Certification names, codes, and prerequisites change. Confirm them on Red Hat's training site and the CNCF site before you plan.

## Lab ideas to extend this repository

- Repeat the build with **Ansible** (a role per document section) to practise RHCE skills.
- Add **etcd backup/restore** and a documented **DR test**.
- Replace Ingress-NGINX with a **Gateway API** implementation.
- Add **network policies** and **Pod Security Admission** labels per namespace.
- Deploy **Argo CD** and drive the add-ons from Git.
- Install **OpenShift Local** or OKD and compare the experience side by side.
