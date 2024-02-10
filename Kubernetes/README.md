# Kubernetes Command Guide

## Labels

Labels in Kubernetes are key/value pairs attached to objects like nodes for identification and organization.

### Assigning a Label to a Node

```bash
kubectl label nodes <node-name> node-role.kubernetes.io/worker=<label_name>
```

### Set node as master: <br />
```bash
kubectl label nodes <node-name> node-role.kubernetes.io/master=master
```


## Namespaces
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


