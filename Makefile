# Makefile

# Image coordinates
PROJECT   := gollum-push
CONTAINER_REGISTRY  ?= registry.example.com   # your private registry hostname
NAMESPACE ?=                        # optional; leave empty if your registry doesn't require a namespace

# Resolve image name with optional namespace
IMAGE := $(CONTAINER_REGISTRY)$(if $(NAMESPACE),/$(NAMESPACE))/$(PROJECT)

.PHONY: docker dockerx docker-nocache push

docker:
	docker build -t $(IMAGE):latest .

dockerx:
	VERSION=$$(date +%Y%m%d%H%M); \
	docker buildx build --platform linux/amd64,linux/arm64 \
		-t $(IMAGE):$$VERSION -t $(IMAGE):latest \
		--push .

docker-nocache:
	docker build --no-cache -t $(IMAGE):latest .

push:
	VERSION=$$(date +%Y%m%d%H%M%S); \
	docker tag $(IMAGE):latest $(IMAGE):$$VERSION; \
	docker push $(IMAGE):$$VERSION; \
	docker push $(IMAGE):latest
