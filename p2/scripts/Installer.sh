if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

echo "Installing dependencies..."
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644

echo "Deploying applications..."

kubectl apply -f /vagrant/k8s/nginx.yaml
kubectl apply -f /vagrant/k8s/apache.yaml
kubectl apply -f /vagrant/k8s/app3.yaml

echo "Applications deployed."

kubectl apply -f /vagrant/k8s/ingress.yaml

echo "Configuring local hostnames..."

HOSTS_LINE="192.168.56.110 app1.com app2.com"

if ! grep -q "app1.com" /etc/hosts; then
    echo "$HOSTS_LINE" >> /etc/hosts
fi
