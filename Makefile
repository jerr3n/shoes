VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
LDFLAGS := -X main.version=$(VERSION)
PLATFORMS := linux-amd64 linux-arm64 darwin-amd64 darwin-arm64 windows-amd64 windows-arm64
PLAT_TARGETS := $(addprefix build-plat-,$(PLATFORMS))

.PHONY: build build-go build-rojo version build-crossplatform $(PLAT_TARGETS) out

build:	build-go build-rojo

build-go:
	cd backend && go build -v -x -ldflags "$(LDFLAGS)" -o ../out/backend

build-rojo:
	cd roblox && rojo build -vvv --output ../out/shoes.rbxmx

$(PLAT_TARGETS): build-plat-%: | out
	GOOS=$(word 1,$(subst -, ,$*)) GOARCH=$(word 2,$(subst -, ,$*)) \
		go build -C backend -v -x -ldflags "$(LDFLAGS)" \
		-o $(CURDIR)/out/$*$(if $(filter windows-%,$*),.exe) .

out:
	mkdir -p out

build-crossplatform: $(PLAT_TARGETS)

version:
	@echo $(VERSION)
