#!/bin/bash
# Instalador da cópia de edição do animus-plugins: só para quem cria ou altera skills.
# Quem só usa as skills não precisa disto: elas chegam pelo marketplace no Claude.
# Uso (no Terminal):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/animus-ia/instalador/main/instalar-plugins.sh)"
# Pode rodar de novo quantas vezes quiser: o que já está pronto é pulado.
#
# Como a publicação funciona depois de instalado:
#   - A cada 5 minutos a rotina traz as mudanças publicadas por outras pessoas.
#   - Quando existe o arquivo .publicar na pasta, ela valida, publica no GitHub com a
#     mensagem escrita nesse arquivo, grava o resultado em .publicacao.log e apaga o sinal.
#   - _rascunhos/, .publicar e .publicacao.log nunca são publicados.

set -u

ORG="animus-ia"
REPO="animus-plugins"
DIR="$HOME/IA/$REPO"
BIN="$HOME/.local/bin"
SCRIPTS="$HOME/Scripts"
SCRIPT="$SCRIPTS/$REPO-publicar.sh"
VALIDADOR="$SCRIPTS/$REPO-validar.py"
VALIDADOR_URL="https://raw.githubusercontent.com/animus-ia/instalador/main/validar-plugins.py"
LABEL="com.animus.$REPO-publicar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$REPO-publicar.log"

passo() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()    { printf '  ✓ %s\n' "$1"; }
falha() { printf '\n\033[31mParou aqui:\033[0m %s\n' "$1"; printf 'Mande um print desta tela para quem te convidou.\n'; exit 1; }

[ "$(uname)" = "Darwin" ] || falha "este instalador é para Mac."
export PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# 1. Git e Python (vêm com as Ferramentas de Linha de Comando da Apple)
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
/usr/bin/python3 -c 'import json' >/dev/null 2>&1 || falha "o Python da Apple não está disponível; rode de novo depois de terminar a instalação das Ferramentas da Apple."

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
gh api "repos/$ORG/$REPO" --jq .permissions.push 2>/dev/null | grep -q true \
  || falha "sua conta não tem permissão de escrita em $ORG/$REPO. Peça a um dono da organização $ORG para te dar acesso de escrita e rode o comando de novo."

# 4. Cópia de edição
passo "4/5 · Cópia de edição dos plugins"
if [ -d "$DIR/.git" ]; then
  ok "já está em $DIR"
else
  mkdir -p "$(dirname "$DIR")"
  git clone -q "https://github.com/$ORG/$REPO.git" "$DIR" || falha "não consegui baixar o $REPO."
  ok "baixada em $DIR"
fi
nome=$(gh api user --jq '.name // .login')
email=$(gh api user --jq '.email // empty')
[ -n "$email" ] || email="$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"
git -C "$DIR" config user.name "$nome"
git -C "$DIR" config user.email "$email"
git -C "$DIR" config core.precomposeunicode true
# O que nunca é publicado fica só nesta cópia (regra local, não vai para o repositório).
EXC="$DIR/.git/info/exclude"
for p in "_rascunhos/" ".publicar" ".publicacao.log" ".DS_Store"; do
  grep -qxF "$p" "$EXC" 2>/dev/null || echo "$p" >> "$EXC"
done
mkdir -p "$DIR/_rascunhos"
ok "assinando as publicações como $nome"

# 5. Rotina de publicação
passo "5/5 · Rotina de publicação"
mkdir -p "$SCRIPTS" "$(dirname "$PLIST")" "$(dirname "$LOG")"
curl -fsSL "$VALIDADOR_URL" -o "$VALIDADOR" || falha "não consegui baixar o validador."

cat > "$SCRIPT" <<EOF
#!/bin/bash
# Traz as mudanças dos outros e publica quando houver o sinal .publicar. Criado pelo instalador do $REPO.
export PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
DIR="$DIR"
RES="\$DIR/.publicacao.log"
exec >> "$LOG" 2>&1
echo "----- \$(date '+%Y-%m-%d %H:%M:%S') -----"
cd "\$DIR" 2>/dev/null || { echo "ERRO: pasta nao encontrada em \$DIR"; exit 1; }
pgrep -x git >/dev/null 2>&1 || find .git -name '*.lock' -type f -delete 2>/dev/null

if [ ! -f .publicar ]; then
  git pull --rebase --autostash -q origin main && echo "atualizado" || echo "AVISO: nao consegui trazer as mudancas"
  exit 0
fi

resultado() {
  printf '%s %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$1" > "\$RES"
  echo "\$1"; rm -f .publicar; exit 0
}
msg=\$(head -1 .publicar | tr -d '\r')
[ -n "\$msg" ] || msg="Atualiza skills"
git fetch -q origin main || resultado "ERRO: sem acesso ao GitHub; nada publicado"
problemas=\$(/usr/bin/python3 "$VALIDADOR" "\$DIR")
[ -z "\$problemas" ] || resultado "RECUSADO: \$(echo "\$problemas" | tr '\n' ';')"
git add -A
git diff --cached --quiet && resultado "NADA A PUBLICAR: nenhuma mudanca em relacao ao publicado"
git commit -q -m "\$msg" || resultado "ERRO: nao consegui registrar a mudanca"
if ! git pull --rebase -q origin main; then
  git rebase --abort 2>/dev/null
  git reset -q --soft HEAD~1
  resultado "ERRO: alguem publicou mudanca no mesmo arquivo; nada publicado, resolver o conflito"
fi
git push -q origin main && resultado "PUBLICADO: \$msg (\$(git rev-parse --short HEAD))" || resultado "ERRO: envio ao GitHub falhou; nada publicado"
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
  <key>StandardOutPath</key><string>$HOME/Library/Logs/$REPO-publicar.out</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/$REPO-publicar.err</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null || falha "o agendamento ficou com erro de formato."
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
launchctl bootstrap "gui/$(id -u)" "$PLIST" || falha "não consegui ligar o agendamento."

# Teste: a rotina traz o publicado e o validador aprova o estado atual
/bin/bash "$SCRIPT"
tail -1 "$LOG" | grep -q "atualizado" || falha "a rotina não conseguiu trazer as mudanças do GitHub. Última linha do registro: $(tail -1 "$LOG")"
problemas=$(/usr/bin/python3 "$VALIDADOR" "$DIR")
[ -z "$problemas" ] && ok "ligada e testada" || printf '  ⚠ ligada; o validador já aponta pendências no que está publicado:\n%s\n' "$problemas"

printf '\n\033[32mPronto.\033[0m Para editar skills, conecte a pasta %s na conversa com o Claude.\n' "$DIR"
printf 'Rascunhos ficam em _rascunhos/ e nunca são publicados. A publicação só acontece com aprovação.\n\n'
