.PHONY: test build setup install clean

test:
	./scripts/test.sh

build:
	./scripts/build-app.sh

setup:
	./scripts/setup-whisper.sh large-v3-q5_0

install:
	./scripts/install.sh

clean:
	swift package clean
