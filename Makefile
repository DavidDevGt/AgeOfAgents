# Makefile — Gulag Arena
# Usage: make [target]
#
# Targets:
#   build         Build server binary for the current platform
#   build-all     Cross-compile for Linux, macOS, and Windows (amd64)
#   test          Run Go tests
#   test-race     Run Go tests with race detector
#   lint          Run golangci-lint (requires golangci-lint in PATH)
#   package       Package the LÖVE client as dist/gulag-arena.love
#   run           Build and start the server locally (1v1, debug)
#   clean         Remove the dist/ directory

BINARY     := server
DIST       := dist
BACKEND    := ./backend
CMD        := $(BACKEND)/cmd/server
LOVE_SRC   := main.lua conf.lua src
LOVE_OUT   := $(DIST)/gulag-arena.love
VERSION    := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
LDFLAGS    := -ldflags="-s -w -X main.version=$(VERSION)"

# Default target
.PHONY: all
all: test build package

# ── Backend ──────────────────────────────────────────────────────────────────

.PHONY: build
build: $(DIST)
	cd $(BACKEND) && go build $(LDFLAGS) -o ../$(DIST)/$(BINARY) ./cmd/server

.PHONY: build-all
build-all: $(DIST)
	GOOS=linux   GOARCH=amd64 cd $(BACKEND) && go build $(LDFLAGS) -o ../$(DIST)/$(BINARY)-linux-amd64 ./cmd/server
	GOOS=darwin  GOARCH=amd64 cd $(BACKEND) && go build $(LDFLAGS) -o ../$(DIST)/$(BINARY)-darwin-amd64 ./cmd/server
	GOOS=windows GOARCH=amd64 cd $(BACKEND) && go build $(LDFLAGS) -o ../$(DIST)/$(BINARY)-windows-amd64.exe ./cmd/server
	cd $(DIST) && sha256sum $(BINARY)-* > checksums.txt

.PHONY: test
test:
	cd $(BACKEND) && go test ./...

.PHONY: test-race
test-race:
	cd $(BACKEND) && go test -race ./...

.PHONY: lint
lint:
	cd $(BACKEND) && golangci-lint run ./...

# ── Client ────────────────────────────────────────────────────────────────────

.PHONY: package
package: $(DIST)
	zip -r $(LOVE_OUT) $(LOVE_SRC) main.lua conf.lua
	@echo "Client packaged: $(LOVE_OUT)"

# ── Local run ─────────────────────────────────────────────────────────────────

.PHONY: run
run: build
	$(DIST)/$(BINARY) -debug

# ── Utility ───────────────────────────────────────────────────────────────────

$(DIST):
	mkdir -p $(DIST)

.PHONY: clean
clean:
	rm -rf $(DIST)

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'
