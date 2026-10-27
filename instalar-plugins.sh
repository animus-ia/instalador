#!/bin/bash
# Instalador da cópia de edição do animus-plugins: só para quem cria ou altera skills.
# Quem só usa as skills não precisa disto: elas chegam pelo marketplace no Claude.
# Uso (no Terminal):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/animus-ia/instalador/main/instalar-plugins.sh)"
# Pode rodar de novo quantas vezes quiser: o que já está pronto é pulado.
#
# Como a publicação funciona depois de instalado:
#   - A cada 5 minutos a rotina traz as mudanças publicadas por outras pessoas.
#   - Quando existe o arquivo .publicar na pasta, ela abre uma proposta (pull request) no GitHub
#     com a mensagem escrita nesse arquivo. A automação do repositório valida e publica sozinha.
#   - Nas rodadas seguintes a rotina confere a proposta e grava o resultado em .publicacao.log:
#     AGUARDANDO, PUBLICADO, RECUSADO (com o motivo) ou AGUARDANDO APROVAÇÃO (mudança na automação).
#   - _rascunhos/, .publicar e .publicacao.log nunca são publicados.

set -u

ORG="animus-ia"
REPO="animus-plugins"
DIR="$HOME/IA/$REPO"
BIN="$HOME/.local/bin"
SCRIPTS="$HOME/Scripts"
SCRIPT="$SCRIPTS/$REPO-publicar.sh"
LABEL="com.animus.$REPO-publicar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$REPO-publicar.log"

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
rm -f "$SCRIPTS/$REPO-validar.py"  # validador local da primeira versão: a validação agora é só a do GitHub

cat > "$SCRIPT" <<EOF
#!/bin/bash
# Traz as mudanças dos outros e, com o sinal .publicar, abre a proposta no GitHub e acompanha
# até a automação do repositório publicar. Criado pelo instalador do $REPO.
export PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
DIR="$DIR"
SLUG="$ORG/$REPO"
RES="\$DIR/.publicacao.log"
PENDENTE="\$DIR/.git/publicacao-pendente"
exec >> "$LOG" 2>&1
echo "----- \$(date '+%Y-%m-%d %H:%M:%S') -----"
cd "\$DIR" 2>/dev/null || { echo "ERRO: pasta nao encontrada em \$DIR"; exit 1; }
pgrep -x git >/dev/null 2>&1 || find .git -name '*.lock' -type f -delete 2>/dev/null

grava() { printf '%s %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$1" > "\$RES"; echo "\$1"; }
desfaz_commit() {
  # Devolve a mudança para a pasta como estava, sem publicar (só se o commit local ainda não está no GitHub).
  git fetch -q origin main
  [ "\$(git rev-list --count origin/main..HEAD)" -gt 0 ] && git reset -q --soft HEAD~1
}

# 1. Proposta aberta: acompanha até publicar ou ser recusada
if [ -f "\$PENDENTE" ]; then
  read -r pr ramo < "\$PENDENTE"
  msg=\$(sed -n 2p "\$PENDENTE")
  estado=\$(gh pr view "\$pr" -R "\$SLUG" --json state --jq .state 2>/dev/null)
  case "\$estado" in
    MERGED)
      git pull --rebase --autostash -q origin main
      git push -q origin --delete "\$ramo" 2>/dev/null
      rm -f "\$PENDENTE"
      grava "PUBLICADO: \$msg (proposta #\$pr)" ;;
    CLOSED)
      desfaz_commit; rm -f "\$PENDENTE"
      grava "RECUSADO: a proposta #\$pr foi fechada sem publicar; a mudanca voltou para a pasta" ;;
    OPEN)
      checks=\$(gh pr view "\$pr" -R "\$SLUG" --json statusCheckRollup --jq '[.statusCheckRollup[] | (.conclusion // .status)] | join(" ")' 2>/dev/null)
      if echo "\$checks" | grep -qE 'FAILURE|CANCELLED|TIMED_OUT|ERROR'; then
        run=\$(gh run list -R "\$SLUG" --branch "\$ramo" -L 1 --json databaseId --jq '.[0].databaseId')
        motivo=\$(gh run view "\$run" -R "\$SLUG" --log-failed 2>/dev/null | grep -E '  - ' | sed 's/.*  - //' | head -5 | paste -sd ';' -)
        gh pr close "\$pr" -R "\$SLUG" --delete-branch >/dev/null 2>&1
        desfaz_commit; rm -f "\$PENDENTE"
        grava "RECUSADO pelo validador do GitHub: \${motivo:-ver a proposta #\$pr}; a mudanca voltou para a pasta"
      elif [ -n "\$checks" ] && ! echo "\$checks" | grep -qE 'QUEUED|IN_PROGRESS|PENDING|WAITING|REQUESTED'; then
        grava "AGUARDANDO APROVACAO: a proposta #\$pr passou na validacao mas precisa de aprovacao de uma pessoa (mexe na automacao): https://github.com/\$SLUG/pull/\$pr"
      else
        grava "AGUARDANDO: o GitHub esta validando a proposta #\$pr"
      fi ;;
    *) echo "AVISO: nao consegui consultar a proposta #\$pr" ;;
  esac
  exit 0
