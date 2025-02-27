provider "aws" {
  region = "us-east-1"
}

variable "spacelift_access_key" {}
variable "spacelift_secret_key" {}

terraform {
  required_providers {
    spacelift = {
      source  = "spacelift-io/spacelift"
      version = "~> 1.0"  # Use the latest compatible version
    }
  }
}

provider "spacelift" {
  access_key = var.spacelift_access_key
  secret_key = var.spacelift_secret_key
}


resource "spacelift_worker_pool" "private_pool" {
  name        = "private-worker-pool"
  description = "Private worker pool for secure workloads"
}

resource "null_resource" "generate_csr" {
  provisioner "local-exec" {
    command = <<EOT
      openssl req -new -newkey rsa:2048 -nodes -keyout worker.key -out worker.csr -subj "/CN=spacelift-worker"
    EOT
  }
}

resource "spacelift_worker_pool_certificate" "worker_cert" {
  worker_pool_id = spacelift_worker_pool.private_pool.id
  csr            = file("worker.csr")
}

resource "null_resource" "store_cert" {
  depends_on = [spacelift_worker_pool_certificate.worker_cert]
  provisioner "local-exec" {
    command = <<EOT
      echo '${spacelift_worker_pool_certificate.worker_cert.certificate}' > worker.crt
    EOT
  }
}

resource "aws_instance" "spacelift_worker" {
  ami           = "ami-0e1bed4f06a3b463d"  # Ubuntu 22.04 AMI
  instance_type = "t3.medium"
  key_name      = "dashathkey"
  user_data     = file("${path.module}/user_data.sh")

  tags = {
    Name = "Spacelift-Worker"
  }
}

resource "null_resource" "install_docker_and_worker" {
  depends_on = [aws_instance.spacelift_worker, null_resource.store_cert]
  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("your-private-key.pem")
    host        = aws_instance.spacelift_worker.public_ip
  }
  provisioner "remote-exec" {
    inline = [
      "sudo apt update && sudo apt install -y docker.io curl",
      "curl -Lo spacelift-launcher https://downloads.spacelift.io/spacelift-launcher-x86_64",
      "chmod +x spacelift-launcher",
      "cat worker.key | base64 -w 0 > worker_key_encoded.txt",
      "export SPACELIFT_TOKEN=$(cat worker.crt)",
      "export SPACELIFT_POOL_PRIVATE_KEY=$(cat worker_key_encoded.txt)",
      "export SPACELIFT_WORKER_POOL_CERT=/root/worker.crt",
      "export SPACELIFT_WORKER_POOL_KEY=/root/worker.key",
      "./spacelift-launcher"
    ]
  }
}
