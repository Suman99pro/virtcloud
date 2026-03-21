# ⚡ VirtCloud — 3-Node Kubernetes Virtualization Platform

> **KVM-over-Kubernetes using KubeVirt · KubeOVN · OpenEBS · kubeadm on Ubuntu 24.04**

---

## 📋 Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Node Layout](#node-layout)
- [Quick Start](#quick-start)
- [Step-by-Step Setup](#step-by-step-setup)
- [Plugin Customization](#plugin-customization)
- [Creating Virtual Machines](#creating-virtual-machines)
- [VM Templates](#vm-templates)
- [VM Management UI](#vm-management-ui)
- [Network Configuration](#network-configuration)
- [Storage Configuration](#storage-configuration)
- [Common Operations](#common-operations)
- [Troubleshooting](#troubleshooting)
- [Project Structure](#project-structure)

---

## 🏗️ Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                       VirtCloud Cluster                          │
│                                                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │ control-plane   │  │   worker-01     │  │   worker-02     │  │
│  │ 192.168.1.10    │  │ 192.168.1.11    │  │ 192.168.1.12    │  │
│  │                 │  │                 │  │                 │  │
│  │ kube-apiserver  │  │ kubelet         │  │ kubelet         │  │
│  │ etcd            │  │ virt-handler    │  │ virt-handler    │  │
│  │ scheduler       │  │ (KVM)           │  │ (KVM)           │  │
│  │ KubeOVN central │  │ ┌───────────┐  │  │ ┌───────────┐  │  │
│  │                 │  │ │ubuntu-vm  │  │  │ │ubuntu-vm  │  │  │
│  └─────────────────┘  │ │rocky-vm   │  │  │ └───────────┘  │  │
│                       │ └───────────┘  │  └─────────────────┘  │
│                       └─────────────────┘                       │
│  Networking : KubeOVN SDN · Pod CIDR 10.244.0.0/16             │
│  VM Subnet  : 172.20.0.0/24 (DHCP via OVN)                     │
│  Storage    : OpenEBS hostpath / LVM                            │
└──────────────────────────────────────────────────────────────────┘
```

---

## ✅ Prerequisites

### Hardware (per node)

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 4 cores + VT-x/AMD-V | 8+ cores |
| RAM | 8 GB | 16–32 GB |
| Disk | 100 GB | 500 GB SSD |
| Network | 1 GbE | 10 GbE |

### Software

- **OS:** Ubuntu 24.04 LTS on all 3 nodes
- **Static IPs** on all nodes, all reachable to each other
- **Internet access** during setup (image pulls)
- **KVM enabled** in BIOS (Intel VT-x or AMD-V)

### Verify KVM

```bash
grep -c '(vmx\|svm)' /proc/cpuinfo   # Must be > 0
ls /dev/kvm                           # Must exist
```

---

## 🖥️ Node Layout

| Hostname | IP | Role |
|----------|----|------|
| `control-plane-01` | `192.168.1.10` | Control plane, etcd, KubeOVN |
| `worker-01` | `192.168.1.11` | Runs KVM virtual machines |
| `worker-02` | `192.168.1.12` | Runs KVM virtual machines |

> Adjust IPs via the `CONTROL_PLANE_IP` environment variable in the setup scripts.

---

## 🚀 Quick Start

### 🧪 Try the sandbox first (recommended)

Run the full stack in Docker on your laptop — no extra hardware needed:

```bash
bash sandbox/bootstrap.sh
```

See [sandbox/SANDBOX-README.md](sandbox/SANDBOX-README.md) for details.

---

### 🏗️ Production Deployment

```bash
# ── On control-plane-01 ────────────────────────────────────────────
sudo CONTROL_PLANE_IP=192.168.1.10 bash scripts/01-setup-controlplane.sh

# ── On worker-01 and worker-02 ─────────────────────────────────────
sudo bash scripts/02-setup-workers.sh
# Then run the join command printed by step 1

# ── Back on control-plane-01 ───────────────────────────────────────
sudo bash scripts/03-install-cni.sh        # KubeOVN (default)
sudo bash scripts/04-install-storage.sh    # OpenEBS (default)
sudo bash scripts/05-install-kubevirt.sh   # KubeVirt + CDI + virtctl

# ── Deploy network config (KubeOVN only) ───────────────────────────
kubectl apply -f manifests/kubeovn/kubeovn-network.yaml

# ── Create your first VM ───────────────────────────────────────────
# Edit your SSH key in manifests/vms/ubuntu-vm.yaml first, then:
kubectl apply -f manifests/vms/ubuntu-vm.yaml
```

---

## 📖 Step-by-Step Setup

### Step 1 — Prepare all nodes

Run on **every node** before anything else:

```bash
# Set hostname (run separately on each node)
hostnamectl set-hostname control-plane-01   # or worker-01 / worker-02

# Add all nodes to /etc/hosts on each node
cat >> /etc/hosts <<EOF
192.168.1.10  control-plane-01
192.168.1.11  worker-01
192.168.1.12  worker-02
EOF

# Enable NTP time sync
timedatectl set-ntp true
```

### Step 2 — Bootstrap the control plane

```bash
# On control-plane-01
sudo CONTROL_PLANE_IP=192.168.1.10 \
     CLUSTER_NAME=virtcloud \
     K8S_VERSION=1.30 \
     bash scripts/01-setup-controlplane.sh
```

The script prints a `kubeadm join` command at the end — **save it**.

### Step 3 — Join worker nodes

```bash
# On worker-01 and worker-02 — run setup first:
sudo bash scripts/02-setup-workers.sh

# Then run the join command (copy /tmp/worker-join.sh from control plane):
sudo bash /tmp/worker-join.sh
```

Verify on control plane:

```bash
kubectl get nodes
# control-plane-01   Ready    control-plane   5m
# worker-01          NotReady <none>          2m   ← waiting for CNI
# worker-02          NotReady <none>          1m
```

### Step 4 — Install CNI

```bash
# Default: KubeOVN
sudo bash scripts/03-install-cni.sh

# Or choose:
sudo CNI_PLUGIN=flannel bash scripts/03-install-cni.sh
sudo CNI_PLUGIN=calico  bash scripts/03-install-cni.sh
sudo CNI_PLUGIN=cilium  bash scripts/03-install-cni.sh

# Wait for all nodes Ready
kubectl get nodes -w
```

### Step 5 — Install storage

```bash
# Default: OpenEBS
sudo bash scripts/04-install-storage.sh

# Or choose:
sudo STORAGE_PLUGIN=longhorn   bash scripts/04-install-storage.sh
sudo STORAGE_PLUGIN=rook-ceph  bash scripts/04-install-storage.sh

# Verify
kubectl get storageclass
```

### Step 6 — Install KubeVirt

```bash
sudo bash scripts/05-install-kubevirt.sh

# Verify
kubectl -n kubevirt get kv kubevirt
# NAME       AGE   PHASE
# kubevirt   5m    Deployed
```

### Step 7 — Apply KubeOVN network config

```bash
# Only needed if you chose KubeOVN as CNI
kubectl apply -f manifests/kubeovn/kubeovn-network.yaml
```

---

## 🔌 Plugin Customization

### CNI Plugins

| Plugin | Command | Best for |
|--------|---------|----------|
| **KubeOVN** ✅ | `CNI_PLUGIN=kubeovn` | VM networking, VPC isolation |
| Flannel | `CNI_PLUGIN=flannel` | Simple, lightweight |
| Calico | `CNI_PLUGIN=calico` | Network policies |
| Cilium | `CNI_PLUGIN=cilium` | eBPF, high performance |

### Storage Plugins

| Plugin | Command | Best for |
|--------|---------|----------|
| **OpenEBS** ✅ | `STORAGE_PLUGIN=openebs` | Default, easy setup |
| Longhorn | `STORAGE_PLUGIN=longhorn` | Built-in replication |
| Rook-Ceph | `STORAGE_PLUGIN=rook-ceph` | Enterprise HA |

### Version overrides

```bash
K8S_VERSION=1.29          bash scripts/01-setup-controlplane.sh
KUBEVIRT_VERSION=v1.1.0   bash scripts/05-install-kubevirt.sh
OPENEBS_VERSION=3.9.0     bash scripts/04-install-storage.sh
```

---

## 🖥️ Creating Virtual Machines

### Ubuntu 24.04 VM

1. Add your SSH public key to `manifests/vms/ubuntu-vm.yaml`:
   ```yaml
   ssh_authorized_keys:
     - ssh-rsa AAAA... your-actual-key
   ```

2. Apply:
   ```bash
   kubectl apply -f manifests/vms/ubuntu-vm.yaml
   ```

3. Watch the disk image download:
   ```bash
   kubectl get dv -n vms -w
   # ubuntu-vm-01-boot   ImportInProgress   45%
   # ubuntu-vm-01-boot   Succeeded          100%
   ```

4. Wait for VM to start:
   ```bash
   kubectl get vm -n vms -w
   # ubuntu-vm-01   Running   True
   ```

5. Connect:
   ```bash
   # SSH via NodePort
   ssh ubuntu@192.168.1.11 -p 30022

   # Serial console
   virtctl console ubuntu-vm-01 -n vms

   # VNC
   virtctl vnc ubuntu-vm-01 -n vms
   ```

---

## 📦 VM Templates

All templates are in `manifests/vms/vm-templates.yaml`.

| OS | Username | CPU | RAM | Disk |
|----|----------|-----|-----|------|
| Ubuntu 24.04 | `ubuntu` | 2 | 4 GiB | 20 GiB |
| Fedora 39 | `fedora` | 2 | 4 GiB | 20 GiB |
| Debian 12 | `debian` | 2 | 2 GiB | 20 GiB |
| Rocky Linux 9 | `rocky` | 2 | 4 GiB | 20 GiB |
| Alpine 3.19 | `alpine` | 1 | 512 MiB | 5 GiB |

```bash
# Add your SSH key to the file, then:
kubectl apply -f manifests/vms/vm-templates.yaml

# Start a specific template
virtctl start fedora-vm-01 -n vms
virtctl start rocky-vm-01  -n vms
virtctl start debian-vm-01 -n vms
virtctl start alpine-vm-01 -n vms
```

---

## 🌐 VM Management UI

The dashboard is `ui/virtcloud-ui.html` — a single HTML file with no dependencies.

### Option A — Open directly in browser (simplest)

```bash
# On your local machine
xdg-open ui/virtcloud-ui.html     # Linux
open ui/virtcloud-ui.html          # macOS
# Windows: double-click ui/virtcloud-ui.html
```

### Option B — Deploy to Kubernetes (accessible from any node)

```bash
# 1. Copy to every node (rename to index.html on the node)
sudo mkdir -p /opt/virtcloud-ui
scp ui/virtcloud-ui.html user@192.168.1.10:/opt/virtcloud-ui/index.html
scp ui/virtcloud-ui.html user@192.168.1.11:/opt/virtcloud-ui/index.html
scp ui/virtcloud-ui.html user@192.168.1.12:/opt/virtcloud-ui/index.html

# 2. Deploy
kubectl apply -f manifests/ui/virtcloud-ui.yaml

# 3. Access
# http://192.168.1.10:30080
# http://192.168.1.11:30080
# http://192.168.1.12:30080
```

> **Why rename?** The nginx pod expects `index.html` as the default filename. Your local file stays as `virtcloud-ui.html`.

### Option C — Build a Docker image (for production GitOps)

```bash
cd ui/
cat > Dockerfile <<'EOF'
FROM nginx:alpine
COPY virtcloud-ui.html /usr/share/nginx/html/index.html
EXPOSE 80
EOF
docker build -t ghcr.io/suman99pro/virtcloud-ui:latest .
docker push ghcr.io/suman99pro/virtcloud-ui:latest
```

---

## 🌐 Network Configuration

### Default (pod network masquerade)

VMs use NAT through the pod network — works with any CNI out of the box.

### KubeOVN VM subnet

After applying `manifests/kubeovn/kubeovn-network.yaml`:
- VMs get IPs in `172.20.0.0/24`
- DHCP served by OVN
- Direct VM-to-VM communication (no NAT)

### Static IP for a VM

```yaml
metadata:
  annotations:
    ovn.kubernetes.io/ip_address: "172.20.0.60"
    ovn.kubernetes.io/mac_address: "00:00:00:00:00:60"
```

---

## 💾 Storage Configuration

### OpenEBS hostpath (default, no extra setup)

```bash
kubectl get pvc -n vms
# Volumes stored at /var/openebs/local on the node
```

### OpenEBS LVM (better performance)

```bash
# On each worker — set up a volume group first
pvcreate /dev/sdb
vgcreate openebs-vg /dev/sdb

# Then use: storageClassName: openebs-lvm
```

### Expand a volume

```bash
kubectl patch pvc ubuntu-vm-01-boot -n vms \
  -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
```

---

## ⚙️ Common Operations

```bash
# ── VM lifecycle ────────────────────────────────────────────────────
virtctl start  ubuntu-vm-01 -n vms
virtctl stop   ubuntu-vm-01 -n vms
virtctl pause  ubuntu-vm-01 -n vms
virtctl resume ubuntu-vm-01 -n vms

# ── Live migration ──────────────────────────────────────────────────
virtctl migrate ubuntu-vm-01 -n vms
kubectl get vmim -n vms              # watch migration status

# ── Snapshots ───────────────────────────────────────────────────────
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

# ── Resize VM ───────────────────────────────────────────────────────
virtctl stop ubuntu-vm-01 -n vms
kubectl patch vm ubuntu-vm-01 -n vms --type merge \
  -p '{"spec":{"template":{"spec":{"domain":{"cpu":{"cores":4},"memory":{"guest":"8Gi"}}}}}}'
virtctl start ubuntu-vm-01 -n vms

# ── Node maintenance ────────────────────────────────────────────────
kubectl drain worker-01 --ignore-daemonsets --delete-emptydir-data
# VMs live-migrate automatically
kubectl uncordon worker-01

# ── Cluster health ──────────────────────────────────────────────────
kubectl get nodes -o wide
kubectl get pods -A | grep -v Running
kubectl -n kubevirt get all
kubectl -n openebs get all
```

---

## 🔧 Troubleshooting

### VM stuck in `Scheduling`

```bash
kubectl describe vmi ubuntu-vm-01 -n vms
kubectl -n kubevirt get pods -l kubevirt.io=virt-handler
```

### DataVolume stuck downloading

```bash
kubectl describe dv ubuntu-vm-01-boot -n vms
kubectl logs -n cdi -l app=containerized-data-importer
```

### Node won't join cluster

```bash
sudo kubeadm reset
sudo rm -rf /etc/cni/net.d
sudo systemctl restart containerd
# Get a fresh join command on control plane:
kubeadm token create --print-join-command
```

### KubeVirt using slow software emulation

```bash
ls /dev/kvm   # must exist
kubectl patch kubevirt kubevirt -n kubevirt --type merge \
  -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":false}}}}'
```

### KubeOVN pods crashing

```bash
kubectl -n kube-system logs -l app=ovs-ovn
kubectl -n kube-system rollout restart daemonset ovs-ovn
```

---

## 📁 Project Structure

```
virtcloud/
├── scripts/
│   ├── 01-setup-controlplane.sh   # Bootstrap control plane node
│   ├── 02-setup-workers.sh        # Prepare worker nodes
│   ├── 03-install-cni.sh          # CNI: KubeOVN | flannel | calico | cilium
│   ├── 04-install-storage.sh      # Storage: OpenEBS | longhorn | rook-ceph
│   └── 05-install-kubevirt.sh     # KubeVirt + CDI + virtctl
│
├── manifests/
│   ├── vms/
│   │   ├── ubuntu-vm.yaml         # Ubuntu 24.04 VM (production)
│   │   └── vm-templates.yaml      # Fedora, Debian, Rocky, Alpine
│   ├── kubeovn/
│   │   └── kubeovn-network.yaml   # VPC, VM subnet, IP pool
│   └── ui/
│       └── virtcloud-ui.yaml      # UI Kubernetes deployment
│
├── sandbox/
│   ├── SANDBOX-README.md          # Sandbox documentation
│   ├── kind-cluster.yaml          # KinD 3-node cluster config
│   ├── bootstrap.sh               # One-command sandbox setup
│   ├── teardown.sh                # Destroy sandbox
│   ├── deploy-ui.sh               # Deploy / update UI in sandbox
│   ├── ubuntu-vm-sandbox.yaml     # Lightweight VM (ContainerDisk)
│   └── virtcloud-ui-sandbox.yaml  # UI deployment for sandbox
│
├── ui/
│   └── virtcloud-ui.html          # VM management web console
│
└── README.md
```

---

## 📚 References

| Component | Docs |
|-----------|------|
| KubeVirt | https://kubevirt.io/user-guide/ |
| KubeOVN | https://kubeovn.io/docs/ |
| OpenEBS | https://openebs.io/docs/ |
| kubeadm | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ |
| CDI | https://github.com/kubevirt/containerized-data-importer |
| KinD | https://kind.sigs.k8s.io/ |

---

## 📄 License

MIT © [suman99pro](https://github.com/suman99pro)
