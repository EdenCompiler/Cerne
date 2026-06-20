#!/usr/bin/env bash
# iniciar.sh — liga a máquina Cerne no QEMU.
#
# Boota o kernel Linux do host com nosso initramfs. Console na serial,
# sem tela gráfica: você cai direto no REPL Lisp do Cerne.
#
# Para sair do QEMU: use (desligar) no REPL, ou Ctrl-A depois X.
set -euo pipefail

raiz="$(cd "$(dirname "$0")" && pwd)"
imagem="$raiz/build/cerne.cpio.gz"

# Escolhe o kernel mais novo disponível no host.
kernel="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -n1 || true)"

if [[ -z "$kernel" ]]; then
  echo "Nenhum kernel encontrado em /boot/vmlinuz-*" >&2
  exit 1
fi
if [[ ! -f "$imagem" ]]; then
  echo "Imagem não encontrada: $imagem  (rode ./criar-imagem.sh)" >&2
  exit 1
fi

echo ">> Kernel:   $kernel"
echo ">> Initramfs: $imagem"
echo ">> Ligando o Cerne (Ctrl-A X para forçar saída)"
echo

# Discos crus: vda = loja chave-valor, vdb = autoexec (init.lisp).
disco="$raiz/build/disco.img"
disco2="$raiz/build/disco-init.img"
mkdir -p "$raiz/build"
[[ -f "$disco" ]]  || truncate -s 1M "$disco"
[[ -f "$disco2" ]] || truncate -s 1M "$disco2"

# KVM corta o boot de ~10s pra ~2s. Cai pra TCG se não houver /dev/kvm.
acel=()
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  acel=(-enable-kvm -cpu host)
else
  echo ">> /dev/kvm indisponível — usando TCG (mais lento)"
fi

exec qemu-system-x86_64 \
  -kernel "$kernel" \
  -initrd "$imagem" \
  -append "console=ttyS0 quiet loglevel=0 sysctl.debug.exception-trace=0 panic=-1" \
  -m 512M \
  "${acel[@]}" \
  -netdev user,id=net0,hostfwd=tcp::2323-:2323,hostfwd=tcp::8080-:8080 \
  -device virtio-net-pci,netdev=net0 \
  -drive "file=$disco,format=raw,if=virtio" \
  -drive "file=$disco2,format=raw,if=virtio" \
  -nographic \
  -no-reboot
