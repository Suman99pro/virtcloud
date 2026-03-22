# 🧪 VirtCloud Sandbox — Kubernetes Virtualization in Docker

> Try the full VirtCloud stack on your laptop before deploying to production bare-metal.

Each "node" is a Docker container running a full Kubernetes node via **KinD (Kubernetes in Docker)**. KubeVirt, local-path storage, and Flannel all run inside — giving you a near-production experience with zero extra hardware.

---

## ⚖️ Sandbox vs Production

| | Sandbox | Production |
|---|---|---|
| Nodes | Docker containers (KinD) | Ubuntu 24.04 bare-metal |
| VM images | ContainerDisk (instant) | DataVolume (cloud image download) |
| KubeVirt | Software emulation (no KVM) | KVM hardware acceleration |
| CNI | kindnet + Flannel | KubeOVN (full SDN) |
| Storage | local-path | OpenEBS |
| Access | `localhost:30022`, `localhost:30080` | Node IP + NodePort |
| Same YAML manifests | ✅ Yes | ✅ Yes |
| Setup time | ~15–20 min (first run) | ~30 min |

---

## ✅ Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 4 cores | 8+ cores |
| RAM free | 6 GB | 8–12 GB |
| Disk free | 15 GB | 30 GB |
| Docker | 20.10+ | latest |

**Supported host OS:** Linux ✅ · macOS + Docker Desktop ✅ · Windows + WSL2 ✅

**macOS:** Go to Docker Desktop → Settings → Resources → Memory → set 8GB+

---

## 🚀 Quick Start

```bash
# From your repo root:
bash sandbox/bootstrap.sh
```

Expected output when complete (~15–20 min):

```
╔════════════════════════════════════════════════════╗
║     VirtCloud Sandbox Ready! 🎉                   ║
╠════════════════════════════════════════════════════╣
║  UI     : http://localhost:30080                   ║
║  VM SSH : ssh ubuntu@localhost -p 30022            ║
╚════════════════════════════════════════════════════╝
```

Create your first VM immediately:

```bash
# Starts in ~30 sec — no image download needed
kubectl apply -f sandbox/ubuntu-vm-sandbox.yaml

# Wait for Running
kubectl get vm -n vms -w

# SSH in
ssh ubuntu@localhost -p 30022
# Password: sandbox123
```

---

## ⚡ Speed Up KubeVirt Image Pulls

KubeVirt pulls ~600MB of images inside the cluster on first run (slow). Pre-pull on your host to load them instantly:

```bash
# Pull on host Docker (fast, uses your network stack directly)
docker pull quay.io/kubevirt/virt-operator:v1.2.0
docker pull quay.io/kubevirt/virt-api:v1.2.0
docker pull quay.io/kubevirt/virt-controller:v1.2.0
docker pull quay.io/kubevirt/virt-handler:v1.2.0
docker pull quay.io/kubevirt/virt-launcher:v1.2.0

# Inject directly into KinD nodes (bypasses slow in-cluster pull)
for img in virt-operator virt-api virt-controller virt-handler virt-launcher; do
  kind load docker-image quay.io/kubevirt/${img}:v1.2.0 --name virtcloud-sandbox
done
```

After loading, pods will move from `ContainerCreating` → `Running` in seconds.

---

## 🔁 If Bootstrap Times Out

If KubeVirt or CDI times out during `bootstrap.sh`, the cluster is still intact. Just run:

```bash
bash sandbox/resume-sandbox.sh
```

This re-waits for KubeVirt/CDI, installs `virtctl`, and deploys the UI.

---

## 📁 File Structure

```
virtcloud/
├── sandbox/
│   ├── SANDBOX-README.md          ← This file
│   ├── kind-cluster.yaml          ← KinD 3-node cluster config
│   ├── bootstrap.sh               ← Full setup (one command)
│   ├── resume-sandbox.sh          ← Resume after timeout
│   ├── teardown.sh                ← Destroy cluster + cleanup
│   ├── deploy-ui.sh               ← Deploy / update UI dashboard
│   ├── ubuntu-vm-sandbox.yaml     ← Sandbox VM (ContainerDisk)
│   └── virtcloud-ui-sandbox.yaml  ← UI Kubernetes deployment
└── ui/
    └── virtcloud-ui.html          ← VM management web console
```

---

## ⚙️ Common Operations

```bash
# VM lifecycle
virtctl start  ubuntu-sandbox-vm -n vms
virtctl stop   ubuntu-sandbox-vm -n vms
virtctl console ubuntu-sandbox-vm -n vms   # serial console (Ctrl+] to exit)

# Start the tiny Cirros test VM (boots in ~10 sec)
virtctl start cirros-test-vm -n vms
virtctl console cirros-test-vm -n vms
# Login: cirros / gocubsgo

# Check all cluster pods
kubectl get pods -A

# Check KubeVirt status
kubectl -n kubevirt get pods

# Check storage
kubectl get storageclass
kubectl get pvc -A

# Restart sandbox containers (without recreating cluster)
docker stop $(docker ps -q --filter name=virtcloud-sandbox)
docker start $(docker ps -aq --filter name=virtcloud-sandbox)
```

---

## 🔧 Troubleshooting

### Pods stuck in `ContainerCreating` / `FailedCreatePodSandBox`

This was caused by `disableDefaultCNI: true` in the old `kind-cluster.yaml`. The fixed version does **not** have this setting. If you still see this error:

```bash
# Verify the fix is in your kind-cluster.yaml
grep -i disableDefaultCNI sandbox/kind-cluster.yaml \
  && echo "REMOVE THIS LINE" || echo "OK — not present"

# If present, tear down and rebuild
bash sandbox/teardown.sh
bash sandbox/bootstrap.sh
```

### KubeVirt pods `ContainerCreating` for 10+ min

Images are still pulling. Check progress:

```bash
kubectl -n kubevirt describe pod -l kubevirt.io=virt-operator | grep -E "Pulling|Pulled|Failed"
```

Speed it up by pre-pulling images (see **Speed Up** section above).

### KubeVirt / CDI timed out

```bash
bash sandbox/resume-sandbox.sh
```

### UI not loading at localhost:30080

```bash
kubectl get pods -n virtcloud-ui
kubectl logs -n virtcloud-ui deployment/virtcloud-ui
bash sandbox/deploy-ui.sh
```

### StorageClass conflict (two defaults)

```bash
kubectl patch storageclass standard \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl get storageclass
```

### Full reset

```bash
bash sandbox/teardown.sh
bash sandbox/bootstrap.sh
```

---

## 🚀 Moving to Production

When ready for bare-metal:

```bash
sudo CONTROL_PLANE_IP=192.168.1.10 bash scripts/01-setup-controlplane.sh
sudo bash scripts/02-setup-workers.sh      # on each worker
sudo bash scripts/03-install-cni.sh        # KubeOVN
sudo bash scripts/04-install-storage.sh   # OpenEBS
sudo bash scripts/05-install-kubevirt.sh  # KubeVirt + CDI

# Exact same VM manifests work in production:
kubectl apply -f manifests/vms/ubuntu-vm.yaml
```

See [README.md](../README.md) for full production documentation.
