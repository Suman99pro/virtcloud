# ⚡ VirtCloud — 3-Node Kubernetes Virtualization Platform

> **Production-ready KVM-over-Kubernetes cluster using KubeVirt · KubeOVN · OpenEBS · kubeadm**

A fully customizable private cloud platform that runs virtual machines natively inside Kubernetes, with software-defined networking, persistent storage, and a web-based VM management console.

---

## 📋 Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Node Layout](#node-layout)
- [Quick Start](#quick-start)
- [Step-by-Step Setup](#step-by-step-setup)
- [Plugin Customization](#plugin-customization)
- [Creating Virtual Machines](#creating-virtual-machines)
- [VM Templates](#vm-templates)
- [Network Configuration](#network-configuration)
- [Storage Configuration](#storage-configuration)
- [VM Management UI](#vm-management-ui)
- [Common Operations](#common-operations)
- [Troubleshooting](#troubleshooting)
- [Project Structure](#project-structure)

---

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        VirtCloud Cluster                            │
│                                                                     │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │  control-plane   │  │    worker-01     │  │    worker-02     │  │
│  │  192.168.1.10    │  │  192.168.1.11    │  │  192.168.1.12    │  │
│  │                  │  │                  │  │                  │  │
│  │  kube-apiserver  │  │  kubelet         │  │  kubelet         │  │
│  │  etcd            │  │  KubeVirt virt-  │  │  KubeVirt virt-  │  │
│  │  scheduler       │  │  handler (KVM)   │  │  handler (KVM)   │  │
│  │  controller-mgr  │  │                  │  │                  │  │
│  │  KubeOVN ovn-    │  │  ┌────────────┐  │  │  ┌────────────┐  │  │
│  │  central         │  │  │  ubuntu-vm │  │  │  │  ubuntu-vm │  │  │
│  │                  │  │  │  rocky-vm  │  │  │  │  (QEMU/KVM)│  │  │
│  └──────────────────┘  │  └────────────┘  │  └──────────────────┘  │
│                        └──────────────────┘                        │
│                                                                     │
│  ── Networking: KubeOVN (SDN) ──────────────────────────────────── │
│     Pod CIDR: 10.244.0.0/16  │  VM Subnet: 172.20.0.0/24          │
│                                                                     │
│  ── Storage: OpenEBS ───────────────────────────────────────────── │
│     openebs-hostpath (default)  │  openebs-lvm                     │
│                                                                     │
│  ── Virtualization: KubeVirt + CDI ──────────────────────────────  │
│     VM images from cloud-images.ubuntu.com via CDI import          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## ✅ Prerequisites

### Hardware Requirements (per node)

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU      | 4 cores | 8+ cores with VT-x/AMD-V |
| RAM      | 8 GB    | 16–32 GB |
| Disk     | 100 GB  | 500 GB+ SSD |
| Network  | 1 GbE   | 10 GbE |

### Software Requirements

- **OS:** Ubuntu 24.04 LTS (all 3 nodes)
- **Kernel:** 5.15+ (Ubuntu 24.04 ships 6.8 ✓)
- **Hardware virt:** Intel VT-x or AMD-V enabled in BIOS
- **Network:** Static IPs, all nodes reachable to each other
- **Internet access** during setup (for image pulls)

### Verify Hardware Virtualization

```bash
# Check on each node
grep -c '(vmx\|svm)' /proc/cpuinfo   # Should be > 0

# If running in a VM (nested virt), check
cat /sys/module/kvm_intel/parameters/nested   # Should print 'Y'
# To enable nested virt:
# echo 'options kvm_intel nested=1' > /etc/modprobe.d/kvm.conf
```

---

## 🖥️ Node Layout

| Hostname            | IP             | Role          | Notes                    |
|---------------------|----------------|---------------|--------------------------|
| `control-plane-01`  | `192.168.1.10` | Control Plane | etcd, API server, OVN    |
| `worker-01`         | `192.168.1.11` | Worker        | Runs VMs via KubeVirt    |
| `worker-02`         | `192.168.1.12` | Worker        | Runs VMs via KubeVirt    |

> **Customize:** Adjust IPs in `scripts/01-setup-controlplane.sh` via environment variables.

---

## 🚀 Quick Start

```bash
# Clone this repository
git clone https://github.com/suman99pro/virtcloud.git
cd virtcloud

# ── On CONTROL PLANE node ──────────────────────────────────────────
sudo CONTROL_PLANE_IP=192.168.1.10 bash scripts/01-setup-controlplane.sh

# ── On EACH WORKER node ────────────────────────────────────────────
sudo bash scripts/02-setup-workers.sh
# Then run the join command printed by step 1

# ── Back on CONTROL PLANE ──────────────────────────────────────────
sudo bash scripts/03-install-cni.sh          # KubeOVN (default)
sudo bash scripts/04-install-storage.sh      # OpenEBS (default)
sudo bash scripts/05-install-kubevirt.sh     # KubeVirt + CDI

# ── Create your first VM ───────────────────────────────────────────
kubectl apply -f manifests/vms/ubuntu-vm.yaml
```

---

## 📖 Step-by-Step Setup

### Step 1 — Prepare All Nodes

Run on **every node** before starting:

```bash
# Set hostnames (replace with actual names)
hostnamectl set-hostname control-plane-01   # or worker-01, worker-02

# Edit /etc/hosts on each node
cat >> /etc/hosts <<EOF
192.168.1.10  control-plane-01
192.168.1.11  worker-01
192.168.1.12  worker-02
EOF

# Verify time sync (critical for etcd)
timedatectl set-ntp true
```

### Step 2 — Bootstrap the Control Plane

```bash
# On control-plane-01
sudo CONTROL_PLANE_IP=192.168.1.10 \
     CLUSTER_NAME=virtcloud \
     K8S_VERSION=1.30 \
     bash scripts/01-setup-controlplane.sh
```

Save the `kubeadm join` command printed at the end.

### Step 3 — Join Worker Nodes

```bash
# On worker-01 and worker-02 — first run setup:
sudo bash scripts/02-setup-workers.sh

# Then join the cluster (command from step 2):
sudo kubeadm join 192.168.1.10:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

Verify from control plane:
```bash
kubectl get nodes
# NAME                STATUS     ROLES           AGE
# control-plane-01    Ready      control-plane   5m
# worker-01           NotReady   <none>          2m   ← waiting for CNI
# worker-02           NotReady   <none>          1m
```

### Step 4 — Install CNI (Networking)

```bash
# Default: KubeOVN
sudo bash scripts/03-install-cni.sh

# Or choose another CNI:
sudo CNI_PLUGIN=flannel bash scripts/03-install-cni.sh
sudo CNI_PLUGIN=calico  bash scripts/03-install-cni.sh
sudo CNI_PLUGIN=cilium  bash scripts/03-install-cni.sh
```

Wait for all nodes to be `Ready`:
```bash
kubectl get nodes -w
```

### Step 5 — Install Storage

```bash
# Default: OpenEBS
sudo bash scripts/04-install-storage.sh

# Or choose another storage backend:
sudo STORAGE_PLUGIN=longhorn   bash scripts/04-install-storage.sh
sudo STORAGE_PLUGIN=rook-ceph  bash scripts/04-install-storage.sh
```

Verify StorageClasses:
```bash
kubectl get storageclass
# NAME                       PROVISIONER          DEFAULT
# openebs-hostpath (default) openebs.io/local     true
```

### Step 6 — Install KubeVirt

```bash
sudo bash scripts/05-install-kubevirt.sh
```

Verify:
```bash
kubectl -n kubevirt get kubevirt kubevirt
# NAME       AGE   PHASE
# kubevirt   5m    Deployed
```

### Step 7 — Apply Network Config (KubeOVN only)

```bash
kubectl apply -f manifests/kubeovn/network.yaml
```

---

## 🔌 Plugin Customization

### CNI Options

| Plugin   | Command                                    | Best For                         |
|----------|--------------------------------------------|----------------------------------|
| **KubeOVN** | `CNI_PLUGIN=kubeovn bash 03-install-cni.sh` | Advanced SDN, VM networking ✅ |
| Flannel  | `CNI_PLUGIN=flannel bash 03-install-cni.sh` | Simple, lightweight              |
| Calico   | `CNI_PLUGIN=calico bash 03-install-cni.sh`  | Network policy enforcement       |
| Cilium   | `CNI_PLUGIN=cilium bash 03-install-cni.sh`  | eBPF-based, high performance     |

> **Recommendation:** Use **KubeOVN** for VM workloads — it provides native DHCP for VMs, VPC isolation, and direct attachment of network interfaces to VMs via Multus.

### Storage Options

| Plugin       | Command                                          | Best For                   |
|--------------|--------------------------------------------------|----------------------------|
| **OpenEBS**  | `STORAGE_PLUGIN=openebs bash 04-install-storage.sh` | Default, easy setup ✅  |
| Longhorn     | `STORAGE_PLUGIN=longhorn bash 04-install-storage.sh` | Built-in replication      |
| Rook-Ceph    | `STORAGE_PLUGIN=rook-ceph bash 04-install-storage.sh`| Enterprise, high HA       |

### Kubernetes Version

```bash
# Use a specific K8s version
K8S_VERSION=1.29 bash scripts/01-setup-controlplane.sh
```

### KubeVirt Version

```bash
KUBEVIRT_VERSION=v1.1.0 bash scripts/05-install-kubevirt.sh
```

---

## 🖥️ Creating Virtual Machines

### Ubuntu 24.04 VM (main template)

1. **Edit the SSH key** in `manifests/vms/ubuntu-vm.yaml`:
   ```yaml
   ssh_authorized_keys:
     - ssh-rsa AAAA... your-actual-key-here
   ```

2. **Apply the manifest:**
   ```bash
   kubectl apply -f manifests/vms/ubuntu-vm.yaml
   ```

3. **Watch the DataVolume download progress:**
   ```bash
   kubectl get dv -n vms -w
   # NAME               PHASE       PROGRESS   RESTARTS   AGE
   # ubuntu-vm-01-boot  ImportInProgress  45%   0         2m
   ```

4. **Wait for VM to start:**
   ```bash
   kubectl get vm -n vms -w
   # NAME           AGE   STATUS    READY
   # ubuntu-vm-01   5m    Running   True
   ```

5. **SSH into the VM:**
   ```bash
   ssh ubuntu@192.168.1.11 -p 30022
   ```

6. **Or use virtctl for console access:**
   ```bash
   virtctl console ubuntu-vm-01 -n vms
   virtctl vnc ubuntu-vm-01 -n vms      # VNC
   ```

### Customize VM Resources

```bash
# Start/stop VM
virtctl start  ubuntu-vm-01 -n vms
virtctl stop   ubuntu-vm-01 -n vms
virtctl pause  ubuntu-vm-01 -n vms
virtctl resume ubuntu-vm-01 -n vms

# Live migration (requires running VM + 2+ workers)
virtctl migrate ubuntu-vm-01 -n vms

# Check VM events
kubectl describe vm ubuntu-vm-01 -n vms
kubectl describe vmi ubuntu-vm-01 -n vms   # VMInstance (running VM)
```

---

## 📦 VM Templates

All templates are in `manifests/vms/vm-templates.yaml`.

| OS             | Default CPU | Default RAM | Default Disk | Username |
|----------------|-------------|-------------|--------------|----------|
| Ubuntu 24.04   | 2           | 4 GiB       | 20 GiB       | `ubuntu` |
| Fedora 39      | 2           | 4 GiB       | 20 GiB       | `fedora` |
| Debian 12      | 2           | 2 GiB       | 20 GiB       | `debian` |
| Rocky Linux 9  | 2           | 4 GiB       | 20 GiB       | `rocky`  |
| Alpine 3.19    | 1           | 512 MiB     | 5 GiB        | `alpine` |

Deploy any template:
```bash
# First set your SSH key in the file, then:
kubectl apply -f manifests/vms/vm-templates.yaml

# Start a specific one
virtctl start fedora-vm-01  -n vms
virtctl start rocky-vm-01   -n vms
virtctl start debian-vm-01  -n vms
virtctl start alpine-vm-01  -n vms
```

### Adding a Custom OS

To add any cloud-image compatible OS:
1. Find a `.qcow2` or `.img` cloud image URL
2. Copy the Ubuntu VM manifest
3. Change the `url:` field in the DataVolume spec
4. Update the cloud-init `users[].name`

---

## 🌐 Network Configuration

### Default Network (Pod Network)

VMs use `masquerade` mode — NAT through the pod network. Works with any CNI.

### KubeOVN VM Subnet

After applying `manifests/kubeovn/network.yaml`:

```yaml
# VMs get IPs in the 172.20.0.0/24 range
# DHCP is handled by OVN
# Inter-VM communication is direct (no NAT)
```

### Static IP for a VM

```yaml
# Add annotation to the VMI template
metadata:
  annotations:
    ovn.kubernetes.io/ip_address: "172.20.0.60"
    ovn.kubernetes.io/mac_address: "00:00:00:00:00:60"
```

### Expose VM to External Network

```bash
# NodePort (already in ubuntu-vm.yaml — port 30022)
# Or use a LoadBalancer if you have MetalLB:
kubectl patch svc ubuntu-vm-01-ssh -n vms \
  -p '{"spec":{"type":"LoadBalancer"}}'
```

---

## 💾 Storage Configuration

### Default: OpenEBS Hostpath

No extra setup — volumes are stored at `/var/openebs/local` on the node.

```bash
# Check volumes
kubectl get pvc -n vms

# Check OpenEBS pods
kubectl get pods -n openebs
```

### Using LVM-backed Volumes (better performance)

```bash
# On each worker node — create a volume group
pvcreate /dev/sdb          # Your additional disk
vgcreate openebs-vg /dev/sdb

# Then use storageClassName: openebs-lvm in VM manifests
```

### Volume Expansion

```bash
kubectl patch pvc ubuntu-vm-01-boot -n vms \
  -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
```

---

## 🖥️ VM Management UI

The included web dashboard (`ui/index.html`) provides:

- **VM overview** — status, resource usage, live metrics
- **Node view** — CPU/memory utilization per node
- **One-click VM operations** — start, stop, migrate, snapshot
- **YAML generator** — export ready-to-apply manifests
- **kubectl console** — run commands from the browser
- **Network & storage views**

### ⚠️ Important: Create the `ui/` folder manually

The `ui/index.html` file is **not auto-generated** by any script — it is a standalone file delivered alongside this README. You must create the folder and place the file inside it yourself:

```bash
# In your local clone of this repo:
mkdir -p ui
# Then copy or move the downloaded index.html into ui/
cp ~/Downloads/index.html ui/index.html   # adjust path as needed

# Verify it's in place:
ls ui/
# index.html
```

> **Why?** Git does not track empty directories, and the HTML file is a pre-built static asset rather than something generated by the setup scripts.

### Deploy the UI

```bash
# 1. Create the host directory on every node (control-plane + workers)
sudo mkdir -p /opt/virtcloud-ui

# 2. Copy the HTML to every node
#    Run from your local machine or from control-plane-01:
scp ui/index.html user@192.168.1.10:/opt/virtcloud-ui/
scp ui/index.html user@192.168.1.11:/opt/virtcloud-ui/
scp ui/index.html user@192.168.1.12:/opt/virtcloud-ui/

# 3. Deploy the Kubernetes manifest
kubectl apply -f manifests/ui/virtcloud-ui.yaml

# 4. Access the dashboard at:
#    http://192.168.1.10:30080  (control-plane)
#    http://192.168.1.11:30080  (worker-01)
#    http://192.168.1.12:30080  (worker-02)
```

### For Production: Build a Docker Image

```bash
cd ui/
cat > Dockerfile <<'EOF'
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
EOF
docker build -t ghcr.io/suman99pro/virtcloud-ui:latest .
docker push ghcr.io/suman99pro/virtcloud-ui:latest

# Update the Deployment image in manifests/ui/virtcloud-ui.yaml
```

---

## ⚙️ Common Operations

### VM Lifecycle

```bash
# List all VMs across all namespaces
kubectl get vm -A

# List running VM instances
kubectl get vmi -A

# Get VM details
kubectl describe vmi ubuntu-vm-01 -n vms

# Watch VM events
kubectl get events -n vms --sort-by=.lastTimestamp

# Delete VM (keeps PVC by default)
kubectl delete vm ubuntu-vm-01 -n vms

# Delete VM AND its disk
kubectl delete vm ubuntu-vm-01 -n vms
kubectl delete pvc ubuntu-vm-01-boot -n vms
```

### Live Migration

```bash
# Migrate a VM to another node
virtctl migrate ubuntu-vm-01 -n vms

# Check migration status
kubectl get vmim -n vms   # VirtualMachineInstanceMigration
```

### Snapshots

```bash
# Take a snapshot (requires snapshot CRD — install separately)
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.kubevirt.io/v1alpha1
kind: VirtualMachineSnapshot
metadata:
  name: ubuntu-snap-01
  namespace: vms
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ubuntu-vm-01
EOF

kubectl get vmsnapshot -n vms
```

### Resize a VM

```bash
# Stop VM, edit, restart
virtctl stop ubuntu-vm-01 -n vms
kubectl patch vm ubuntu-vm-01 -n vms --type merge \
  -p '{"spec":{"template":{"spec":{"domain":{"cpu":{"cores":4},"memory":{"guest":"8Gi"}}}}}}'
virtctl start ubuntu-vm-01 -n vms
```

### Cluster Management

```bash
# Drain a node for maintenance
kubectl drain worker-01 --ignore-daemonsets --delete-emptydir-data
# VMs will live-migrate automatically

# Uncordon after maintenance
kubectl uncordon worker-01

# Get cluster info
kubectl cluster-info
kubectl top nodes
kubectl top pods -A
```

---

## 🔧 Troubleshooting

### VM stuck in `Scheduling`

```bash
kubectl describe vmi ubuntu-vm-01 -n vms
# Look for "InsufficientResources" or taint issues

# Check if KubeVirt handler is running on workers
kubectl -n kubevirt get pods -l kubevirt.io=virt-handler
```

### DataVolume stuck in `ImportInProgress`

```bash
kubectl describe dv ubuntu-vm-01-boot -n vms
# Check importer pod logs
kubectl logs -n vms -l app=containerized-data-importer
```

### `useEmulation: true` — slow VMs

If KubeVirt installed with software emulation (no KVM):
```bash
# Verify KVM is available
ls /dev/kvm   # Should exist

# Enable KVM in KubeVirt
kubectl patch kubevirt kubevirt -n kubevirt --type merge \
  -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":false}}}}'
```

### Node won't join cluster

```bash
# Reset and retry
sudo kubeadm reset
sudo rm -rf /etc/cni/net.d
sudo systemctl restart containerd

# Generate a new join command on control plane
kubeadm token create --print-join-command
```

### KubeOVN pods crashing

```bash
kubectl -n kube-system get pods -l app=ovn-central
kubectl -n kube-system logs -l app=ovs-ovn

# Restart OVN
kubectl -n kube-system rollout restart daemonset ovs-ovn
```

### Check all component health

```bash
kubectl get componentstatuses
kubectl get pods -A | grep -v Running
kubectl -n kubevirt get all
kubectl -n openebs get all
kubectl -n kube-system get all
```

---

## 📁 Project Structure

```
virtcloud/
├── scripts/
│   ├── 01-setup-controlplane.sh    # Bootstrap control plane
│   ├── 02-setup-workers.sh         # Prepare worker nodes
│   ├── 03-install-cni.sh           # Install CNI (KubeOVN/Flannel/Calico/Cilium)
│   ├── 04-install-storage.sh       # Install storage (OpenEBS/Longhorn/Rook-Ceph)
│   └── 05-install-kubevirt.sh      # Install KubeVirt + CDI + virtctl
│
├── manifests/
│   ├── vms/
│   │   ├── ubuntu-vm.yaml          # Ubuntu 24.04 VM (primary template)
│   │   └── vm-templates.yaml       # Fedora, Debian, Rocky, Alpine templates
│   ├── kubeovn/
│   │   └── network.yaml            # VPC, Subnets, NetworkAttachmentDefinitions
│   └── ui/
│       └── virtcloud-ui.yaml       # UI dashboard Kubernetes deployment
│
├── ui/
│   └── index.html                  # VM management web console
│
└── README.md
```

---

## 🔐 Security Notes

- All VMs run in the `vms` namespace with RBAC isolation
- SSH access via NodePort (port 30022) — restrict with NetworkPolicy in production
- Control plane uses kubeadm defaults — consider enabling encryption at rest for etcd
- KubeVirt VMs are isolated via QEMU/KVM — hardware-level isolation

---

## 📚 References

| Component | Documentation |
|-----------|--------------|
| KubeVirt  | https://kubevirt.io/user-guide/ |
| KubeOVN   | https://kubeovn.io/docs/ |
| OpenEBS   | https://openebs.io/docs/ |
| kubeadm   | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ |
| virtctl   | https://kubevirt.io/user-guide/user_workloads/virtctl_client_tool/ |
| CDI       | https://github.com/kubevirt/containerized-data-importer |

---

## 📄 License

MIT © [suman99pro](https://github.com/suman99pro)
