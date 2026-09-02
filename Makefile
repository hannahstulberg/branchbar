# BranchBar — single command vocabulary shared by the orchestrator, subagents, and CI.
VERSION    := $(shell tr -d '[:space:]' < VERSION)
APP        := dist/BranchBar.app
ZIP        := dist/BranchBar-$(VERSION)-mac.zip
LOG        := $(HOME)/Library/Logs/BranchBar/BranchBar.log
TEST_FLAGS ?= --disable-xctest --enable-swift-testing
ARCHS      ?= arm64

.PHONY: test build release bundle zip run stop logs screenshot install verify record-fixtures doc-refs doc-strings snapshot clean

test:            ## unit tests for BranchBarCore (Swift Testing only)
	swift test $(TEST_FLAGS)

build:           ## debug build, host arch
	swift build --product BranchBar

release:         ## release bundle; ARCHS="arm64 x86_64" for universal
	ARCHS="$(ARCHS)" scripts/bundle.sh

bundle: release

zip: bundle
	rm -f $(ZIP) $(ZIP).sha256
	ditto -c -k --sequesterRsrc --keepParent $(APP) $(ZIP)
	shasum -a 256 $(ZIP) > $(ZIP).sha256

run: stop        ## rebuild (arm64) and launch the bundled app
	ARCHS=arm64 scripts/bundle.sh
	open $(APP)

stop:
	-pkill -x BranchBar

logs:
	tail -n 50 -f $(LOG)

screenshot:      ## menu bar strip + popover into dist/screens/
	scripts/screenshot.sh

install: bundle  ## copy to /Applications (login-item and Gatekeeper rehearsals need this path)
	rm -rf /Applications/BranchBar.app && ditto $(APP) /Applications/BranchBar.app

verify:          ## what CI checks before publishing
	codesign --verify --strict --verbose=2 $(APP)
	lipo -info $(APP)/Contents/MacOS/BranchBar
	plutil -p $(APP)/Contents/Info.plist | grep -E 'LSUIElement|CFBundleShortVersionString|LSMinimumSystemVersion'

record-fixtures: ## re-run every frozen git/gh invocation against real repos; rewrites Tests/BranchBarCoreTests/Fixtures/recorded-*
	scripts/record-fixtures.sh

doc-refs:        ## fail if any ARCHITECTURE.md file:line no longer points at its symbol
	scripts/doc-refs.sh

doc-strings:     ## regenerate docs/UI-CONTRACT.md string table from Sources/BranchBarCore/Strings.swift
	scripts/doc-strings.sh

snapshot:        ## Gate 3 harness: print every repo, branch, worktree, PR, and push for ROOTS with Apple git
	swift run -c release branchbar-cli snapshot $(foreach r,$(ROOTS),--root $(r)) --git $(or $(BRANCHBAR_GIT),/usr/bin/git)

clean:
	rm -rf .build dist
