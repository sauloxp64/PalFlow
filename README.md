🇺🇸 English version available here: [README.en.md](README.en.md)

# PalFlow

Planejador de breeding para Palworld. Ferramenta visual baseada em DAG que mapeia rotas otimizadas de breeding desde pals base capturados ate pals alvo.

Aplicacao estatica single-page (HTML/CSS/JS, zero dependencias) servida por uma stack Docker totalmente containerizada com TLS automatizado.

## Arquitetura

```
                    Browser
                      |
               HTTPS :443 / HTTP :80
                      |
              +-------+-------+
              |     edge      |   nginx reverse proxy
              | TLS termination|   (Cloudflare Origin / Let's Encrypt / self-signed)
              +-------+-------+
                      |
              HTTP (Docker internal)
                      |
              +-------+-------+
              |   palflow     |   nginx:alpine
              |  static site  |   index.html + /assets/icons/
              +---------------+

              +---------------+
              |   certbot     |   certbot/certbot
              | renewal loop  |   webroot challenge, every 12h
              +---------------+
```

**Com Cloudflare proxy (orange cloud ativado):**

```
Browser --> Cloudflare CDN --> edge :443 (CF Origin cert) --> palflow
```

O Cloudflare encerra a conexao TLS publica. O container edge utiliza um Cloudflare Origin Certificate para proteger o link entre o Cloudflare e o servidor de origem. Esse certificado nao e confiavel por navegadores por si so.

**Sem Cloudflare (DNS direto):**

```
Browser --> edge :443 (Let's Encrypt cert) --> palflow
```

O container edge utiliza um certificado Let's Encrypt confiavel por navegadores. O Certbot gerencia a emissao e renovacao automatica via ACME webroot challenge.

## Servicos

| Servico | Imagem | Funcao | Portas |
|---------|--------|--------|--------|
| `palflow` | nginx:alpine (custom) | Servidor do site estatico | Interna :80 apenas |
| `edge` | nginx:alpine (custom) | TLS termination + reverse proxy | 0.0.0.0:80, 0.0.0.0:443 |
| `certbot` | certbot/certbot | Loop de renovacao Let's Encrypt | Nenhuma |

O container edge faz bind em `0.0.0.0` (todas as interfaces) nas portas 80 e 443 porque e o ponto de entrada publico. A porta 80 precisa estar acessivel pela internet para ACME challenges e redirecionamentos HTTP-para-HTTPS. A porta 443 serve todo o trafego HTTPS. O container palflow nao possui portas publicadas — ele so e acessivel pelo edge via a rede interna do Docker.

## Requisitos

- Ubuntu 22.04+ (ou Linux compativel)
- Docker 24+
- Docker Compose v2+
- Um dominio com DNS apontando para o servidor
- Portas 80 e 443 abertas (firewall/security group)

### Firewall (UFW)

Se o UFW estiver habilitado no servidor, libere as portas necessarias:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw reload
```

Verifique:

```bash
sudo ufw status
```

## Instalacao do Docker (Ubuntu)

### Metodo A: Repositorio APT Oficial

Siga o guia oficial:
https://docs.docker.com/engine/install/ubuntu/

### Metodo B: Script Rapido (recomendado para setup rapido)

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
```

### Passos Pos-Instalacao

Adicione seu usuario ao grupo `docker` para executar Docker sem `sudo`:

```bash
sudo usermod -aG docker $USER
```

Faca logout e login novamente para a mudanca de grupo ter efeito, ou execute:

```bash
newgrp docker
```

Habilite o Docker para iniciar no boot:

```bash
sudo systemctl enable docker
```

Verifique a instalacao:

```bash
docker --version
docker compose version
```

Referencia: https://docs.docker.com/engine/install/linux-postinstall/

## Inicio Rapido

### 1. Clone e configure

```bash
git clone <repo-url> palflow
cd palflow
```

Copie o template de configuracao e edite com seus valores reais:

```bash
cp .env.example .env
```

Edite o `.env` com seu dominio e email:

```
PALFLOW_DOMAIN=palflow.seudominio.com
TLS_MODE=auto
ALLOW_SELF_SIGNED=0
LETSENCRYPT_EMAIL=seu-email@example.com
```

### 2. Bootstrap (primeiro deploy)

