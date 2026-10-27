#!/usr/bin/env python3
"""Valida o animus-plugins antes de publicar. Imprime um problema por linha; nada impresso = pode publicar.

Uso: python3 validar-plugins.py <pasta do repositório>
Compara com origin/main (o que está publicado), então rode `git fetch` antes.
"""
import json, os, re, subprocess, sys

raiz = sys.argv[1] if len(sys.argv) > 1 else "."
os.chdir(raiz)
problemas = []


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def ler_json(caminho):
    try:
        with open(caminho, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        problemas.append(f"{caminho}: arquivo não existe")
    except json.JSONDecodeError as e:
        problemas.append(f"{caminho}: JSON inválido (linha {e.lineno}): {e.msg}")
    return None


SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
# Limite empírico do Claude para a descrição de uma skill.
LIMITE_DESCRICAO = 1024

catalogo = ler_json(".claude-plugin/marketplace.json")
entradas = []
if catalogo is not None:
    if not isinstance(catalogo.get("plugins"), list):
        problemas.append(".claude-plugin/marketplace.json: falta a lista \"plugins\"")
    else:
        entradas = catalogo["plugins"]

# Arquivos que mudaram em relação ao publicado (inclui arquivos novos ainda não versionados).
mudados = set((git("diff", "--name-only", "origin/main") or "").split())
mudados |= set((git("ls-files", "--others", "--exclude-standard") or "").split())

for e in entradas:
    nome = e.get("name")
    fonte = e.get("source")
    if not nome:
        problemas.append("marketplace.json: um plugin está sem \"name\"")
        continue
    if not (isinstance(fonte, str) and fonte.startswith("./")):
        continue  # plugin que mora fora deste repositório: não há o que validar aqui
    pasta = os.path.normpath(fonte)
    manifesto_caminho = os.path.join(pasta, ".claude-plugin", "plugin.json")
    manifesto = ler_json(manifesto_caminho)
    if manifesto is None:
        continue
    if manifesto.get("name") != nome:
        problemas.append(f"{manifesto_caminho}: name \"{manifesto.get('name')}\" difere do catálogo \"{nome}\"")
    versao = manifesto.get("version")
    if not (isinstance(versao, str) and SEMVER.match(versao)):
        problemas.append(f"{manifesto_caminho}: version precisa ser no formato 1.2.3")
    if "version" in e and e["version"] != versao:
        problemas.append(f"marketplace.json: versão de {nome} ({e['version']}) difere do plugin.json ({versao})")

    # Skills: cada SKILL.md precisa de name e description no cabeçalho.
    for base, _, arquivos in os.walk(os.path.join(pasta, "skills")):
        if "SKILL.md" not in arquivos:
            continue
        caminho = os.path.join(base, "SKILL.md")
        texto = open(caminho, encoding="utf-8").read()
        m = re.match(r"^---\n(.*?)\n---\n", texto, re.S)
        if not m:
            problemas.append(f"{caminho}: falta o cabeçalho entre --- no topo")
            continue
        cab = m.group(1)
        if not re.search(r"^name:\s*\S", cab, re.M):
            problemas.append(f"{caminho}: falta name no cabeçalho")
        d = re.search(r"^description:\s*(.*)$", cab, re.M)
        if not d or not d.group(1).strip():
            problemas.append(f"{caminho}: falta description no cabeçalho")
        elif len(d.group(1).strip()) > LIMITE_DESCRICAO:
            problemas.append(f"{caminho}: description com mais de {LIMITE_DESCRICAO} caracteres")

    # Versão: plugin com arquivo mudado precisa de versão nova, senão ninguém recebe a mudança.
    mexeu = any(p == pasta or p.startswith(pasta + "/") for p in mudados)
    publicado = git("show", f"origin/main:{manifesto_caminho}")
    if mexeu and publicado:
        try:
            versao_publicada = json.loads(publicado).get("version")
        except json.JSONDecodeError:
            versao_publicada = None
        if versao_publicada == versao:
            problemas.append(f"{nome}: arquivos mudaram mas a versão continua {versao}; suba a versão no plugin.json")

print("\n".join(problemas))
