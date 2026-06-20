# Cerne — núcleo Lisp inicializável
# Alvos:
#   make           — compila o binário e monta a imagem
#   make binario   — só gera build/cerne (via SBCL)
#   make imagem    — monta o initramfs
#   make rodar     — liga a máquina no QEMU
#   make limpar    — apaga build/

SBCL ?= sbcl

.PHONY: tudo binario imagem rodar limpar

tudo: imagem

binario: build/cerne

build/cerne: src/cerne.lisp construir.lisp
	$(SBCL) --non-interactive --load construir.lisp

imagem: binario
	./criar-imagem.sh

rodar: imagem
	./iniciar.sh

limpar:
	rm -rf build
