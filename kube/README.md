# Platform Kubernetes Deployment

This folder contains a sample configuration for platform Kubernetes deployment.

## Requires

Requires a working kubernetes cluster with min one node. Each node should have at least 2 vCPUs and 8 GB RAM.

If you don't have any k8s cluster, consider using the [kind setup](QUICKSTART.md).

## Check and update configuration

Deployment configuration is located in [config.yaml](config/config.yaml) and [secret.yaml](config/secret.yaml) files.
The sample configuration assumes that the platform is available on huly.example hostname with dedicated hostname per service.

## Deploy the platform to Kubernetes

Deploy the platform with `kubectl`.

```bash
kubectl create namespace huly-v7

kubectl apply -R -f . --namespace huly-v7
```

Now, launch your web browser and enjoy the platform!
