#!/bin/bash
# Instalador do animus-os: liga o Mac de uma pessoa nova ao vault da AnimusPay.
# Uso (no Terminal):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/animus-ia/instalador/main/instalar.sh)"
# Pode rodar de novo quantas vezes quiser: o que já está pronto é pulado.
# Não guarda nem pede senha: o login no GitHub é feito no navegador.

set -u

ORG="animus-ia"
REPO="animus-os"
MARKETPLACE="animus-ia/animus-plugins"
VAULT="$HOME/IA/$REPO"
BIN="$HOME/.local/bin"
SCRIPT="$HOME/Scripts/$REPO-sync.sh"
LABEL="com.animus.$REPO-sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$REPO-sync.log"

passo() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()    { printf '  ✓ %s\n' "$1"; }
falha() { printf '\n\033[31mParou aqui:\033[0m %s\n' "$1"; printf 'Mande um print desta tela para quem te convidou.\n'; exit 1; }

[ "$(uname)" = "Darwin" ] || falha "este instalador é para Mac."
export PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# 1. Git (vem com as Ferramentas de Linha de Comando da Apple)
passo "1/5 · Git"
if xcode-select -p >/dev/null 2>&1 && /usr/bin/git --version >/dev/null 2>&1; then
  ok "já instalado"
else
  printf '  Vai abrir uma janela da Apple: clique em "Instalar" e aguarde terminar.\n'
  xcode-select --install >/dev/null 2>&1
  espera=0
  until xcode-select -p >/dev/null 2>&1 && /usr/bin/git --version >/dev/null 2>&1; do
    sleep 10; espera=$((espera+10))
    [ $espera -ge 1800 ] && falha "o git não terminou de instalar em 30 minutos. Rode o comando de novo depois que a instalação da Apple acabar."
  done
  ok "instalado"
fi

# 2. GitHub CLI (gh), sem precisar de Homebrew nem de senha do Mac
passo "2/5 · Ferramenta do GitHub"
if command -v gh >/dev/null 2>&1; then
  ok "já instalada"
else
  arq="amd64"; [ "$(uname -m)" = "arm64" ] && arq="arm64"
  url=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
        | grep -o "https://[^\"]*_macOS_${arq}\.zip" | head -1)
  [ -n "$url" ] || falha "não achei o download da ferramenta do GitHub. Confira a internet e rode de novo."
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/gh.zip" || falha "o download da ferramenta do GitHub não terminou."
  unzip -q "$tmp/gh.zip" -d "$tmp" || falha "não consegui abrir o arquivo da ferramenta do GitHub."
  mkdir -p "$BIN"
  cp "$(find "$tmp" -type f -path '*/bin/gh' | head -1)" "$BIN/gh" && chmod +x "$BIN/gh"
  rm -rf "$tmp"
  command -v gh >/dev/null 2>&1 || falha "a ferramenta do GitHub não ficou instalada."
  ok "instalada em $BIN"
fi

# 3. Login no GitHub (pelo navegador)
passo "3/5 · Login no GitHub"
if gh auth status -h github.com >/dev/null 2>&1; then
  ok "já conectado como $(gh api user --jq .login)"
else
  printf '  Vai aparecer um código de 8 letras. Aperte Enter, cole o código no navegador e autorize.\n'
  gh auth login -h github.com -p https -w || falha "o login no GitHub não foi concluído. Rode o comando de novo."
  ok "conectado como $(gh api user --jq .login)"
fi
gh auth setup-git -h github.com >/dev/null 2>&1 || falha "não consegui ligar o git ao login do GitHub."

gh repo view "$ORG/$REPO" >/dev/null 2>&1 \
  || falha "sua conta ainda não tem acesso a $ORG/$REPO. Aceite o convite da organização $ORG que chegou no seu e-mail (ou em github.com/$ORG) e rode o comando de novo."

# 4. Vault
passo "4/5 · Vault da Animus"
if [ -d "$VAULT/.git" ]; then
  ok "já está em $VAULT"
else
  mkdir -p "$(dirname "$VAULT")"
  git clone -q "https://github.com/$ORG/$REPO.git" "$VAULT" || falha "não consegui baixar o vault."
  ok "baixado em $VAULT"
fi
nome=$(gh api user --jq '.name // .login')
email=$(gh api user --jq '.email // empty')
[ -n "$email" ] || email="$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"
git -C "$VAULT" config user.name "$nome"
git -C "$VAULT" config user.email "$email"
git -C "$VAULT" config core.precomposeunicode true
ok "assinando as mudanças como $nome"

# 5. Sincronização automática a cada 5 minutos
passo "5/5 · Sincronização automática"
mkdir -p "$(dirname "$SCRIPT")" "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$SCRIPT" <<EOF
#!/bin/bash
# Sincroniza o vault com o GitHub. Criado pelo instalador do $REPO.
export PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
exec >> "$LOG" 2>&1
echo "----- \$(date '+%Y-%m-%d %H:%M:%S') -----"
cd "$VAULT" 2>/dev/null || { echo "ERRO: vault nao encontrado em $VAULT"; exit 1; }
# Trava esquecida por um git que morreu impede o commit; so remove se nenhum git estiver rodando.
pgrep -x git >/dev/null 2>&1 || find .git -name '*.lock' -type f -delete 2>/dev/null
git add -A
git diff --cached --quiet && echo "sem mudancas locais" || git commit -q -m "vault: sync \$(date '+%Y-%m-%d %H:%M:%S')"
git pull --rebase --autostash -q origin main && echo "pull ok" || echo "AVISO: pull falhou"
git push -q origin main && echo "push ok" || echo "AVISO: push falhou (checar login / rede)"
EOF
chmod +x "$SCRIPT"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$SCRIPT</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/$REPO-sync.out</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/$REPO-sync.err</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null || falha "o agendamento ficou com erro de formato."
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
launchctl bootstrap "gui/$(id -u)" "$PLIST" || falha "não consegui ligar o agendamento."
ok "ligada"

# Teste: uma nota sobe para o GitHub e depois é apagada
printf '  Testando...\n'
login=$(gh api user --jq .login)
nota="_teste-sync-$login.md"
echo "Teste do instalador em $(date '+%d/%m/%Y %H:%M')." > "$VAULT/$nota"
/bin/bash "$SCRIPT"
if gh api "repos/$ORG/$REPO/contents/$nota" >/dev/null 2>&1; then
  rm -f "$VAULT/$nota"; /bin/bash "$SCRIPT"
  ok "teste passou: o que muda no Mac chega ao GitHub e volta"
else
  rm -f "$VAULT/$nota"
  falha "a nota de teste não chegou ao GitHub. Últimas linhas do registro:
$(tail -5 "$LOG")"
fi

printf '\n\033[32mPronto.\033[0m Falta um passo, no app do Claude:\n'
printf '  Personalizar > Plugins > Adicionar > Adicionar marketplace > Adicionar de um repositório\n'
printf '  e digite: %s\n' "$MARKETPLACE"
printf '\nO vault está em %s. Para abrir no Obsidian: "Abrir pasta como vault" e escolha essa pasta.\n' "$VAULT"
printf 'Para trabalhar na Animus, conecte essa pasta na conversa com o Claude.\n\n'
