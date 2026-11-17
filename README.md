# LLM on GPUs demo: Terraform + RKE2 + agentgateway

A 3-node RKE2 cluster in Mumbai (`asia-south1-a`) across **3 dedicated physical Spot T4 GPUs**, spanning 3 VPC-peered GCP projects so each project only needs `GPUS_ALL_REGIONS = 1`:

- **Project 1 (`<gcp-project-1>`, `10.10.0.10`)**: Spot `n1-standard-8` + `1 x nvidia-tesla-t4` (RKE2 server + `inference-gateway` + 1 GPU).
- **Project 2 (`<gcp-project-2>`, `10.20.0.10`)**: Spot `n1-standard-4` + `1 x nvidia-tesla-t4` (RKE2 worker-1 + 1 GPU).
- **Project 3 (`<gcp-project-3>`, `10.30.0.10`)**: Spot `n1-standard-4` + `1 x nvidia-tesla-t4` (RKE2 worker-2 + 1 GPU).

All three VPCs are connected in a full private VPC peering mesh (`$0.00` peering + `$0.00/GB` same-zone Mumbai traffic), and all models are served behind one OpenAI-compatible gateway endpoint with automatic OpenRouter failover.

## What gets created

- Three VPCs + subnets (`10.10.0.0/24`, `10.20.0.0/24`, `10.30.0.0/24` in `asia-south1`), full-mesh `google_compute_network_peering`, firewall rules, and one static gateway IP in Project 1
- Spot `n1-standard-8` RKE2 server (8 vCPU, 30 GB RAM, 1 x T4, 100 GB SSD) + two Spot `n1-standard-4` RKE2 workers (4 vCPU, 15 GB RAM, 1 x T4, 100 GB SSD each) in `asia-south1-a`
- Startup scripts that join both workers to `https://10.10.0.10:9345` over private VPC peering, install Helm + `kube-prometheus-stack` (Prometheus + Grafana), NVIDIA GPU operator across all 3 T4s (with DCGM `ServiceMonitor`), Gateway API + GIE CRDs, agentgateway CRDs + controller (with `monitoring.enabled=true` and Grafana dashboard), and the manifests under `k8s/`
- Three vLLM pods (`2 x qwen2.5-3b-instruct`, `1 x smollm2-1.7b-instruct`), one Endpoint Picker per model pool (`epp-qwen2-5-3b-instruct`, `epp-smollm2-1-7b-instruct`) with `prefix-cache-scorer` and `--v=4` scorer logs enabled, two InferencePools (`qwen2-5-3b-instruct`, `smollm2-1-7b-instruct`), two `AgentgatewayBackend`s (`qwen2.5-3b-instruct`, `smollm2-1.7b-instruct`), `inference-gateway` (`:80`) + `grafana-gateway` (`:3000`), `PreRouting` + health eviction + retry `AgentgatewayPolicy` resources, `HTTPRoute`s, a custom **LLM Inference & GPU Routing** Grafana dashboard (`ConfigMap/grafana-dashboard-llm`), and `PodMonitor`/`ServiceMonitor` resources for vLLM and EPP

## Prerequisites

- `gcloud` authenticated with an account that has Owner/Editor (and Compute Engine API enabled) on all three projects
- Terraform 1.5+
- `GPUS_ALL_REGIONS >= 1` and `PREEMPTIBLE_NVIDIA_T4_GPUS >= 1` in `asia-south1` on each of the 3 projects

## Usage

```bash
git clone https://github.com/shkatara/kubernetes-llm-inference.git
cd kubernetes-llm-inference

cat > terraform.tfvars <<EOF
project_id = "<gcp-project-1>"
worker_project_ids = [
  "<gcp-project-2>",
  "<gcp-project-3>",
]
region             = "asia-south1"
zone               = "asia-south1-a"
spot               = true
openrouter_api_key = "sk-or-v1-..."
EOF

terraform init
terraform apply
```

Provisioning takes 15 to 25 minutes, mostly driver install and image pulls across the 3 nodes.
Watch progress with the output command `startup_log_command`.

When `/opt/demo-ready` exists on the server node, the gateway is live:

```bash
curl http://$(terraform output -raw public_ip)/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-3b-instruct","messages":[{"role":"user","content":"hi"}]}'
```

Switch `"model"` to `"smollm2-1.7b-instruct"` on the same URL to hit the second pool.

## Verify prefix-based KV cache routing

Fetch the cluster kubeconfig using `terraform output -raw kubeconfig_command`, then watch
both `qwen2.5-3b-instruct` replicas and the EPP scheduler in two terminals:

```bash
export KUBECONFIG=$PWD/kubeconfig.yaml

# Terminal A: vLLM replica logs
kubectl logs -f -l app=qwen2.5-3b-instruct --tail=-1 --prefix | grep -E "POST /v1|Prefix cache hit rate"

# Terminal B: EPP per-pod scorer & picker decisions (--v=4)
kubectl logs -f deploy/epp-qwen2-5-3b-instruct | grep -E "Calculated score|Completed running picker|Request handled"
```

Multi-turn sessions against `qwen2.5-3b-instruct` stick to the replica holding
their cached prompt prefix, while an unrelated session with a different prefix can be
scheduled onto the second replica.

## Verify OpenRouter fallback when local GPUs are unavailable

If you did not pass `openrouter_api_key` in `terraform.tfvars`, update `openrouter-secret` at runtime:

```bash
kubectl create secret generic openrouter-secret \
  --namespace default \
  --from-literal=Authorization="$OPENROUTER_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Scale the local `qwen2.5-3b-instruct` pool to zero replicas and send a request with the same model name:

```bash
kubectl scale deploy qwen2.5-3b-instruct --replicas=0

