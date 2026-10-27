# Instalador do animus-os

Liga o Mac de uma pessoa nova ao vault e aos plugins da AnimusPay.

## Antes

Aceite o convite da organização **animus-ia** que chegou no seu e-mail.

## Instalar

Abra o Terminal, cole a linha abaixo e aperte Enter:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/animus-ia/instalador/main/instalar.sh)"
```

O instalador instala o git e a ferramenta do GitHub se faltarem, abre o navegador para você entrar no GitHub, baixa o vault em `~/IA/animus-os`, liga a sincronização automática a cada 5 minutos e testa. Se algo der errado, ele diz onde parou. Pode rodar de novo quantas vezes quiser.

## Depois

No app do Claude: Personalizar > Plugins > Adicionar > Adicionar marketplace > Adicionar de um repositório, e digite `animus-ia/animus-plugins`.

## Só para quem edita skills

Quem cria ou altera skills instala também a cópia de edição do `animus-plugins` (precisa de acesso de escrita a ele):

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/animus-ia/instalador/main/instalar-plugins.sh)"
```

Ela fica em `~/IA/animus-plugins`. Rascunhos ficam em `_rascunhos/` e nunca são publicados. A publicação acontece quando o arquivo `.publicar` aparece na pasta: em até 5 minutos a rotina valida (formato dos arquivos e versão nova em todo plugin alterado), publica com a mensagem escrita nesse arquivo e grava o resultado em `.publicacao.log`. Quem só usa as skills não precisa disto.

Este repositório é público e não guarda senha, token nem dado da empresa: só os passos de instalação.
