NAMESPACE=default
SERVICE_ACCOUNT=k8s-tls-deploy
SECRET_NAME=$(kubectl get sa $SERVICE_ACCOUNT -n $NAMESPACE -o jsonpath='{.secrets[0].name}')
TOKEN=$(kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.token}' | base64 --decode)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_CERT=$(kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.ca\.crt}' | base64 --decode)

cat <<EOF > /opt/kubeconfig-sa-$SERVICE_ACCOUNT-$NAMESPACE.config
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $(echo "$CA_CERT" | base64 | tr -d '\n')
    server: $APISERVER
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    namespace: $NAMESPACE
    user: $SERVICE_ACCOUNT-$NAMESPACE
  name: $SERVICE_ACCOUNT-$NAMESPACE-context
current-context: $SERVICE_ACCOUNT-$NAMESPACE-context
users:
- name: $SERVICE_ACCOUNT-$NAMESPACE
  user:
    token: $TOKEN
EOF

echo "kubeconfig file created at ./kubeconfig-sa-$SERVICE_ACCOUNT-$NAMESPACE"