No primeiro deploy, nenhum certificado TLS existe ainda. O container edge precisa estar rodando na porta 80 para o certbot completar o ACME challenge. Use `ALLOW_SELF_SIGNED=1` para iniciar com um certificado self-signed temporario:

```bash
ALLOW_SELF_SIGNED=1 docker compose up -d --build
```

### 3. Emitir certificado Let's Encrypt

```bash
docker compose run --rm certbot certonly \
    --webroot -w /var/www/certbot \
    -d $PALFLOW_DOMAIN \
    --email $LETSENCRYPT_EMAIL \
    --agree-tos --no-eff-email
```

### 4. Reiniciar edge com certificado real

```bash
docker compose restart edge
```

O edge detectara o novo certificado Let's Encrypt e o utilizara automaticamente.

### 5. Verificar

```bash
curl -sI https://palflow.example.com | head -5
docker compose logs edge --no-log-prefix | grep "\[edge\]"
```

## Modos TLS

Defina `TLS_MODE` no `.env`:

| Modo | Comportamento |
|------|---------------|
| `auto` (padrao) | Usa certificado Cloudflare Origin se valido, senao Let's Encrypt se valido, senao falha |
| `cloudflare` | Exige certificado Cloudflare Origin. Sai com codigo 1 se ausente ou expirado |
| `letsencrypt` | Exige certificado Let's Encrypt. Fallback para self-signed apenas se `ALLOW_SELF_SIGNED=1` |

### Validacao de certificado

O entrypoint do edge verifica certificados na inicializacao usando:

```
openssl x509 -in <cert> -checkend 86400 -noout
```

Um certificado e considerado invalido se estiver ausente, ilegivel ou expirar em menos de 24 horas.

### ALLOW_SELF_SIGNED

| Valor | Comportamento |
|-------|---------------|
| `0` (padrao) | Edge sai com codigo 1 se nenhum certificado valido for encontrado. Exibe o comando exato para emitir um certificado. |
| `1` | Edge gera um certificado self-signed temporario (7 dias, RSA 2048) e inicia mesmo assim. |

**Mantenha `ALLOW_SELF_SIGNED=0` em producao.** O fallback self-signed existe exclusivamente para o bootstrap do primeiro deploy — o edge precisa estar rodando na porta 80 antes que o certbot consiga completar o ACME challenge. Apos a emissao de um certificado real, defina de volta para `0` para que o edge recuse iniciar se o certificado estiver ausente ou expirado, em vez de servir TLS nao confiavel silenciosamente.

## Certificado Cloudflare Origin

Se seu dominio esta com proxy pelo Cloudflare (orange cloud habilitado), use um Cloudflare Origin Certificate ao inves de Let's Encrypt.

### 1. Gerar no painel do Cloudflare

Acesse **SSL/TLS > Origin Server > Create Certificate** no painel do Cloudflare. Baixe o certificado e a chave privada no formato PEM.

### 2. Colocar no servidor

```bash
cp origin-cert.pem certs/cloudflare/fullchain.pem
cp origin-key.pem  certs/cloudflare/privkey.pem
```

### 3. Configurar e reiniciar

```
TLS_MODE=cloudflare
```

```bash
docker compose restart edge
```

## Renovacao de Certificado

O servico `certbot` executa um loop de renovacao a cada 12 horas. Quando um certificado e efetivamente renovado, o `--deploy-hook` do certbot toca um arquivo de flag. O container edge monitora esse arquivo a cada 5 segundos e recarrega o nginx quando detecta uma alteracao. Nao e necessario acesso ao Docker socket.

Mapeamento do arquivo de flag:

| Contexto | Caminho |
|----------|---------|
| Host | `./certs/letsencrypt/.reload-flag` |
| container certbot | `/etc/letsencrypt/.reload-flag` |
| container edge | `/etc/letsencrypt/.reload-flag` |

Ambos os containers montam `./certs/letsencrypt:/etc/letsencrypt`, portanto o arquivo de flag e o mesmo arquivo fisico acessado via volume compartilhado.

Isso acontece automaticamente sem intervencao manual.

## Variaveis de Ambiente

Todas as variaveis sao definidas no `.env`:

