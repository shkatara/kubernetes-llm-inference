#!/usr/bin/env bash
set -euxo pipefail
exec > >(tee -a /var/log/llm-demo-startup.log) 2>&1

# Runs on every boot (GCE startup script). Skip only once full provisioning succeeded,
# so a Spot preemption during initial setup resumes cleanly on restart.
if [ -f /opt/demo-ready ]; then
  echo "Already provisioned, nothing to do"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates jq apt-transport-https gnupg lsb-release "linux-headers-$(uname -r)"

# Raise inotify limits so GPU operator validators and multiple pods do not exhaust watchers,
# and disable rp_filter so Cilium/WireGuard overlay traffic across peered VPCs is not dropped.
cat > /etc/sysctl.d/99-k8s-inotify.conf <<'EOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
sysctl --system
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f"; done

# --------------------------------------------------------------- RKE2 server
# Disable RKE2's bundled ingress controller so host port 80 is free, enable
# ServiceLB so Gateway LoadBalancer Services bind host port 80, use Cilium with
# WireGuard across peered VPCs (avoids kernel 6.8 VXLAN checksum offload drops on GCE),
# and add both the public and internal server IPs to the API server TLS SANs.
mkdir -p /etc/rancher/rke2 /var/lib/rancher/rke2/server/manifests
cat > /etc/rancher/rke2/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

cat > /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    operator:
      replicas: 1
    encryption:
      enabled: true
      type: wireguard
EOF

cat > /etc/rancher/rke2/config.yaml <<'EOF'
token: "${rke2_token}"
write-kubeconfig-mode: "0600"
advertise-address: "${server_internal_ip}"
node-ip: "${server_internal_ip}"
resolv-conf: "/etc/rancher/rke2/resolv.conf"
cni: cilium
tls-san:
  - "${public_ip}"
  - "${server_internal_ip}"
node-external-ip: "${public_ip}"
ingress-controller: none
enable-servicelb: true
EOF

curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL=${rke2_channel} sh -
systemctl enable rke2-server.service
systemctl start rke2-server.service

for i in $(seq 1 60); do
  if [ -f /etc/rancher/rke2/rke2.yaml ]; then break; fi
  sleep 10
done

mkdir -p /root/.kube
cp /etc/rancher/rke2/rke2.yaml /root/.kube/config
chmod 600 /root/.kube/config
ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
export KUBECONFIG=/root/.kube/config
export PATH=$PATH:/var/lib/rancher/rke2/bin

# Wait for all cluster nodes (server + 2 peered GPU workers) to join and report Ready.
for i in $(seq 1 90); do
  READY_NODES=$( (kubectl get nodes --no-headers 2>/dev/null || true) | awk '$2 == "Ready" {count++} END {print count+0}' )
  if [ "$READY_NODES" -ge "${expected_nodes}" ]; then break; fi
  sleep 10
done

# ---------------------------------------------------------------------- Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ----------------------------------------------- kube-prometheus-stack (Prom + Grafana)
# Install before GPU Operator and agentgateway so ServiceMonitor/PodMonitor CRDs exist
# when those charts reconcile, and allow Prometheus/Grafana to discover monitors and
# dashboards across all namespaces.
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --wait --timeout 10m \
  --set alertmanager.enabled=false \
  --set kubeEtcd.enabled=false \
  --set kubeControllerManager.enabled=false \
  --set kubeScheduler.enabled=false \
  --set kubeProxy.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.retention=2d \
  --set grafana.sidecar.dashboards.searchNamespace=ALL

# -------------------------------------------------------- NVIDIA GPU operator
# GPU Operator on RKE2 (containerd 2.x) uses CDI and only needs the RKE2 containerd socket path.
helm upgrade -i gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --wait --timeout 25m \
  --set driver.enabled=true \
  --set toolkit.enabled=true \
  --set toolkit.env[0].name=CONTAINERD_SOCKET \
  --set toolkit.env[0].value=/run/k3s/containerd/containerd.sock \
  --set dcgmExporter.serviceMonitor.enabled=true

# Wait until the sum of allocatable GPUs across all 3 nodes reaches total_gpus.
for i in $(seq 1 80); do
  GPUS=$( (kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}') | jq '[.items[].status.allocatable["nvidia.com/gpu"] // "0" | tonumber] | add // 0' || echo 0 )
  if [ "$GPUS" -ge "${total_gpus}" ]; then break; fi
  sleep 15
done

# ----------------------------------- Gateway API + Inference Extension CRDs
# Install Gateway API and GIE CRDs before agentgateway so the controller discovers InferencePool.
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

kubectl apply -f \
  https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.4.0/manifests.yaml

# ------------------------------------------------------- agentgateway and GIE
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace agentgateway-system --create-namespace \
  --version v1.7.0

helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system \
  --version v1.7.0 \
  --set inferenceExtension.enabled=true \
  --set monitoring.enabled=true \
  --set monitoring.proxy.namespaceSelector.any=true \
  --wait --timeout 10m

# --------------------------------------------------------------- Demo stack
kubectl create secret generic openrouter-secret \
  --namespace default \
  --from-literal=Authorization='${openrouter_api_key}' \
  --dry-run=client -o yaml | kubectl apply -f -

echo '${manifests}' | base64 -d > /opt/demo.yaml
kubectl apply -f /opt/demo.yaml

kubectl rollout status deployment/epp-qwen2-5-3b-instruct -n default --timeout=10m
kubectl rollout status deployment/epp-smollm2-1-7b-instruct -n default --timeout=10m
kubectl rollout status deployment/qwen2.5-3b-instruct -n default --timeout=25m
kubectl rollout status deployment/smollm2-1.7b-instruct -n default --timeout=25m
kubectl wait --for=condition=Programmed gateway/inference-gateway -n default --timeout=5m
kubectl wait --for=condition=Programmed gateway/grafana-gateway -n monitoring --timeout=5m

touch /opt/demo-ready
echo "Demo stack is up. Gateway at http://${public_ip}/v1 | Grafana at http://${public_ip}:3000"
