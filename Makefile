# Formatting and checks to run before opening a pull request, and the
# builds of each platform.
#
#   make format   rewrite files so `make check` passes
#   make check    verify formatting and lints
#   make test     run the unit tests and the headless flows
#   make pr       check + test: the full gate before a pull request
#
#   make mac      build/Listenook-<arch>-debug.app
#   make ios      an unsigned iOS build, to check that it compiles
#   make android  a debug-signed .apk
#   (Windows: scripts\build-windows.ps1 debug on a Windows machine)
#
# Releases: scripts/publish.sh --help.

CARGO := cargo

.PHONY: help format check check-format lint test pr mac ios android

help:
	@sed -n '4,14p' Makefile | sed 's/^# *//'

format:
	$(CARGO) fmt

check: check-format lint

check-format:
	$(CARGO) fmt --check

lint:
	$(CARGO) clippy --workspace --all-targets -- -D warnings

test:
	$(CARGO) test --workspace

pr: check test

mac:
	scripts/build-macos.sh debug

ios:
	scripts/build-ios.sh debug

android:
	scripts/build-android.sh debug
