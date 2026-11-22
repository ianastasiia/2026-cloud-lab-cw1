output "api_gateway_url" {
  description = "Точка входа: служебный домен API-шлюза"
  value       = "https://${yandex_api_gateway.gateway.domain}"
}

output "tasks_queue_url" {
  description = "URL очереди заданий"
  value       = yandex_message_queue.tasks.id
}

output "dead_letter_queue_url" {
  description = "URL очереди необработанных заданий"
  value       = yandex_message_queue.dead_letter.id
}