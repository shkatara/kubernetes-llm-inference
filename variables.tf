variable "project_id" {
  description = "Primary GCP project id hosting the RKE2 server node and public gateway IP"
  type        = string
}

variable "worker_project_ids" {
  description = "Two additional GCP project ids (each using its own GPUS_ALL_REGIONS = 1 quota) hosting the two RKE2 GPU worker nodes, peered over private VPC."
  type        = list(string)

  validation {
    condition     = length(var.worker_project_ids) == 2
    error_message = "Provide exactly 2 worker GCP project IDs so the cluster gets 3 GPUs total (1 server + 2 workers)."
  }
}

variable "region" {
  description = "Region for all three peered VPC subnets and VMs"
  type        = string
  default     = "asia-south1"
}

variable "zone" {
  description = "Zone to deploy into. In Mumbai (asia-south1), T4 GPUs are available in asia-south1-a and asia-south1-b."
  type        = string
  default     = "asia-south1-a"
}

variable "spot" {
  description = "Provision VMs as GCP Spot instances (~60-70% cheaper, may be preempted/stopped by GCP)."
  type        = bool
  default     = true
}

variable "name" {
  description = "Prefix for all resource names"
  type        = string
  default     = "llm-gpu-demo"
}

variable "machine_type" {
  description = "Machine type for the RKE2 server node. n1-standard-8 has 8 vCPU and 30 GB RAM."
  type        = string
  default     = "n1-standard-8"
}

variable "worker_machine_type" {
  description = "Machine type for each RKE2 GPU worker node. n1-standard-4 has 4 vCPU and 15 GB RAM."
  type        = string
  default     = "n1-standard-4"
}

variable "gpu_count" {
  description = "Number of T4 GPUs attached to the RKE2 server node."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 4], var.gpu_count)
    error_message = "GCP Compute Engine only allows 1, 2, or 4 nvidia-tesla-t4 GPUs per N1 instance."
  }
}

variable "worker_gpu_count" {
  description = "Number of T4 GPUs attached to each RKE2 GPU worker node."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 4], var.worker_gpu_count)
    error_message = "GCP Compute Engine only allows 1, 2, or 4 nvidia-tesla-t4 GPUs per N1 instance."
  }
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB for the server node."
  type        = number
  default     = 100
}

variable "worker_boot_disk_size_gb" {
  description = "Boot disk size in GB for each worker node."
  type        = number
  default     = 100
}

variable "ssh_source_ranges" {
  description = "CIDR ranges allowed to SSH and reach the Kubernetes API. When empty, defaults to your current public IPv4 (/32)."
  type        = list(string)
  default     = []
}

variable "http_source_ranges" {
  description = "CIDR ranges allowed to reach ports 80, 443, and 3000 (Grafana Gateway LB) on the gateway. When empty, defaults to your current public IPv4 (/32)."
  type        = list(string)
  default     = []
}

variable "rke2_channel" {
  description = "RKE2 release channel used by the installer"
  type        = string
  default     = "stable"
}

variable "openrouter_api_key" {
  description = "Optional OpenRouter API key for cloud fallback when local GPU InferencePools are unavailable"
  type        = string
  default     = ""
  sensitive   = true
}
