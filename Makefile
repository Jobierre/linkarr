# Linkarr - Hard Link Checker for Sonarr/Radarr
# Verifies that media files are properly hard-linked between downloads and media directories

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Directories
SCRIPTS_DIR := scripts
REPORTS_DIR := reports

# Scripts
CHECK_SCRIPT := $(SCRIPTS_DIR)/check-hardlinks.sh

# Make scripts executable
.PHONY: init
init: ## Initialize project (make scripts executable, create config)
	@chmod +x $(SCRIPTS_DIR)/*.sh
	@if [ ! -f config.env ]; then \
		cp config.env.example config.env; \
		echo "Created config.env from template"; \
		echo "Please edit config.env with your API keys and paths"; \
	else \
		echo "config.env already exists"; \
	fi
	@mkdir -p $(REPORTS_DIR)
	@echo "Initialization complete"

# Dependencies check
.PHONY: deps
deps: ## Check for required dependencies
	@echo "Checking dependencies..."
	@command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required"; exit 1; }
	@command -v stat >/dev/null 2>&1 || { echo "ERROR: stat is required"; exit 1; }
	@command -v find >/dev/null 2>&1 || { echo "ERROR: find is required"; exit 1; }
	@echo "All dependencies are installed"

# API connectivity test
.PHONY: test-api
test-api: deps ## Test API connectivity to Sonarr and Radarr
	@$(CHECK_SCRIPT) test-api

# Main check targets
.PHONY: check
check: deps ## Check all hard links (movies + TV shows)
	@$(CHECK_SCRIPT) all

.PHONY: check-movies
check-movies: deps ## Check only movie hard links (via Radarr)
	@$(CHECK_SCRIPT) movies

.PHONY: check-tv
check-tv: deps ## Check only TV show hard links (via Sonarr)
	@$(CHECK_SCRIPT) tv

# Filesystem-only checks (no API)
.PHONY: check-movies-fs
check-movies-fs: deps ## Check movie hard links (filesystem scan, no API)
	@$(CHECK_SCRIPT) movies-fs

.PHONY: check-tv-fs
check-tv-fs: deps ## Check TV hard links (filesystem scan, no API)
	@$(CHECK_SCRIPT) tv-fs

# Report targets
.PHONY: report
report: check ## Generate a full report (runs check first)
	@echo ""
	@echo "Report files saved in $(REPORTS_DIR)/"
	@ls -lt $(REPORTS_DIR)/*.txt 2>/dev/null | head -5 || true

.PHONY: fix-suggestions
fix-suggestions: ## Display fix suggestions from the last report
	@echo "#!/bin/bash"
	@echo "# Hard link fix suggestions"
	@echo "# Review each command before executing!"
	@echo ""
	@if [ -d $(REPORTS_DIR) ]; then \
		latest=$$(ls -t $(REPORTS_DIR)/suggestions_*.txt 2>/dev/null | head -1); \
		if [ -n "$$latest" ] && [ -s "$$latest" ]; then \
			cat "$$latest"; \
		else \
			echo "# No suggestions available. Run 'make check' first."; \
		fi \
	else \
		echo "# No reports directory. Run 'make check' first."; \
	fi

.PHONY: show-problems
show-problems: ## Display problems from the last report
	@if [ -d $(REPORTS_DIR) ]; then \
		latest=$$(ls -t $(REPORTS_DIR)/problems_*.txt 2>/dev/null | head -1); \
		if [ -n "$$latest" ] && [ -s "$$latest" ]; then \
			cat "$$latest"; \
		else \
			echo "No problems found or no report available. Run 'make check' first."; \
		fi \
	else \
		echo "No reports directory. Run 'make check' first."; \
	fi

# Verbose mode
.PHONY: check-verbose
check-verbose: deps ## Run check with verbose output
	@VERBOSE=true $(CHECK_SCRIPT) all

# Cleanup
.PHONY: clean
clean: ## Remove old reports (keeps last 5)
	@if [ -d $(REPORTS_DIR) ]; then \
		echo "Cleaning old reports..."; \
		cd $(REPORTS_DIR) && ls -t problems_*.txt 2>/dev/null | tail -n +6 | xargs -r rm -f; \
		cd $(REPORTS_DIR) && ls -t suggestions_*.txt 2>/dev/null | tail -n +6 | xargs -r rm -f; \
		cd $(REPORTS_DIR) && ls -t report_*.json 2>/dev/null | tail -n +6 | xargs -r rm -f; \
		echo "Done"; \
	fi

.PHONY: clean-all
clean-all: ## Remove all reports
	@rm -rf $(REPORTS_DIR)/*
	@echo "All reports removed"

# Help
.PHONY: help
help: ## Show this help message
	@echo "Linkarr - Hard Link Checker for Sonarr/Radarr"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Quick start:"
	@echo "  1. make init          # Create config file"
	@echo "  2. Edit config.env    # Add your API keys"
	@echo "  3. make test-api      # Verify connectivity"
	@echo "  4. make check         # Run the check"
