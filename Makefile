
MISE := $(HOME)/.local/bin/mise
TUIST := $(MISE) exec -- tuist
SWIFTLINT := $(MISE) exec -- swiftlint
SWIFTFORMAT := $(MISE) exec -- swiftformat
MAC_DERIVED_DATA := $(CURDIR)/.build/JingoMacDerivedData
MAC_APP := $(MAC_DERIVED_DATA)/Build/Products/Debug/Jingo.app

all: bootstrap project_file

bootstrap:
	command -v $(MISE) >/dev/null 2>&1 || curl https://mise.jdx.dev/install.sh | sh
	$(MISE) install

project_file: secrets
	$(TUIST) install
	$(TUIST) generate --no-open

update: secrets
	$(TUIST) install --update
	$(TUIST) generate --no-open

appstore: secrets
	TUIST_IS_APP_STORE=1 $(TUIST) install
	TUIST_IS_APP_STORE=1 $(TUIST) generate --no-open

project_cache_warmup:
	$(TUIST) cache Common AudioProcessing JingoKit --external-only
	$(TUIST) generate -n

build_dev_debug:
	$(TUIST) build --configuration Debug --build-output-path .build/ JingoDev

build_dev_release:
	$(TUIST) build --configuration Release --build-output-path .build/ JingoDev

build_mac_debug:
	xcodebuild -workspace Jingo.xcworkspace -scheme JingoMac -configuration Debug -destination 'platform=macOS' -derivedDataPath "$(MAC_DERIVED_DATA)" build

run_mac: build_mac_debug
	@terminated_pids=""; \
	for pid in $$(pgrep -x Jingo 2>/dev/null || true); do \
		kill "$$pid"; \
		terminated_pids="$$terminated_pids $$pid"; \
	done; \
	for pid in $$terminated_pids; do \
		attempts=0; \
		while kill -0 "$$pid" 2>/dev/null; do \
			attempts=$$((attempts + 1)); \
			if [ "$$attempts" -ge 50 ]; then \
				echo "Jingo did not stop within 5 seconds; launch cancelled." >&2; \
				exit 1; \
			fi; \
			sleep 0.1; \
		done; \
	done; \
	open "$(MAC_APP)"

format:
	$(SWIFTLINT) lint --force-exclude --fix .
	$(SWIFTFORMAT) . --config .swiftformat

secrets:
	sh ./ci_scripts/secrets.sh

build_dev_server:
	xcode-build-server config -workspace Jingo.xcworkspace -scheme JingoDev || echo "consult https://github.com/SolaWing/xcode-build-server for vscode support"

build_server:
	xcode-build-server config -workspace Jingo.xcworkspace -scheme Jingo || echo "consult https://github.com/SolaWing/xcode-build-server for vscode support"

analyze:
	sh ./ci_scripts/cpd_run.sh && echo "CPD done"
	periphery scan > periphery.log && echo "Periphery done"
	xcodebuild -workspace Jingo.xcworkspace -scheme JingoDev -configuration Debug build CODE_SIGNING_ALLOWED="NO" ENABLE_BITCODE="NO" > xcodebuild.log && echo "Xcodebuild done"
	swiftlint analyze --compiler-log-path xcodebuild.log > swiftlint_analyze.log && echo "Swiftlint done"

clear_analyze:
	rm -f periphery.log
	rm -f xcodebuild.log
	rm -f swiftlint_analyze.log
	rm -f cpd-output.xml
	
clean: clear_analyze
	rm -rf build
	$(TUIST) clean

.SILENT: all project_file update hot appstore hot_appstore build_debug build_release build_mac_debug run_mac format secrets
