# Formatting and checks to run before opening a pull request.
#
#   make format   rewrite files so `make check` passes
#   make check    verify formatting, generated files and static analysis
#   make test     run the unit and widget tests
#   make pr       check + test: the full gate before a pull request
#
# Uses the Flutter SDK pinned in .fvmrc (see scripts/flutter-sdk.sh).

FLUTTER := scripts/flutter.sh
DART := .fvm/flutter_sdk/bin/dart

DART_DIRS := lib test integration_test scripts tool

# Plugin registrants Flutter rewrites on `pub get`; they are committed, so
# they must match what the pinned SDK generates.
GENERATED := \
	macos/Flutter/GeneratedPluginRegistrant.swift \
	windows/flutter/generated_plugin_registrant.cc \
	windows/flutter/generated_plugin_registrant.h \
	windows/flutter/generated_plugins.cmake

.PHONY: help format check check-format check-generated analyze test pr

help:
	@sed -n '3,6p' Makefile | sed 's/^# *//'

# `pub get` goes first: it installs the SDK if needed and regenerates the
# plugin registrants.
format:
	$(FLUTTER) pub get
	$(DART) format $(DART_DIRS)

check: check-generated check-format analyze

check-format:
	$(DART) format --output=none --set-exit-if-changed $(DART_DIRS)

check-generated:
	$(FLUTTER) pub get
	@git diff --exit-code --stat -- $(GENERATED) || { \
		echo "error: generated plugin files are stale; run 'make format' and commit them" >&2; \
		exit 1; \
	}

analyze:
	$(FLUTTER) analyze

test:
	$(FLUTTER) test

pr: check test
