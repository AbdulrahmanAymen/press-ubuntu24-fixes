output "server_public_ips" {
  description = "Public (Elastic) IP of each server — use these for your DuckDNS A records."
  value = {
    for role, eip in aws_eip.server : role => eip.public_ip
  }
}

output "server_private_ips" {
  description = "Private IP of each server — use these in Press's Proxy/Database/Server 'Private IP' fields."
  value = {
    for role, inst in aws_instance.server : role => inst.private_ip
  }
}

output "ssh_commands" {
  description = "Ready-to-copy SSH commands for each server as the default 'ubuntu' user."
  value = {
    for role, eip in aws_eip.server :
    role => "ssh -i ~/.ssh/${var.key_pair_name}.pem ubuntu@${eip.public_ip}"
  }
}
