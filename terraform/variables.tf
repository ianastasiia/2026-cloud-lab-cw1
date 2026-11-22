variable "cloud_id" {
  description = "ID облака Yandex Cloud"
  type        = string
}

variable "folder_id" {
  description = "ID каталога Yandex Cloud"
  type        = string
}

variable "bucket_name" {
  description = "Имя бакета Object Storage (глобально уникальное, должно начинаться с vvot09-)"
  type        = string
}