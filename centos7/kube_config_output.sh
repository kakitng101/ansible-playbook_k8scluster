NAMESPACE="default"           
SA_NAME="deploy"
CR_NAME="deploy-clusterrole"
SECRET_NAME="${SA_NAME}-token-secret"


# 1. 创建 ServiceAccount
kubectl create serviceaccount ${SA_NAME} -n ${NAMESPACE}

kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CR_NAME}
rules:
# 自定义clusterrole权限和资源组
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets", "daemonsets"]
  verbs: ["patch","list","get"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["patch","list","get"]
EOF


# 2. 创建 ClusterRoleBinding
kubectl create clusterrolebinding ${SA_NAME}-binding \
  --clusterrole=${CR_NAME} \
  --serviceaccount=${NAMESPACE}:${SA_NAME}


# 3. 创建 Secret(新版本k8s默认sa不创建secret)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

# 4. 创建 kubeconfig 文件
TOKEN=$(kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.token}' | base64 --decode)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_CERT=$(kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.ca\.crt}' | base64 --decode)


cat <<EOF > /tmp/kubeconfig-sa-$SA_NAME-$NAMESPACE.config
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
    user: $SA_NAME-$NAMESPACE
  name: $SA_NAME-$NAMESPACE-context
current-context: $SA_NAME-$NAMESPACE-context
users:
- name: $SA_NAME-$NAMESPACE
  user:
    token: $TOKEN
EOF

echo "kubeconfig file created at "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/kubeconfig-sa-$SA_NAME-$NAMESPACE"
