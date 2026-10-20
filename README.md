# init-containers

Init container que prepara volumes antes do container principal subir: clona
uma lista de repositórios git nos diretórios pedidos e ajusta owner/group/modo
de diretórios e arquivos, lendo tudo de um arquivo JSON montado como volume.

Implementado em bash sobre `git` e `jq`, sem código compilado: o que o init
container faz cabe numa leitura do script.

```
ConfigMap ──montado──> /etc/init-containers/config.json
                              │
                       init-containers
                              │
          ┌───────────────────┴───────────────────┐
          ▼                                       ▼
   git clone / sync                        chown + chmod
   (em paralelo)                           (após os clones)
          └───────────────────┬───────────────────┘
                              ▼
                    volume pronto para o container principal
```

## Uso em Kubernetes

A configuração vai num ConfigMap e o volume de trabalho é compartilhado entre o
init container e o container principal:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: init-containers-config
data:
  config.json: |
    {
      "apiVersion": "init-containers/v1",
      "defaults": { "owner": 1000, "group": 1000 },
      "auth": {
        "github": { "tokenEnv": "GITHUB_TOKEN" }
      },
      "repositories": [
        { "url": "https://github.com/exemplo/app.git",
          "path": "/workspace/app", "ref": "main", "depth": 1 }
      ],
      "permissions": [
        { "path": "/workspace/app", "dirMode": "0755", "fileMode": "0644",
          "recursive": true }
      ]
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: exemplo
spec:
  initContainers:
    - name: init
      image: ghcr.io/jfxdev/init-containers:latest
      # chown exige uid 0; o container principal segue non-root.
      securityContext:
        runAsUser: 0
      env:
        - name: GITHUB_TOKEN
          valueFrom:
            secretKeyRef: { name: git-credentials, key: token }
      volumeMounts:
        - { name: config, mountPath: /etc/init-containers, readOnly: true }
        - { name: workspace, mountPath: /workspace }
  containers:
    - name: app
      image: exemplo/app:latest
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
      volumeMounts:
        - { name: workspace, mountPath: /workspace }
  volumes:
    - name: config
      configMap:
        name: init-containers-config
    - name: workspace
      emptyDir: {}
```

Para rodar fora do cluster:

```bash
init-containers --config ./config.json           # aplica
init-containers --config ./config.json --dry-run # só mostra o plano
```

## Configuração

O caminho padrão é `/etc/init-containers/config.json`, sobrescrito por
`--config` ou pela variável `INITC_CONFIG`. `examples/init-config.json` traz
todos os campos preenchidos; `examples/init-config.minimal.json`, o mínimo.

### Raiz

| Campo          | Tipo   | Descrição |
| -------------- | ------ | --------- |
| `apiVersion`   | string | Obrigatório, `"init-containers/v1"`. |
| `defaults`     | objeto | Valores aplicados a toda entrada que não traga o campo. |
| `auth`         | objeto | Blocos de credenciais, referenciados por nome. |
| `repositories` | lista  | Repositórios a clonar. |
| `permissions`  | lista  | Ajustes de permissão. |

Campos desconhecidos são erro, não aviso: num ConfigMap montado, um typo em
`recursive` passaria silenciosamente sem aplicar nada.

### `defaults`

| Campo         | Tipo          | Padrão | Descrição |
| ------------- | ------------- | ------ | --------- |
| `owner`       | int ou string | —      | uid ou nome de usuário. |
| `group`       | int ou string | —      | gid ou nome de grupo. |
| `mode`        | string octal  | —      | Modo padrão. |
| `auth`        | string        | —      | Bloco de `auth` usado pelos repositórios. |
| `concurrency` | int ≥ 1       | `4`    | Clones simultâneos. |

### `auth`

| Campo       | Tipo   | Padrão            | Descrição |
| ----------- | ------ | ----------------- | --------- |
| `type`      | string | `https`           | Único valor suportado nesta versão. |
| `username`  | string | `x-access-token`  | Usuário do basic auth. Use `oauth2` no GitLab. |
| `tokenEnv`  | string | —                 | Variável de ambiente com o token. |
| `tokenFile` | string | —                 | Arquivo com o token, ex.: um Secret montado. |

`tokenEnv` e `tokenFile` são mutuamente exclusivos, e um dos dois é obrigatório.
O token nunca vai no JSON: a configuração costuma ser um ConfigMap, não um
Secret.

O token é entregue ao git por um helper de `GIT_ASKPASS`, lido de um arquivo
`0600` criado e removido a cada invocação. Ele não aparece na linha de comando
(visível em `ps`), não é embutido na URL (que vazaria em `.git/config` e nos
logs do servidor remoto) e é redigido das mensagens de erro.

### `repositories[]`

| Campo        | Tipo          | Padrão | Descrição |
| ------------ | ------------- | ------ | --------- |
| `url`        | string        | —      | Obrigatório. `http`, `https` ou `file`. Sem credenciais embutidas. |
| `path`       | string        | —      | Obrigatório. Destino absoluto. |
| `ref`        | string        | HEAD   | Branch, tag ou SHA. Resolvido via `ls-remote`. |
| `depth`      | int ≥ 0       | `0`    | `0` = histórico completo. Ignorado quando `ref` é um SHA. |
| `submodules` | bool          | `false`| Inicializa submódulos recursivamente. |
| `auth`       | string        | herda  | Nome de um bloco `auth`, ou `none` para clone anônimo. |
| `optional`   | bool          | `false`| Falha vira aviso e não afeta o código de saída. |
| `force`      | bool          | `false`| Permite sobrescrever um destino ocupado. |
| `owner`      | int ou string | herda  | Aplicado recursivamente à árvore clonada. |
| `group`      | int ou string | herda  | Aplicado recursivamente à árvore clonada. |
| `mode`       | string octal  | herda  | Aplicado **somente ao diretório de destino**. |

`owner`/`group` descem na árvore inteira, para que o container principal possa
escrever. `mode`, não: aplicá-lo a cada arquivo mudaria o bit de execução e o
git passaria a ver a árvore toda como modificada. Para modos por arquivo, use
uma entrada de `permissions` com `dirMode`/`fileMode`.

URLs SSH (`git@host:org/repo.git`) são rejeitadas com mensagem explícita — esta
versão só fala HTTPS.

### `permissions[]`

| Campo       | Tipo          | Padrão  | Descrição |
| ----------- | ------------- | ------- | --------- |
| `path`      | string        | —       | Obrigatório. Diretório ou arquivo, absoluto. |
| `owner`     | int ou string | herda   | uid ou nome de usuário. |
| `group`     | int ou string | herda   | gid ou nome de grupo. |
| `mode`      | string octal  | herda   | Modo aplicado a tudo que a entrada alcança. |
| `dirMode`   | string octal  | —       | Modo dos diretórios. Exige `recursive`. |
| `fileMode`  | string octal  | —       | Modo dos arquivos. Exige `recursive`. |
| `recursive` | bool          | `false` | Desce na árvore. |
| `optional`  | bool          | `false` | Falha vira aviso e não afeta o código de saída. |

`mode` é mutuamente exclusivo com `dirMode`/`fileMode`. Modos são sempre
**string octal entre quotes** (`"0755"`): JSON não aceita literais octais, e
`755` sem quotes seria o decimal 755.

Symlinks nunca são seguidos: `chown` usa `-h` e o `chmod` recursivo pula
symlinks, para que um link dentro de um repositório clonado não faça o init
container alterar permissões fora do volume.

As permissões rodam depois dos clones, para poderem cobrir as árvores
recém-clonadas, e rodam mesmo se um clone falhou: um volume com dono certo e um
repositório faltando é mais fácil de diagnosticar que os dois errados.

## Idempotência

Init containers reiniciam junto com o Pod, então estado parcial de uma execução
anterior é esperado e não pode virar erro. Para cada repositório:

| Estado do destino                  | Comportamento |
| ---------------------------------- | ------------- |
| Ausente                            | Clona num diretório temporário irmão e move para o destino — nunca um clone meio feito no lugar final. |
| Diretório vazio                    | Clona normalmente (cobre um `subPath` montado). |
| Repositório do mesmo remoto        | `fetch`, reset no ref e `clean`: descarta edições locais e arquivos não rastreados. |
| Repositório de outro remoto        | Erro, a menos que `force: true`. |
| Ocupado por dados que não são git  | Erro, a menos que `force: true`. |

`force: true` apaga dados. Por isso nada é destruído sem ele.

Quando `ref` é um branch, o HEAD fica no branch em vez de detached, para que o
volume se pareça com um checkout normal.

## Códigos de saída

| Código | Significado |
| ------ | ----------- |
| `0`    | Tudo aplicado (ou nada a fazer). |
| `1`    | Configuração ausente, ilegível ou inválida. |
| `2`    | Uma ou mais tarefas obrigatórias falharam. |

A validação acumula todos os problemas e os reporta de uma vez: num init
container, cada tentativa custa um restart do Pod.

## Linha de comando

```
-c, --config CAMINHO    arquivo de configuração JSON
    --dry-run           imprime o plano efetivo sem alterar nada
    --log-format FORMA  text (padrão) ou json
    --log-level NÍVEL   debug, info (padrão), warn ou error
-V, --version           versão
-h, --help              ajuda
```

`--dry-run` mostra a configuração já com os defaults resolvidos e não contata os
repositórios remotos. Credenciais ausentes e caminhos que ainda não existem
viram aviso, não erro — a ideia é conferir o plano, não o estado do volume.

`--log-format json` emite uma linha JSON por evento, com `ts`, `level`, `msg` e
os campos estruturados.

## Desenvolvimento

```bash
make help              # lista os targets
make check             # lint + formatação + testes + validação dos exemplos
make test              # suíte bats no host
make test-image        # suíte bats dentro da imagem, contra o busybox
make image             # constrói a imagem
```

Dependências de desenvolvimento: `bats`, `shellcheck`, `jq`, `git` e, opcional,
`shfmt` — o CI usa a v3.14.1, e versões diferentes do formatador podem divergir
no `fmt-check`.

Não há toolchain Go envolvida: o `shfmt` do CI vem do binário da release.

Os testes rodam contra repositórios bare locais via `file://`, sem rede.

### Organização

```
bin/init-containers   entrypoint: flags, orquestração, códigos de saída
lib/config.sh         carga da configuração; delega validação e defaults ao jq
lib/jq/defs.jq        definições compartilhadas pelos programas jq
lib/jq/validate.jq    toda a validação, num só lugar
lib/jq/normalize.jq   aplica defaults e normaliza paths
lib/clone.sh          clone, re-sync e credenciais
lib/perms.sh          chown e chmod
lib/log.sh            logging em texto ou JSON
lib/run.sh            execução de comandos, com suporte a dry-run
```

A configuração é validada e depois normalizada para uma forma em que todo campo
existe com tipo previsível. O shell lê essa forma normalizada, então a lógica de
defaults não é repetida entre jq e bash.

## Limitações desta versão

- Apenas autenticação HTTPS com token. SSH e GitHub App ainda não.
- Entradas de `permissions` não criam diretórios ausentes nem aceitam globs.
- Sem git-lfs, sparse-checkout ou cache de repositórios.
- Sem Helm chart; o exemplo de Pod acima é o ponto de partida.
