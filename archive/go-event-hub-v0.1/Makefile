.PHONY: build test vet run-embedded clean

build:
	go build -o ./bin/opendotnews ./cmd/opendotnews

test:
	go test -v ./...

vet:
	go vet ./...

run-embedded:
	go run ./examples/embedded

clean:
	rm -rf ./bin ./data
