output "server_instance_id" {
  value = aws_instance.server.id
}

output "client_instance_id" {
  value = aws_instance.client.id
}

output "server_private_ip" {
  description = "memtier -s target (Dragonfly README: SERVER_PRIVATE_IP)."
  value       = aws_instance.server.private_ip
}

output "server_public_ip" {
  description = "SSH if the subnet assigns a public address."
  value       = aws_instance.server.public_ip
}

output "client_private_ip" {
  value = aws_instance.client.private_ip
}

output "client_public_ip" {
  value = aws_instance.client.public_ip
}

output "ssh_server" {
  description = "Example SSH to server (replace key path)."
  value       = format("ssh -i ~/.ssh/<your-key>.pem ubuntu@%s", aws_instance.server.public_ip)
}

output "ssh_client" {
  description = "Example SSH to client (replace key path)."
  value       = format("ssh -i ~/.ssh/<your-key>.pem ubuntu@%s", aws_instance.client.public_ip)
}

output "placement_group" {
  value = var.use_placement_group ? aws_placement_group.benchmark[0].name : "(disabled)"
}

output "region" {
  value = var.aws_region
}

output "subnet_id" {
  description = "Subnet used by both instances (for debugging capacity / AZ issues)."
  value       = local.subnet_id
}

output "availability_zone" {
  description = "AZ for the subnet above."
  value       = data.aws_subnet.selected.availability_zone
}
