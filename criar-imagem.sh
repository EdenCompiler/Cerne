#!/usr/bin/env bash
# criar-imagem.sh — monta o initramfs com o binário do Cerne como /init.
#
# O kernel Linux, ao subir, executa /init do initramfs. Colocamos ali o
# binário do SBCL. Resultado: a máquina liga direto no REPL Lisp.
set -euo pipefail

raiz="$(cd "$(dirname "$0")" && pwd)"
binario="$raiz/build/cerne"
fs="$raiz/build/initramfs"
imagem="$raiz/build/cerne.cpio.gz"

if [[ ! -x "$binario" ]]; then
  echo "Binário não encontrado: $binario" >&2
  echo "Rode primeiro: sbcl --non-interactive --load construir.lisp" >&2
  exit 1
fi

echo ">> Limpando árvore antiga do initramfs"
rm -rf "$fs"
mkdir -p "$fs"/{bin,lib,lib64,dev,proc,sys}

echo ">> Copiando o núcleo como /init"
cp "$binario" "$fs/init"
chmod +x "$fs/init"

echo ">> Copiando bibliotecas compartilhadas exigidas pelo binário"
# Pega todas as libs (e o linker dinâmico) via ldd e copia preservando o caminho.
ldd "$binario" | awk '
    /=>/ { print $3 }
    /ld-linux/ { print $1 }
' | sort -u | while read -r lib; do
  [[ -e "$lib" ]] || continue
  destino="$fs$lib"
  mkdir -p "$(dirname "$destino")"
  cp -L "$lib" "$destino"
  echo "   $lib"
done

echo ">> Incluindo módulos do kernel (disco + rede)"
# Mesma versão do kernel que o iniciar.sh boota (o mais novo em /boot).
kv="$(ls -1 /boot/vmlinuz-* | sort -V | tail -n1 | sed 's#.*/vmlinuz-##')"
mkdir -p "$fs/lib/modules"

incluir_modulo() {  # $1 = caminho relativo dentro de /lib/modules/$kv/kernel
  local rel="$1" base; base="$(basename "$rel")"
  local src="/lib/modules/$kv/kernel/$rel"
  if [[ -f "$src" ]]; then
    cp "$src" "$fs/lib/modules/$base"
  elif [[ -f "$src.xz" ]]; then
    xz -dc "$src.xz" > "$fs/lib/modules/$base"
  elif [[ -f "$src.zst" ]]; then
    zstd -dc "$src.zst" > "$fs/lib/modules/$base"
  else
    echo "   AVISO: $base não encontrado"
    return 1
  fi
  echo "   $base"
}

# Disco (persistência) e rede (telnet). A ordem de carga é tratada no Lisp.
incluir_modulo "drivers/block/virtio_blk.ko"
incluir_modulo "net/core/failover.ko"
incluir_modulo "drivers/net/net_failover.ko"
incluir_modulo "drivers/net/virtio_net.ko"

echo ">> Empacotando initramfs (cpio + gzip)"
( cd "$fs" && find . -print0 | cpio --null -o --format=newc 2>/dev/null ) \
  | gzip -9 > "$imagem"

echo ">> Pronto: $imagem ($(du -h "$imagem" | cut -f1))"
