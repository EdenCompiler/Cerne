#!/usr/bin/env bash
# demo.sh — liga o Cerne no QEMU e "digita" comandos devagar, pra animação.
#
# Usado pelo gravar-gif.sh dentro do asciinema. Roda sozinho também:
#   ./demo.sh
set -euo pipefail

raiz="$(cd "$(dirname "$0")" && pwd)"
imagem="$raiz/build/cerne.cpio.gz"
kernel="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -n1)"

fifo="$(mktemp -u)"
mkfifo "$fifo"
# mantém o FIFO aberto pra escrita o tempo todo (senão o QEMU vê EOF cedo)
exec 3<>"$fifo"

qemu-system-x86_64 \
  -kernel "$kernel" \
  -initrd "$imagem" \
  -append "console=ttyS0 quiet loglevel=0 sysctl.debug.exception-trace=0 panic=-1" \
  -m 512M -nographic -no-reboot < "$fifo" &
qpid=$!

limpar() { kill "$qpid" 2>/dev/null || true; rm -f "$fifo"; }
trap limpar EXIT

# digita uma string caractere a caractere, depois Enter
digitar() {
  local s="$1" i
  for ((i=0; i<${#s}; i++)); do
    printf '%s' "${s:i:1}" >&3
    sleep 0.04
  done
  printf '\n' >&3
}

sleep 11                       # espera o boot chegar no REPL
digitar '(cpuinfo)';                sleep 1.6
digitar '(meminfo)';                sleep 1.6
digitar '(data)';                   sleep 1.4
digitar '(lembrar :jogo "Zelda")';  sleep 1.2
digitar '(recordar :jogo)';         sleep 1.4
digitar '(mandelbrot 70 22)';       sleep 2.5
digitar '(desligar)';               sleep 2

wait "$qpid" 2>/dev/null || true