curl --retry 1 --retry-delay 1 --retry-all-errors -s http://$(terraform output -raw public_ip)/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-3b-instruct","messages":[{"role":"user","content":"hi"}]}' \
  | jq -r '.model'
# Returns: meta-llama/llama-3.2-3b-instruct

# Restore local GPU replicas
kubectl scale deploy qwen2.5-3b-instruct --replicas=2
```

## Monitor with Prometheus & Grafana (`kube-prometheus-stack`)

`kube-prometheus-stack` runs in the `monitoring` namespace and automatically scrapes:

1. **`agentgateway` proxy & controller** (including the bundled Agentgateway Grafana dashboard)
2. **EPP schedulers** (`ServiceMonitor/inference-epp` on `:9090/metrics`)
3. **vLLM pods** (`PodMonitor/vllm-models` on `:8000/metrics`)
4. **NVIDIA DCGM GPU exporter** (`dcgmExporter.serviceMonitor.enabled=true`)

Grafana is exposed directly on `http://<public_ip>:3000` via `Gateway/grafana-gateway` (`k8s/gateway-grafana.yaml` + `k8s/httproute-grafana.yaml`) and comes pre-loaded with two dashboards via the sidecar: **LLM Inference & GPU Routing** (`k8s/configmap-grafana-dashboard-llm.yaml`) and **Agentgateway**.

Print the `admin` password and Grafana URL using the Terraform outputs:

```bash
eval "$(terraform output -raw grafana_admin_password_command)"
terraform output -raw grafana_url
# Open http://<public_ip>:3000 (user: admin)
```

(Or port-forward locally if preferred: `eval "$(terraform output -raw grafana_port_forward_command)"`.)

Useful PromQL queries in Grafana Explore / Prometheus (`kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090`):

- **Gateway local vs. OpenRouter fallback**: `sum by (gen_ai_request_model, gen_ai_response_model) (rate(agentgateway_gen_ai_client_token_usage_count[5m]))`
- **Gateway Time to First Token (p95)**: `histogram_quantile(0.95, sum by (le, gen_ai_request_model) (rate(agentgateway_gen_ai_server_time_to_first_token_bucket[5m])))`
- **EPP prefix-cache match ratio**: `histogram_quantile(0.5, sum by (le) (rate(inference_extension_prefix_indexer_hit_ratio_bucket[5m])))`
- **EPP pool KV cache & ready pods**: `inference_pool_average_kv_cache_utilization`, `inference_pool_ready_pods`
- **Per-pod vLLM prefix cache hits**: `rate(vllm:prefix_cache_hits_total[5m])`
- **Physical T4 GPU & VRAM utilization**: `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`

## Connect the pi agent harness

Add to `~/.pi/agent/models.json`:

```json
{
  "$schema": "https://pi.dev/schemas/models.schema.json",
  "providers": {
    "gcp-demo": {
      "name": "GCP Kubernetes GPU Cluster",
      "baseUrl": "http://<public_ip>/v1",
      "api": "openai-completions",
      "apiKey": "demo",
      "models": [
        {
          "id": "qwen2.5-3b-instruct",
          "name": "Qwen2.5 3B (2x T4 pool)",
          "input": ["text"],
          "reasoning": false,
          "contextWindow": 8192,
          "maxTokens": 2048,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "smollm2-1.7b-instruct",
          "name": "SmolLM2 1.7B (1x T4 pool)",
          "input": ["text"],
          "reasoning": false,
          "contextWindow": 8192,
          "maxTokens": 2048,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ],
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      }
    }
  }
}
```

Then `/model` inside pi and pick `qwen2.5-3b-instruct` or `smollm2-1.7b-instruct`.

## If Spot preempts a VM

Because `instance_termination_action = "STOP"`, GCP stops preempted VMs rather than deleting them:

```bash
gcloud compute instances start llm-gpu-demo-node --project <gcp-project-1> --zone asia-south1-a
gcloud compute instances start llm-gpu-demo-worker-1 --project <gcp-project-2> --zone asia-south1-a
gcloud compute instances start llm-gpu-demo-worker-2 --project <gcp-project-3> --zone asia-south1-a
```

## Teardown

```bash
terraform destroy
```

This deletes all three VMs, disks, peerings, subnets, VPCs, and static IP across all three projects.

## Cost

Across the 3 Spot VMs in Mumbai (`1x` `n1-standard-8` + `2x` `n1-standard-4`, `3x` Spot T4 GPUs, `3x` 100 GB SSD, `$0` same-zone VPC peering), the stack runs roughly **~$0.85 USD per hour (~$20.50 USD / day)**. Always `terraform destroy` when done.

## Security notes

This is a demo, not a hardened deployment. By default, Terraform fetches your
current public IPv4 (`https://ipv4.icanhazip.com`) and locks `ssh_source_ranges`
and `http_source_ranges` to `<your-ip>/32` (re-run `terraform apply` if your ISP
rotates your IP). There is no TLS and no API key check by default. Destroy it
when done.

## Troubleshooting

- Pods `Pending` with `insufficient nvidia.com/gpu`:
  Check `kubectl get nodes` (confirm all 3 nodes are `Ready`) and `kubectl get pods -n gpu-operator`.
- Startup script failed early: `sudo tail -200 /var/log/llm-demo-startup.log` on any node.
- No Spot T4 capacity in `asia-south1-a`: switch `zone = "asia-south1-b"` in `terraform.tfvars`.
- 503 from the gateway: check `kubectl logs deploy/epp-qwen2-5-3b-instruct` and confirm
  `InferencePool` targetPort (`8000`) matches the vLLM container port and that
  EPP readiness probes on port `9003` are passing.