| Variavel | Padrao | Descricao |
|----------|--------|-----------|
| `PALFLOW_DOMAIN` | (obrigatorio) | Nome do dominio do site |
| `TLS_MODE` | `auto` | Selecao de certificado: `auto`, `cloudflare` ou `letsencrypt` |
| `ALLOW_SELF_SIGNED` | `0` | Defina como `1` para permitir fallback com certificado self-signed |
| `LETSENCRYPT_EMAIL` | (obrigatorio para LE) | Email para registro Let's Encrypt e avisos de expiracao. Obrigatorio ao usar `TLS_MODE=letsencrypt` ou quando o modo `auto` recorre ao Let's Encrypt |

## Estrutura do Projeto

```
palflow/
├── index.html                 # App PalFlow (arquivo unico, HTML/CSS/JS)
├── assets/icons/              # 225 PNGs de icones de Pals
├── Dockerfile                 # Servico palflow (nginx:alpine + arquivos estaticos)
├── nginx.conf                 # Config nginx interna do palflow
├── docker-compose.yml         # Stack de 3 servicos
├── .env                       # Dominio, modo TLS, flag self-signed
├── .dockerignore              # Exclusoes do contexto de build
├── edge/
│   ├── Dockerfile             # Servico edge (nginx:alpine + openssl)
│   ├── entrypoint.sh          # Selecao de cert + render de template + exec nginx
│   └── nginx.template.conf    # Template de config nginx (envsubst)
├── certbot/
│   └── renew.sh               # Loop de renovacao (a cada 12h, deploy-hook)
├── certs/
│   ├── cloudflare/            # Cert CF Origin colocado pelo usuario (fullchain.pem, privkey.pem)
│   └── letsencrypt/           # Certs LE gerenciados pelo Certbot (preenchido automaticamente)
└── acme-webroot/              # Volume compartilhado para arquivos ACME challenge
```

## Comandos

### Iniciar / rebuild

```bash
docker compose up -d --build
```

### Parar

```bash
docker compose down
```

### Ver logs

```bash
docker compose logs edge certbot        # logs do edge + certbot
docker compose logs palflow             # logs do container app
docker compose logs -f edge             # acompanhar logs do edge
```

### Verificar status

```bash
docker compose ps
```

### Reiniciar edge apos mudanca de certificado

```bash
docker compose restart edge
```

### Emitir certificado Let's Encrypt (primeira vez)

```bash
docker compose run --rm certbot certonly \
    --webroot -w /var/www/certbot \
    -d $PALFLOW_DOMAIN \
    --email $LETSENCRYPT_EMAIL \
    --agree-tos --no-eff-email
```

### Forcar renovacao de certificado (teste)

```bash
docker compose run --rm certbot renew --force-renewal \
    --webroot -w /var/www/certbot \
    --deploy-hook "touch /etc/letsencrypt/.reload-flag"
```

## Atualizacao

Apos puxar as mudancas do repositorio:

```bash
git pull
docker compose up -d --build
```

Isso reconstroi as imagens `palflow` e `edge` a partir de seus Dockerfiles e reinicia apenas os containers cujas imagens mudaram. O servico `certbot` usa a imagem upstream `certbot/certbot` e nao e reconstruido — o Docker baixara uma versao mais nova no proximo `docker compose pull`.

Para atualizar todas as imagens incluindo o certbot:

```bash
git pull
docker compose pull
docker compose up -d --build
```

Certificados, volumes e configuracao do `.env` sao preservados entre atualizacoes.

## Solucao de Problemas

### Edge reinicia em loop na inicializacao

Esperado quando `ALLOW_SELF_SIGNED=0` e nenhum certificado valido existe. Verifique os logs:

```bash
docker compose logs edge
```

O log exibira o comando exato do certbot a ser executado.

### Portas 80/443 ja em uso

Pare qualquer servidor web existente no host:

```bash
sudo systemctl stop nginx apache2 2>/dev/null
```

### ACME challenge do Certbot falha

Certifique-se de que o DNS do seu dominio aponta para o servidor e que a porta 80 esta acessivel pela internet. O container edge precisa estar rodando (use `ALLOW_SELF_SIGNED=1` para bootstrap).

### Certificado nao atualiza apos renovacao

O container edge monitora `certs/letsencrypt/.reload-flag` a cada 5 segundos. Se o reload nao acontecer, reinicie o edge manualmente:

```bash
docker compose restart edge
```
