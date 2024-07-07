# Create the builder
docker buildx create --platform linux/amd64,linux/arm64 --driver docker-container --name multi-builder

docker buildx build -f practice-extra1.dockerfile --builder multi-builder --platform linux/amd64,linux/arm64  -t matenduel/cloudwave_test:v2 --push .
