# Build, lint e testes do init container.

IMAGE ?= ghcr.io/jfxdev/init-containers
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
SHELL_FILES := bin/init-containers lib/log.sh lib/run.sh lib/config.sh lib/perms.sh lib/clone.sh test/helper/common.bash tools/release-tag.sh

.DEFAULT_GOAL := help

.PHONY: help
help: ## Lista os targets disponíveis
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: lint
lint: ## Roda o shellcheck nos scripts
	shellcheck -x $(SHELL_FILES)

.PHONY: fmt
fmt: ## Formata os scripts com shfmt (se instalado)
	@command -v shfmt >/dev/null 2>&1 \
		|| { echo "shfmt não encontrado; pulando"; exit 0; }
	shfmt -i 2 -ci -w $(SHELL_FILES)

.PHONY: fmt-check
fmt-check: ## Verifica a formatação sem alterar arquivos
	@command -v shfmt >/dev/null 2>&1 \
		|| { echo "shfmt não encontrado; pulando"; exit 0; }
	shfmt -i 2 -ci -d $(SHELL_FILES)

.PHONY: validate-examples
validate-examples: ## Valida os exemplos de configuração contra o schema
	@for f in examples/*.json; do \
		./bin/init-containers --config "$$f" --dry-run >/dev/null \
			&& echo "ok   $$f" \
			|| { echo "FALHA $$f"; exit 1; }; \
	done

.PHONY: test
test: ## Roda a suíte bats no host
	bats test/

.PHONY: test-image
test-image: ## Roda a suíte bats dentro da imagem, contra os utilitários do busybox
	docker build --target test --build-arg VERSION=$(VERSION) -t $(IMAGE):test .

.PHONY: image
image: ## Constrói a imagem do init container
	docker build --target runtime --build-arg VERSION=$(VERSION) -t $(IMAGE):$(VERSION) .

.PHONY: check
check: lint fmt-check test validate-examples ## Roda tudo que não exige docker

.PHONY: tag
tag: ## Cria a tag de release do dia (sufixo .N automático se já existir)
	tools/release-tag.sh

.PHONY: next-tag
next-tag: ## Mostra a tag que o próximo release do dia usaria, sem criar nada
	@tools/release-tag.sh --print

.PHONY: clean
clean: ## Remove artefatos locais
	rm -rf dist
