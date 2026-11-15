terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Estado remoto en GCS (contiene secretos generados: proteger el bucket).
  # Crear el bucket antes (ver README 2.2):
  #   gcloud storage buckets create gs://<BUCKET> --project=<PROYECTO> --location=us-central1 --uniform-bucket-level-access
  #   gcloud storage buckets update gs://<BUCKET> --versioning
  backend "gcs" {
    # bucket = "mi-bucket-tfstate"   # se pasa con: terraform init -backend-config="bucket=..."
    prefix = "defectdojo-iap"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

data "google_project" "this" {
  project_id = var.project_id
}
