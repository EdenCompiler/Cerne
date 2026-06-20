# Cerne 🌳

> Um núcleo Lisp que **liga direto no REPL**. Sem shell. Sem espaço de usuário. Só parênteses.

**Cerne** é um *unikernel* de brincadeira (e de verdade) escrito em Common Lisp.
A máquina liga, o kernel sobe, e em vez de cair num `login:` você cai num
prompt `cerne>` — um REPL Lisp completo rodando como **PID 1**.

![demo do Cerne](recursos/cerne.gif)

```
   ____
  / ___|___ _ __ _ __   ___
 | |   / _ \ '__| '_ \ / _ \     Cerne — núcleo Lisp inicializável
 | |__|  __/ |  | | | |  __/     SBCL rodando direto como PID 1
  \____\___|_|  |_| |_|\___|     Sem shell. Sem SO. Só parênteses.

SBCL 2.5.2 — digite (ajuda) para começar.

cerne> (loop for i below 5 collect (* i i))
=> (0 1 4 9 16)
cerne> (desligar)
Desligando o Cerne. Até logo.
```

## Por que isso existe

Porque dá. E porque é divertido ligar um computador e a primeira coisa
que ele te oferece é avaliar S-expressões.

## Como funciona (a verdade técnica)

Um unikernel *bare-metal de verdade* em SBCL seria reescrever todo o
runtime do SBCL sem syscalls — projeto do tamanho do [Mezzano](https://github.com/froggey/Mezzano),
anos de trabalho.

O Cerne faz o truque prático que unikernels reais usam: o binário Lisp
**é o processo de init**. O kernel Linux sobe um `initramfs` mínimo cujo
`/init` é o executável do SBCL. Nada de shell, systemd ou disco — só o
kernel e os parênteses.

```
QEMU
 └── kernel Linux
      └── initramfs
           └── /init  ← binário SBCL (este projeto)
                └── REPL em português, como PID 1
```

Os comandos do operador (`desligar`, `reiniciar`) falam direto com o
kernel via `reboot(2)`, chamando a syscall na unha — porque PID 1 não
tem ninguém acima para pedir.

## Rodar

Precisa de: `sbcl`, `qemu-system-x86_64`, `gcc`, `cpio`, `gzip` e um
kernel em `/boot/vmlinuz-*` (qualquer distro Linux tem).

```sh
make rodar
```

Isso compila o binário, monta o `initramfs` e liga a máquina no QEMU.
Para desligar: digite `(desligar)` no REPL, ou `Ctrl-A` seguido de `X`.

**Velocidade:** com KVM (`/dev/kvm`), o boot até o REPL leva **~1.6s**.
Os scripts usam KVM automaticamente quando disponível e caem pra emulação
(TCG, ~10s) quando não há.

**Rede:** os scripts ligam uma interface virtio-net e encaminham a porta
`2323` do host. Dentro do REPL, `(telnet)` serve um REPL completo por TCP —
conecte de fora com `nc localhost 2323` e avalie Lisp na máquina remota
(inclusive `(desligar)`).

Alvos separados:

```sh
make binario   # gera build/cerne via SBCL
make imagem    # monta o initramfs
make rodar     # liga no QEMU
make limpar    # apaga build/
```

## Comandos do núcleo

Tudo é Lisp — os "comandos" são só funções. O REPL tem **edição de linha**
(modo cru da tty via `termios`): setas ←→ movem o cursor, ↑↓ navegam o
histórico, e backspace / Ctrl-A / Ctrl-E funcionam como você espera.

**Operador**

| Comando        | O que faz                          |
| -------------- | ---------------------------------- |
| `(ajuda)` / `(ajuda 'cmd)` | lista comandos / doc de um |
| `(memoria)`    | uso de memória do núcleo           |
| `(tempo)`      | tempo de vida do REPL              |
| `(cronometrar forma...)` | mede o tempo de avaliar formas |
| `(reiniciar)`  | reinicia a máquina                 |
| `(desligar)`   | desliga a máquina                  |

**Sistema** (lê o `/proc` que o próprio Cerne monta no boot)

| Comando      | O que faz                          |
| ------------ | ---------------------------------- |
| `(uptime)`   | tempo que a máquina está ligada    |
| `(meminfo)`  | RAM total / livre / disponível     |
| `(cpuinfo)`  | modelo da CPU e nº de núcleos      |
| `(data)`     | data e hora em UTC (RTC)           |
| `(uname)`    | versão do kernel                   |
| `(cmdline)`  | argumentos de boot do kernel       |
| `(modulos)`  | módulos do kernel carregados       |
| `(pci)`      | dispositivos PCI (via `/sys`)      |
| `(rtc)`      | data/hora do chip RTC (porta I/O)  |

**Arquivos** (explore os pseudo-FS do kernel)

| Comando                  | O que faz                    |
| ------------------------ | ---------------------------- |
| `(arquivos "/proc")`     | lista um diretório (ls)      |
| `(ver "/proc/cmdline")`  | mostra um arquivo (cat)      |

**Rede**

| Comando         | O que faz                                       |
| --------------- | ----------------------------------------------- |
| `(rede)`        | sobe a interface e mostra o IP                  |
| `(telnet 2323)` | serve um REPL por TCP (`nc localhost 2323`)     |

A interface virtio-net sobe na unha via `ioctl(SIOCSIFADDR…)` (struct
`ifreq`), sem `ifconfig`. O REPL remoto avalia Lisp por um socket TCP.

**Lisp / meta**

| Comando                          | O que faz                              |
| -------------------------------- | -------------------------------------- |
| `(quine)`                        | forma que se reproduz ao ser avaliada  |
| `(desmontar 'fib)`               | mostra o código de máquina da função   |
| `(macroexpandir '(when a b))`    | expande uma macro um nível             |

**Memória chave-valor** (vive enquanto a máquina viver)

| Comando                    | O que faz                  |
| -------------------------- | -------------------------- |
| `(lembrar chave valor)`    | guarda um valor            |
| `(recordar chave)`         | recupera um valor          |
| `(esquecer chave)`         | apaga um valor             |
| `(tudo-que-lembro)`        | lista tudo                 |

**Persistência em disco cru** — sem sistema de arquivos!

| Comando        | O que faz                                        |
| -------------- | ------------------------------------------------ |
| `(salvar)`       | grava a loja direto nos bytes de `/dev/vda`    |
| `(restaurar)`    | recarrega a loja do disco                      |
| `(disco-bruto)`  | hexdump dos bytes crus de `/dev/vda`           |

A loja é serializada como uma S-expressão e escrita **direto no bloco**
`/dev/vda` — nada de ext4, FAT ou partição. No boot, o Cerne carrega o
módulo `virtio_blk` via `finit_module(2)` e restaura a loja sozinho.
Desligue, ligue de novo: ela continua lá.

**Diversão**

| Comando             | O que faz                                  |
| ------------------- | ------------------------------------------ |
| `(mandelbrot)`      | desenha o Mandelbrot em ASCII colorido     |
| `(vida)`            | Jogo da Vida de Conway, animado            |
| `(matrix)`          | chuva digital estilo Matrix                |
| `(plasma)`          | plasma colorido animado (cores 256)        |
| `(fogo)`            | efeito de fogo ASCII animado               |
| `(snake)`           | jogo da cobra (setas/WASD, q sai)          |
| `(cores)`           | paleta de cores ANSI do terminal           |
| `(relogio 10)`      | relógio digital grande, ao vivo            |
| `(arvore)`          | árvore fractal em ASCII                     |
| `(grafico lista)`   | gráfico de barras de uma lista             |
| `(vaca "texto")`    | cowsay em português                        |
| `(pi-digitos 80)`   | dígitos de π por Machin (aritmética exata) |
| `(senha 16)`        | gera senha com entropia de `/dev/urandom`  |
| `(fortune)`         | frase hacker/Lisp aleatória                |
| `(adivinhe)`        | jogo de adivinhar o número                 |
| `(historico)`       | comandos avaliados na sessão               |

Como um init de verdade, o Cerne monta `/proc`, `/sys` e `/dev` (devtmpfs)
no boot, carrega módulo do kernel via `finit_module(2)`, e fala com o
kernel via `reboot(2)` e `mount(2)` na unha.

Fora isso, é Common Lisp puro:

```lisp
cerne> (defun fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
cerne> (mapcar #'fib (loop for i below 10 collect i))
=> (0 1 1 2 3 5 8 13 21 34)
```

## Estrutura

```
cerne/
├── src/cerne.lisp     # o núcleo: banner, REPL, syscalls, comandos
├── construir.lisp     # gera build/cerne com save-lisp-and-die
├── criar-imagem.sh    # monta o initramfs (binário + libs)
├── iniciar.sh         # liga a máquina no QEMU
└── Makefile
```

## Aviso

Projeto educativo / recreativo. Roda só em QEMU (usa o kernel do host).
Não é um sistema operacional de produção — é um abraço em parênteses.

## Licença

MIT.
