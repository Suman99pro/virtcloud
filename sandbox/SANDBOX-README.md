# 🧪 VirtCloud Sandbox — Kubernetes Virtualization in Docker

> **Try the full VirtCloud stack on your laptop before deploying to production**

Each "node" is a Docker container running a full Kubernetes node via **KinD (Kubernetes in Docker)**. KubeVirt, OpenEBS, and Flannel all run inside — giving you a near-production experience with zero extra hardware.

---

## ⚖️ Sandbox vs Production

| | Sandbox | Production |
|---|---|---|
| Nodes | Docker containers (KinD) | Ubuntu 24.04 bare-metal |
| VM images | ContainerDisk (instant start) | DataVolume (cloud image download) |
| KubeVirt | Software emulation (no KVM) | KVM hardware acceleration |
| CNI | Flannel or Calico | KubeOVN (full SDN) |
| Access | `localhost:30022`, `localhost:30080` | Node IP + NodePort |
| Same YAML manifests | ✅ Yes | ✅ Yes |
| Setup time | ~10 min | ~30 min |

---

## ✅ Requirements

| Resource | Minimum |
|----------|---------|
| CPU | 4 cores |
| RAM | 8 GB free |
| Disk | 20 GB free |
| Docker | 20.10+ running |

**Host OS support:**
- Linux ✅ (best experience)
- macOS with Docker Desktop ✅ (set memory to 8GB+ in Docker Desktop → Settings → Resources)
- Windows with Docker Desktop + WSL2 ✅ (run all commands in WSL2 terminal)

---

## 🚀 Quick Start

```bash
# From the repo root:
bash sandbox/bootstrap.sh
```

When done (~10 min):

```
╔══════════════════════════════════════════════════════╗
║     VirtCloud Sandbox Ready! 🎉                     ║
╠══════════════════════════════════════════════════════╣
║  UI:       http://localhost:30080                    ║
║  VM SSH:   ssh ubuntu@localhost -p 30022             ║
╚══════════════════════════════════════════════════════╝
```

Then create a VM:

```bash
# Starts in ~30 seconds (no image download needed)
kubectl apply -f sandbox/ubuntu-vm-sandbox.yaml

# Wait for VM to be Running
kubectl get vm -n vms -w

# SSH in
ssh ubuntu@localhost -p 30022
# Password: sandbox123

# Or use console
virtctl console ubuntu-sandbox-vm -n vms
```

---

## 📖 Step-by-Step Setup

If you prefer to run each step manually instead of using `bootstrap.sh`:

### 1. Install KinD

```bash
# Linux / macOS Intel
curl -fsSL https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64 \
  -o /usr/local/bin/kind && chmod +x /usr/local/bin/kind

# macOS Apple Silicon
curl -fsSL https://kind.sigs.k8s.io/dl/v0.23.0/kind-darwin-arm64 \
  -o /usr/local/bin/kind && chmod +x /usr/local/bin/kind
```

### 2. Create the cluster

```bash
mkdir -p /tmp/virtcloud-sandbox/{control-plane,worker-01,worker-02}

kind create cluster \
  --name virtcloud-sandbox \
  --config sandbox/kind-cluster.yaml \
  --wait 120s

kubectl get nodes
```

### 3. Install Flannel CNI

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

kubectl -n kube-flannel patch daemonset kube-flannel-ds \
  --type json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--iface=eth0"}]'

kubectl wait --for=condition=Ready nodes --all --timeout=300s
```

### 4. Install local-path-provisioner (default storage)

`local-path` is used instead of OpenEBS in the sandbox — it installs in seconds with no Helm chart and no heavy pods.

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

kubectl wait --for=condition=Available \
  deployment/local-path-provisioner \
  -n local-path-storage \
  --timeout=120s

kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

kubectl get storageclass
# NAME                   PROVISIONER             DEFAULT
# local-path (default)   rancher.io/local-path   true
```

> **Why not OpenEBS in sandbox?** OpenEBS pulls many images and spawns several pods — it frequently times out in resource-constrained Docker environments. `local-path` does the same job (hostpath volumes) with a single small pod and no timeout risk. OpenEBS is still used in production (script `04-install-storage.sh`).

### 5. Install KubeVirt (software emulation)

```bash
KUBEVIRT_VERSION=v1.2.0
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"

kubectl apply -f - <<'EOF'
apiVersion: kubevirt.io/v1
kind: KubeVirt
metadata:
  name: kubevirt
  namespace: kubevirt
spec:
  configuration:
    developerConfiguration:
      useEmulation: true
      featureGates: [LiveMigration]
  imagePullPolicy: IfNotPresent
  workloadUpdateStrategy:
    workloadUpdateMethods: [LiveMigrate]
EOF

kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=600s
```

### 6. Install CDI

```bash
CDI_VERSION=v1.58.1
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"
kubectl wait --for=condition=Available -n cdi cdi/cdi --timeout=300s
```

### 7. Deploy the UI

```bash
bash sandbox/deploy-ui.sh
# Open: http://localhost:30080
```

---

## 🖥️ VM Options in Sandbox

### ContainerDisk VMs (recommended — instant start)

```bash
kubectl apply -f sandbox/ubuntu-vm-sandbox.yaml
```

Available images:

