terraform {
  backend "s3" {
    bucket       = "eks-demo-047585400236-ap-south-1-an"
    key          = "terraform.demo.tfstate"
    region       = "ap-south-1"
    profile      = "mlbd-tahjib"
    encrypt      = true
    use_lockfile = true
  }
}