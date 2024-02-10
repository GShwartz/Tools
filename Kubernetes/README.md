### Labels
- Give a label to a node: <br />
kubectl label nodes <node-name> node-role.kubernetes.io/worker=<label_name> <br />

- Set node as master: <br />
kubectl label nodes <node-name> node-role.kubernetes.io/master=master <br/>

### Namespaces
- List all namespaces <br />
kubectl get ns <br/>

- Create namespace <br />
kubectl create namespace [namespace-name] <br />

- Describe namespace <br />
kubectl describe namespace [namespace-name] <br />

- Delete namespace <br />
kubectl delete namespace [namespace-name] <br />


