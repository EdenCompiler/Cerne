#!/usr/bin/env bash
# gravar-gif.sh — grava a demo do Cerne e gera um GIF.
#
# Precisa de: asciinema, agg.  Gera: build/cerne.cast e cerne.gif
set -euo pipefail

raiz="$(cd "$(dirname "$0")" && pwd)"
cast="$raiz/build/cerne.cast"
gif="$raiz/recursos/cerne.gif"

mkdir -p "$raiz/build" "$raiz/recursos"
rm -f "$cast"

echo ">> Gravando sessão (asciinema)"
# O caminho do projeto pode ter espaços; asciinema -c e o script aninhado
# não lidam bem com isso. Então usamos um wrapper sem espaços em /tmp.
wrapper="$(mktemp /tmp/cerne-run.XXXXXX.sh)"
cast_tmp="$(mktemp /tmp/cerne-cast.XXXXXX.cast)"
printf '#!/bin/sh\nexec "%s"\n' "$raiz/demo.sh" > "$wrapper"
chmod +x "$wrapper"
trap 'rm -f "$wrapper" "$cast_tmp"' EXIT

# 'script' dá um pty pro asciinema mesmo fora de um terminal interativo.
# Caminhos sem espaços (em /tmp) pra sobreviver ao aninhamento de shells.
script -qec "asciinema rec --overwrite --cols 90 --rows 30 -c $wrapper $cast_tmp" /dev/null
cp "$cast_tmp" "$cast"

echo ">> Convertendo pra GIF (agg)"
agg --cols 90 --rows 30 --font-size 18 --speed 1.0 --fps-cap 12 "$cast" "$gif"

echo ">> Pronto: $gif ($(du -h "$gif" | cut -f1))"
