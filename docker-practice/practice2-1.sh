

docker run -d --name loki --network observ-net -p 3100:3100 -v "$((Get-Location).Path)\loki-demo:/mnt/config" grafana/loki:3.4.1 --config.file=/mnt/config/loki-config.yaml

docker run -d --name promtail --network observ-net -v "$((Get-Location).Path)\loki-demo:/mnt/config" -v /var/run/docker.sock:/var/run/docker.sock grafana/promtail:3.4.1 --config.file=/mnt/config/promtail-docker.yaml

docker run -d --name grafana --network observ-net -p 3000:3000 -e GF_SECURITY_ADMIN_USER=admin -e GF_SECURITY_ADMIN_PASSWORD=admin grafana/grafana:latest