| Image | OS | Size |
|-------|----|------|
| `quay.io/kubevirt/cirros-container-disk:latest` | CirrOS (test) | 40 MB |
| `quay.io/kubevirt/ubuntu-container-disk:2404` | Ubuntu 24.04 | ~500 MB |
| `quay.io/containerdisks/debian:12` | Debian 12 | ~400 MB |
| `quay.io/containerdisks/fedora:39` | Fedora 39 | ~600 MB |
| `quay.io/containerdisks/rockylinux:9` | Rocky Linux 9 | ~500 MB |

### Start the tiny Cirros test VM (boots in ~10 sec)

```bash
virtctl start cirros-test-vm -n vms
virtctl console cirros-test-vm -n vms
# Login: cirros / gocubsgo
```

### Full cloud image DataVolume (production-identical, ~5-10 min download)

```bash
# Edit SSH key in manifests/vms/ubuntu-vm.yaml first, then:
kubectl apply -f manifests/vms/ubuntu-vm.yaml
```

---

## 🌐 UI Dashboard

Access at **http://localhost:30080**

To update after changing `ui/virtcloud-ui.html`:

```bash
bash sandbox/deploy-ui.sh
```

---

## ⚙️ Customization

```bash
# Use Calico instead of Flannel
CNI_PLUGIN=calico bash sandbox/bootstrap.sh

# Use OpenEBS instead of local-path (needs 12GB+ RAM, takes longer)
STORAGE_PLUGIN=openebs bash sandbox/bootstrap.sh

# Different KubeVirt version
KUBEVIRT_VERSION=v1.1.0 bash sandbox/bootstrap.sh
```

### Low memory mode (4 GB RAM)

Edit `sandbox/ubuntu-vm-sandbox.yaml`:
```yaml
memory:
  guest: 512Mi
resources:
  requests:
    memory: 512Mi
```

Use the Cirros VM instead (only 256 MB).

---

## 📁 Sandbox File Structure

```
virtcloud/
├── sandbox/
│   ├── SANDBOX-README.md          ← This file
│   ├── kind-cluster.yaml          ← 3-node KinD cluster definition
│   ├── bootstrap.sh               ← One-command full setup
│   ├── teardown.sh                ← Destroy cluster and cleanup
│   ├── deploy-ui.sh               ← Deploy / update UI dashboard
│   ├── ubuntu-vm-sandbox.yaml     ← Sandbox VM (ContainerDisk)
│   └── virtcloud-ui-sandbox.yaml  ← UI Kubernetes deployment
│
└── ui/
    └── virtcloud-ui.html          ← VM management web console
```

---

## 🔧 Troubleshooting

### OpenEBS installation times out (`context deadline exceeded`)

This happens when your machine doesn't have enough RAM or CPU for OpenEBS. The sandbox now uses `local-path` by default which avoids this entirely. If you already ran bootstrap with `STORAGE_PLUGIN=openebs`:

```bash
# Tear down and restart with the lightweight default
bash sandbox/teardown.sh
bash sandbox/bootstrap.sh   # uses local-path automatically now
```

Or manually install local-path on the existing cluster:

```bash
# Uninstall OpenEBS if partially installed
helm uninstall openebs -n openebs 2>/dev/null || true

# Install local-path instead
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl wait --for=condition=Available deployment/local-path-provisioner \
  -n local-path-storage --timeout=120s
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get storageclass
```

### Nodes stuck in NotReady

```bash
kubectl get pods -n kube-flannel
docker exec virtcloud-sandbox-worker journalctl -u kubelet -n 30
```

### VM stuck in Scheduling

```bash
kubectl describe vmi ubuntu-sandbox-vm -n vms
# Reduce memory if "Insufficient memory":
kubectl patch vm ubuntu-sandbox-vm -n vms --type merge \
  -p '{"spec":{"template":{"spec":{"domain":{"memory":{"guest":"512Mi"}}}}}}'
virtctl stop ubuntu-sandbox-vm -n vms
virtctl start ubuntu-sandbox-vm -n vms
```

### ContainerDisk pull timeout

```bash
# Pre-pull the image then load into KinD nodes
docker pull quay.io/kubevirt/ubuntu-container-disk:2404
kind load docker-image quay.io/kubevirt/ubuntu-container-disk:2404 \
  --name virtcloud-sandbox
```

### UI not loading at localhost:30080

```bash
kubectl get pods -n virtcloud-ui
kubectl logs -n virtcloud-ui deployment/virtcloud-ui
# Re-deploy:
bash sandbox/deploy-ui.sh
```

### Reset everything

```bash
bash sandbox/teardown.sh
bash sandbox/bootstrap.sh
```

---

## 🚀 Graduating to Production

When ready for real hardware:

```bash
# On 3 Ubuntu 24.04 servers:
sudo CONTROL_PLANE_IP=192.168.1.10 bash scripts/01-setup-controlplane.sh
sudo bash scripts/02-setup-workers.sh          # on each worker
sudo bash scripts/03-install-cni.sh
sudo bash scripts/04-install-storage.sh
sudo bash scripts/05-install-kubevirt.sh

# Same VM manifests work identically:
kubectl apply -f manifests/vms/ubuntu-vm.yaml
```

See [README.md](../README.md) for full production documentation.
