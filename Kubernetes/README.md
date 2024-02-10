# Kubernetes Command Guide


# Applying Configuration
### Applies a configuration to a resource from a file <br />
```bash
kubectl apply -f [config-file]
```


# Labels
### Assigning a Label to a Node

```bash
kubectl label nodes <node-name> node-role.kubernetes.io/worker=<label_name>
```
### Set node as master: <br />
```bash
kubectl label nodes <node-name> node-role.kubernetes.io/master=master
```


# Namespaces
### List all namespaces <br />
```bash
kubectl get ns
```
### Create namespace <br />
```bash
kubectl create namespace [namespace-name]
```
### Describe namespace <br />
```bash
kubectl describe namespace [namespace-name]
```
### Delete namespace <br />
```bash
kubectl delete namespace [namespace-name]
```


# Node and cluster management
### Lists all nodes in the cluster <br />
```bash
kubectl get nodes
```
### Mark the node as unschedulable <br />
```bash
kubectl cordon [node-name]
```
### Drains all pods from the node in preparation for maintenance <br />
```bash
kubectl drain [node-name]
```


# POD management
### Lists all pods in the namespace <br />
```bash
kubectl get pods
```
### Shows detailed information about a specific pod <br />
```bash
kubectl describe pod [pod-name]
```
### Fetches the logs of a specific pod <br />
```bash
kubectl logs [pod-name]
```
### Executes a command in a specific pod <br />
```bash
kubectl exec [pod-name] -- [command]
```


# Deployment management
### Lists all deployments in the namespace <br />
```bash
kubectl get deployments
```
### Shows the status of a specific deployment rollout <br />
```bash
kubectl rollout status deployment/[deployment-name]
```
### Rolls back to the previous deployment <br />
```bash
kubectl rollout undo deployment/[deployment-name]
```


# Service management
### Lists all services in the namespace <br />
```bash
kubectl get services
```
### Exposes a deployment as a new Kubernetes service <br />
```bash
kubectl expose deployment [deployment-name]
```


# ConfigMap and Secret Management
### Creates a new secret from literals <br />
```bash
kubectl create secret generic [secret-name] --from-literal=[key]=[value]
```
### Lists all configmaps in the namespace <br />
```bash
kubectl get configmaps
```


# Resource Inspection
### Shows metrics for pods in the namespace <br />
```bash
kubectl top pod
```
### Shows detailed information about a specific node <br />
```bash
kubectl describe node [node-name]
```


# Scaling Resources
### Scales a deployment to the specified number of replicas <br />
```bash
kubectl scale deployment [deployment-name] --replicas=[number]
```


