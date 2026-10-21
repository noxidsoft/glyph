.PHONY: build test lint clean skill

build:
	go build -o bin/glyph ./cmd/glyph

test:
	go test ./...

# Regenerate the agent skill from the built binary. SKILL_DIR overrides the
# destination (default: the user-level Claude Code skill directory).
SKILL_DIR ?= $(HOME)/.claude/skills/glyph
skill: build
	@mkdir -p $(SKILL_DIR)
	@./bin/glyph skill > $(SKILL_DIR)/SKILL.md
	@echo "wrote $(SKILL_DIR)/SKILL.md"

lint:
	go vet ./...

clean:
	rm -rf bin
