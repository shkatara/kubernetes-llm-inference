output "public_ip" {
  description = "Public IP of the gateway / RKE2 server node in Mumbai"
  value       = google_compute_address.server.address
}

output "ssh_command" {
  description = "SSH into the Mumbai RKE2 server node (project 1)"
  value       = "gcloud compute ssh ${google_compute_instance.server.name} --project ${var.project_id} --zone ${var.zone}"
}

output "worker_ssh_commands" {
  description = "SSH into each RKE2 GPU worker node (projects 2 and 3)"
  value = [
    for idx, inst in google_compute_instance.worker :
    "gcloud compute ssh ${inst.name} --project ${var.worker_project_ids[idx]} --zone ${var.zone}"
  ]
}

output "gateway_url" {
  description = "Once the stack is up, the OpenAI-compatible base URL"
  value       = "http://${google_compute_address.server.address}/v1"
}

output "grafana_url" {
  description = "Grafana UI exposed via Gateway LoadBalancer on port 3000"
  value       = "http://${google_compute_address.server.address}:3000"
}

output "grafana_admin_password_command" {
  description = "Print the Grafana admin password"
  value       = "KUBECONFIG=$PWD/kubeconfig.yaml kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d && echo"
}

output "kubeconfig_command" {
  description = "Fetch a kubeconfig to your machine"
  value       = "gcloud compute ssh ${google_compute_instance.server.name} --project ${var.project_id} --zone ${var.zone} --command 'sudo cat /etc/rancher/rke2/rke2.yaml' > kubeconfig.yaml && perl -pi -e 's/127\\.0\\.0\\.1/${google_compute_address.server.address}/g' kubeconfig.yaml"
}

output "startup_log_command" {
  description = "Follow provisioning progress on the Mumbai RKE2 server node"
  value       = "gcloud compute ssh ${google_compute_instance.server.name} --project ${var.project_id} --zone ${var.zone} --command 'sudo tail -f /var/log/llm-demo-startup.log'"
}

output "grafana_port_forward_command" {
  description = "Port-forward Grafana (http://localhost:3000) and print the admin password"
  value       = "KUBECONFIG=$PWD/kubeconfig.yaml kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d && echo && KUBECONFIG=$PWD/kubeconfig.yaml kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
}