fi

# 2. Sem sinal: só traz as mudanças dos outros
if [ ! -f .publicar ]; then
  git pull --rebase --autostash -q origin main && echo "atualizado" || echo "AVISO: nao consegui trazer as mudancas"
  exit 0
fi

# 3. Sinal: abre a proposta
msg=\$(head -1 .publicar | tr -d '\r'); [ -n "\$msg" ] || msg="Atualiza skills"
rm -f .publicar
git fetch -q origin main || { grava "ERRO: sem acesso ao GitHub; nada publicado, crie o sinal de novo"; exit 0; }
git pull --rebase --autostash -q origin main || { grava "ERRO: alguem publicou mudanca no mesmo arquivo; resolver o conflito antes de publicar"; exit 0; }
git add -A
git diff --cached --quiet && { grava "NADA A PUBLICAR: nenhuma mudanca em relacao ao publicado"; exit 0; }
git commit -q -m "\$msg" || { grava "ERRO: nao consegui registrar a mudanca"; exit 0; }
ramo="publicar/\$(date '+%Y%m%d-%H%M%S')-\$RANDOM"
if ! git push -q origin "HEAD:refs/heads/\$ramo"; then
  git reset -q --soft HEAD~1; grava "ERRO: envio ao GitHub falhou; nada publicado, crie o sinal de novo"; exit 0
fi
url=\$(gh pr create -R "\$SLUG" --base main --head "\$ramo" --title "\$msg" --body "Aberta pela rotina de publicacao de \$(git config user.name).")
pr=\${url##*/}
if [ -z "\$pr" ] || ! [ "\$pr" -eq "\$pr" ] 2>/dev/null; then
  git push -q origin --delete "\$ramo" 2>/dev/null; git reset -q --soft HEAD~1
  grava "ERRO: nao consegui abrir a proposta no GitHub; nada publicado, crie o sinal de novo"; exit 0
fi
printf '%s %s\n%s\n' "\$pr" "\$ramo" "\$msg" > "\$PENDENTE"
grava "AGUARDANDO: proposta #\$pr aberta; o GitHub valida e publica em instantes"
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

# Teste: a rotina traz o que está publicado
/bin/bash "$SCRIPT"
tail -1 "$LOG" | grep -q "atualizado" || falha "a rotina não conseguiu trazer as mudanças do GitHub. Última linha do registro: $(tail -1 "$LOG")"
ok "ligada e testada"

printf '\n\033[32mPronto.\033[0m Para editar skills, conecte a pasta %s na conversa com o Claude.\n' "$DIR"
printf 'Rascunhos ficam em _rascunhos/ e nunca são publicados. A publicação só acontece com aprovação.\n\n'
