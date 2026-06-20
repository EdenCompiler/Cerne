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

disco="$raiz/build/disco.img"
[[ -f "$disco" ]] || { mkdir -p "$raiz/build"; truncate -s 1M "$disco"; }

acel=()
[[ -r /dev/kvm && -w /dev/kvm ]] && acel=(-enable-kvm -cpu host)

qemu-system-x86_64 \
  -kernel "$kernel" \
  -initrd "$imagem" \
  -append "console=ttyS0 quiet loglevel=0 sysctl.debug.exception-trace=0 panic=-1" \
  -m 512M "${acel[@]}" \
  -netdev user,id=net0,hostfwd=tcp::2323-:2323 -device virtio-net-pci,netdev=net0 \
  -drive "file=$disco,format=raw,if=virtio" \
  -nographic -no-reboot < "$fifo" &
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

# espera o boot chegar no REPL (rápido com KVM, lento em TCG)
if [[ ${#acel[@]} -gt 0 ]]; then sleep 4; else sleep 11; fi
digitar '(cpuinfo)';                       sleep 1.2
digitar '(rtc)';                           sleep 1.4
digitar '(fortune)';                       sleep 1.6
digitar '(quine)';                         sleep 2.0
digitar '(vaca "Lisp no metal!")';         sleep 1.8
digitar '(salvar)';                        sleep 1.2
digitar '(disco-bruto 48)';                sleep 1.8
digitar '(grafico (list 3 7 2 9 5 8 4))';  sleep 2.0
digitar '(arvore 8 58 16)';                sleep 2.0
digitar '(mandelbrot 60 16)';              sleep 2.0
digitar '(fogo 14 58 12)';                 sleep 1.6
digitar '(plasma 12 58 12)';               sleep 1.6
digitar '(matrix 14 58 12)';               sleep 1.6
digitar '(desligar)';                      sleep 2

wait "$qpid" 2>/dev/null || true
