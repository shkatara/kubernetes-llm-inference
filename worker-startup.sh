#!/usr/bin/env bash
set -euxo pipefail
exec > >(tee -a /var/log/llm-demo-startup.log) 2>&1

# Runs on every boot (GCE startup script). Skip only once the agent joined cleanly.
if [ -f /opt/worker-ready ]; then
  echo "Worker already provisioned, nothing to do"
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

# --------------------------------------------------------------- RKE2 agent
mkdir -p /etc/rancher/rke2
cat > /etc/rancher/rke2/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

cat > /etc/rancher/rke2/config.yaml <<'EOF'
server: https://${server_internal_ip}:9345
token: "${rke2_token}"
node-ip: "${worker_internal_ip}"
resolv-conf: "/etc/rancher/rke2/resolv.conf"
EOF

curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" INSTALL_RKE2_CHANNEL=${rke2_channel} sh -

# Wait for the RKE2 server supervisor port over VPC peering before starting the agent.
for i in $(seq 1 90); do
  if timeout 3 bash -c "</dev/tcp/${server_internal_ip}/9345" 2>/dev/null; then
    break
  fi
  sleep 10
done

systemctl enable rke2-agent.service
systemctl start rke2-agent.service

touch /opt/worker-ready
echo "RKE2 GPU worker joined https://${server_internal_ip}:9345"
