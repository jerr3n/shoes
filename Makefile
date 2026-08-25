VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
LDFLAGS := -X main.version=$(VERSION)

.PHONY: build build-go build-rojo version

build: build-go build-rojo

build-go:
	cd backend && go build -v -x -ldflags "$(LDFLAGS)" -o ../out/shoes .

build-rojo:
	cd roblox && rojo build -vvv --output ../out/shoes.rbxmx

version:
	@echo $(VERSION)
