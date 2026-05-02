BINARY  := echo-api
PKG     := github.com/advanced-scaling/echo-api
GOFLAGS :=

.PHONY: build run test clean tidy

## build: compile the binary to ./echo-api
build:
	go build $(GOFLAGS) -o $(BINARY) .

## run: build then start the server (reads .env if present via export trick)
run: build
	@if [ -f .env ]; then \
		export $$(grep -v '^#' .env | xargs) && ./$(BINARY); \
	else \
		./$(BINARY); \
	fi

## test: run all unit tests with race detector
test:
	go test -race -v ./...

## tidy: tidy and verify the module graph
tidy:
	go mod tidy
	go mod verify

## clean: remove compiled artefacts
clean:
	rm -f $(BINARY)
