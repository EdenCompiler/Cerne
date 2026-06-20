;;;; Cerne — núcleo Lisp inicializável (unikernel)
;;;;
;;;; Este arquivo vira o processo de inicialização (PID 1) da máquina.
;;;; Ao ligar, o kernel Linux carrega este binário diretamente como /init,
;;;; sem shell, sem systemd, sem espaço de usuário — só parênteses.
;;;;
;;;; Tudo escrito em português do Brasil de propósito.

(defpackage :cerne
  (:use :cl)
  (:export :inicializar
           ;; operador
           :ajuda :desligar :reiniciar :memoria :tempo
           ;; introspecção do sistema
           :uptime :meminfo :cpuinfo :data
           ;; loja chave-valor
           :lembrar :recordar :esquecer :tudo-que-lembro
           ;; diversão
           :mandelbrot :adivinhe))

(in-package :cerne)

;;; ===========================================================================
;;; Chamadas de sistema (somos o PID 1, então falamos direto com o kernel)
;;; ===========================================================================

;; Número da syscall reboot() no x86_64 = 169.
;; Constantes mágicas exigidas pelo kernel Linux (man 2 reboot).
(defconstant +magica-1+ #xfee1dead)
(defconstant +magica-2+ #x28121969)            ; 672274793
(defconstant +desligar+ #x4321fedc)            ; LINUX_REBOOT_CMD_POWER_OFF
(defconstant +reiniciar+ #x01234567)           ; LINUX_REBOOT_CMD_RESTART

(sb-alien:define-alien-routine ("syscall" chamada-de-sistema) sb-alien:long
  (numero sb-alien:long)
  (a sb-alien:long) (b sb-alien:long)
  (c sb-alien:long) (d sb-alien:long))

(defun reboot-cru (comando)
  "Chama reboot(2) cru. COMANDO decide se desliga ou reinicia."
  (finish-output)
  (chamada-de-sistema 169 +magica-1+ +magica-2+ comando 0))

;; mount(2) via libc, para montar /proc, /sys e /dev como um init de verdade.
(sb-alien:define-alien-routine ("mount" c-mount) sb-alien:int
  (origem sb-alien:c-string)
  (destino sb-alien:c-string)
  (tipo sb-alien:c-string)
  (flags sb-alien:unsigned-long)
  (dados sb-alien:c-string))

(defun montar-sistemas-de-arquivos ()
  "Monta os pseudo-sistemas de arquivos do kernel. Dever de todo PID 1."
  (dolist (m '(("proc"     "/proc" "proc")
               ("sysfs"    "/sys"  "sysfs")
               ("devtmpfs" "/dev"  "devtmpfs")))
    (destructuring-bind (origem destino tipo) m
      (handler-case (c-mount origem destino tipo 0 "")
        (error () nil)))))

;;; ===========================================================================
;;; Cores ANSI (deixa o terminal bonito; ótimo pro GIF do README)
;;; ===========================================================================

(defparameter *cores* t "Liga/desliga cores ANSI.")

(defun cor (codigo texto)
  (if *cores*
      (format nil "~c[~am~a~c[0m" #\Escape codigo texto #\Escape)
      texto))

(defun verde (s)   (cor "32" s))
(defun ciano (s)   (cor "36" s))
(defun amarelo (s) (cor "33" s))
(defun negrito (s) (cor "1" s))

;;; ===========================================================================
;;; Leitura de arquivos do /proc
;;; ===========================================================================

(defun ler-arquivo (caminho)
  "Lê um arquivo inteiro como string. NIL se não der.
Não confia em FILE-LENGTH porque arquivos do /proc reportam tamanho 0."
  (handler-case
      (with-open-file (f caminho :direction :input :if-does-not-exist nil)
        (when f
          (with-output-to-string (saida)
            (let ((buf (make-string 4096)))
              (loop for n = (read-sequence buf f)
                    do (write-string buf saida :end n)
                    while (= n (length buf)))))))
    (error () nil)))

(defun campo-de-proc (caminho prefixo)
  "Acha a primeira linha de CAMINHO que começa com PREFIXO e devolve o resto."
  (let ((texto (ler-arquivo caminho)))
    (when texto
      (with-input-from-string (s texto)
        (loop for linha = (read-line s nil)
              while linha
              when (and (>= (length linha) (length prefixo))
                        (string= prefixo linha :end2 (length prefixo)))
                do (return (string-trim '(#\Space #\Tab #\:)
                                        (subseq linha (length prefixo)))))))))

;;; ===========================================================================
;;; Comandos: operador
;;; ===========================================================================

(defun desligar ()
  "Desliga a máquina."
  (format t "~&~a~%" (amarelo "Desligando o Cerne. Até logo."))
  (reboot-cru +desligar+))

(defun reiniciar ()
  "Reinicia a máquina."
  (format t "~&~a~%" (amarelo "Reiniciando o Cerne..."))
  (reboot-cru +reiniciar+))

(defun memoria ()
  "Mostra uso de memória dinâmica do Lisp."
  (let ((usada (sb-ext:get-bytes-consed)))
    (format t "~&Memória já alocada nesta sessão: ~:D bytes (~,1F MiB)~%"
            usada (/ usada 1024.0 1024.0))
    (room nil))
  (values))

(defun tempo ()
  "Mostra há quanto tempo o REPL está vivo (relógio interno do Lisp)."
  (let ((seg (/ (get-internal-real-time) internal-time-units-per-second)))
    (format t "~&REPL vivo há ~,1F segundos.~%" seg))
  (values))

;;; ===========================================================================
;;; Comandos: introspecção do sistema (via /proc)
;;; ===========================================================================

(defun uptime ()
  "Tempo que a máquina está ligada, lido de /proc/uptime."
  (let ((texto (ler-arquivo "/proc/uptime")))
    (if texto
        (let ((seg (read-from-string texto nil 0)))
          (multiple-value-bind (m s) (floor (round seg) 60)
            (multiple-value-bind (h m) (floor m 60)
              (format t "~&Máquina ligada há ~dh ~dm ~ds (~,1Fs)~%" h m s seg))))
        (format t "~&/proc/uptime indisponível.~%")))
  (values))

(defun meminfo ()
  "Resumo de memória RAM, lido de /proc/meminfo."
  (flet ((kb (campo)
           (let ((v (campo-de-proc "/proc/meminfo" campo)))
             (when v (read-from-string v nil 0)))))
    (let ((total (kb "MemTotal:")) (livre (kb "MemFree:")) (disp (kb "MemAvailable:")))
      (if total
          (format t "~&RAM total:      ~:D MiB~%RAM livre:      ~:D MiB~%RAM disponível: ~:D MiB~%"
                  (round total 1024) (round (or livre 0) 1024) (round (or disp 0) 1024))
          (format t "~&/proc/meminfo indisponível.~%"))))
  (values))

(defun cpuinfo ()
  "Modelo da CPU e número de núcleos, lido de /proc/cpuinfo."
  (let ((modelo (campo-de-proc "/proc/cpuinfo" "model name"))
        (texto (ler-arquivo "/proc/cpuinfo")))
    (let ((nucleos (if texto
                       (with-input-from-string (s texto)
                         (loop for l = (read-line s nil) while l
                               count (and (>= (length l) 10)
                                          (string= "processor" l :end2 9))))
                       0)))
      (format t "~&CPU:     ~a~%Núcleos: ~d~%"
              (or modelo "desconhecida") nucleos)))
  (values))

(defun data ()
  "Data e hora atuais em UTC (relógio do hardware via gettimeofday)."
  (multiple-value-bind (s m h dia mes ano dow)
      (decode-universal-time (get-universal-time) 0)
    (let ((dias #("seg" "ter" "qua" "qui" "sex" "sáb" "dom")))
      (format t "~&~a ~2,'0d/~2,'0d/~d ~2,'0d:~2,'0d:~2,'0d UTC~%"
              (aref dias dow) dia mes ano h m s)))
  (values))

;;; ===========================================================================
;;; Comandos: loja chave-valor em RAM (persiste enquanto a máquina viver)
;;; ===========================================================================

(defparameter *kv* (make-hash-table :test 'equal))

(defun lembrar (chave valor)
  "Guarda VALOR sob CHAVE na memória do núcleo."
  (setf (gethash chave *kv*) valor)
  (format t "~&Guardado: ~s => ~s~%" chave valor)
  valor)

(defun recordar (chave)
  "Recupera o valor guardado sob CHAVE."
  (multiple-value-bind (v achou) (gethash chave *kv*)
    (if achou
        (progn (format t "~&~s => ~s~%" chave v) v)
        (format t "~&Nada guardado sob ~s.~%" chave))))

(defun esquecer (chave)
  "Apaga o que estava guardado sob CHAVE."
  (if (remhash chave *kv*)
      (format t "~&Esquecido: ~s~%" chave)
      (format t "~&Nada para esquecer em ~s.~%" chave))
  (values))

(defun tudo-que-lembro ()
  "Lista tudo na loja chave-valor."
  (if (zerop (hash-table-count *kv*))
      (format t "~&A loja está vazia.~%")
      (maphash (lambda (k v) (format t "~&  ~s => ~s~%" k v)) *kv*))
  (values))

;;; ===========================================================================
;;; Comandos: diversão
;;; ===========================================================================

(defun mandelbrot (&optional (largura 78) (altura 26) (iteracoes 50))
  "Desenha o conjunto de Mandelbrot em ASCII colorido."
  (let ((paleta " .:-=+*#%@"))
    (dotimes (linha altura)
      (let ((ci (- (* (/ linha altura) 2.2) 1.1)))
        (dotimes (col largura)
          (let ((cr (- (* (/ col largura) 3.0) 2.1))
                (zr 0.0) (zi 0.0) (n 0))
            (loop while (and (< n iteracoes) (< (+ (* zr zr) (* zi zi)) 4.0))
                  do (let ((novo-zr (+ (- (* zr zr) (* zi zi)) cr)))
                       (setf zi (+ (* 2.0 zr zi) ci)
                             zr novo-zr)
                       (incf n)))
            (let* ((dentro (>= n iteracoes))
                   (ch (if dentro
                           #\@
                           (char paleta (min (1- (length paleta))
                                             (floor (* n (length paleta)) iteracoes)))))
                   ;; cor ANSI 31..36 conforme a velocidade de fuga
                   (cod (format nil "3~d" (1+ (mod n 6)))))
              (write-string (if dentro (string ch) (cor cod (string ch)))
                            *standard-output*))))
        (terpri))))
  (values))

(defun adivinhe (&optional (maximo 100))
  "Jogo: pense que EU pensei num número de 1 a MAXIMO e adivinhe."
  (setf *random-state* (make-random-state t))
  (let ((alvo (1+ (random maximo)))
        (tentativas 0))
    (format t "~&Pensei num número de 1 a ~d. Adivinhe (digite o número):~%" maximo)
    (loop
      (format t "palpite> ") (finish-output)
      (let ((p (read *standard-input* nil :fim)))
        (cond
          ((eq p :fim) (format t "~&Desisti. Era ~d.~%" alvo) (return))
          ((not (integerp p)) (format t "~&Digite um número inteiro.~%"))
          (t (incf tentativas)
             (cond
               ((< p alvo) (format t "~&Mais alto.~%"))
               ((> p alvo) (format t "~&Mais baixo.~%"))
               (t (format t "~&Acertou! Era ~d, em ~d tentativa(s).~%"
                          alvo tentativas)
                  (return))))))))
  (values))

;;; ===========================================================================
;;; Ajuda
;;; ===========================================================================

(defun ajuda ()
  "Lista os comandos disponíveis."
  (format t "~&~a~%~
  Operador:~%~
    (ajuda) (memoria) (tempo) (reiniciar) (desligar)~%~
  Sistema (via /proc):~%~
    (uptime) (meminfo) (cpuinfo) (data)~%~
  Memória chave-valor:~%~
    (lembrar chave valor) (recordar chave) (esquecer chave) (tudo-que-lembro)~%~
  Diversão:~%~
    (mandelbrot) (adivinhe)~%~
~%  Fora isso, é Common Lisp puro: (+ 1 2 3), (loop for i below 5 collect (* i i))~%"
          (negrito "Comandos do Cerne (tudo é Lisp — chame como função):"))
  (values))

;;; ===========================================================================
;;; Banner de boot
;;; ===========================================================================

(defparameter *bandeira*
  "
   ____
  / ___|___ _ __ _ __   ___
 | |   / _ \\ '__| '_ \\ / _ \\     Cerne — núcleo Lisp inicializável
 | |__|  __/ |  | | | |  __/     SBCL rodando direto como PID 1
  \\____\\___|_|  |_| |_|\\___|     Sem shell. Sem SO. Só parênteses.
")

(defun banner ()
  (format t "~a~%" (verde *bandeira*))
  (format t "SBCL ~a — digite ~a para começar.~%~%"
          (lisp-implementation-version) (ciano "(ajuda)")))

;;; ===========================================================================
;;; Laço de leitura-avaliação-impressão (REPL)
;;; ===========================================================================

(defun repl ()
  "REPL simples em português, à prova de erros."
  (loop
    (format t "~a " (ciano "cerne>"))
    (finish-output)
    (let ((forma (handler-case (read *standard-input* nil :fim-do-arquivo)
                   (error (e)
                     (format t "~&Erro de leitura: ~a~%" e)
                     :erro-leitura))))
      (cond
        ((eq forma :fim-do-arquivo)
         (format t "~&Entrada encerrada.~%")
         (return))
        ((eq forma :erro-leitura)
         (read-line *standard-input* nil nil))
        (t
         (handler-case
             (let ((resultados (multiple-value-list (eval forma))))
               (if resultados
                   (dolist (r resultados) (format t "~&~a ~s~%" (amarelo "=>") r))
                   (format t "~&; sem valor~%")))
           (error (e)
             (format t "~&~a ~a~%" (amarelo "Falha ao avaliar:") e))))))))

;;; ===========================================================================
;;; Ponto de entrada (chamado pelo kernel como /init)
;;; ===========================================================================

(defun inicializar ()
  "Função de entrada do binário. É o PID 1 da máquina."
  ;; Como PID 1, se a gente sair, o kernel entra em pânico.
  ;; Então montamos os FS, protegemos tudo e, no fim, desligamos limpo.
  (montar-sistemas-de-arquivos)
  (setf *package* (find-package :cerne))   ; (ajuda)/(desligar) resolvem direto
  (handler-case
      (progn
        (banner)
        (repl))
    (sb-sys:interactive-interrupt ()
      (format t "~&Interrupção recebida.~%"))
    (error (e)
      (format t "~&Erro fatal no núcleo: ~a~%" e)))
  (desligar)
  ;; Se reboot falhar, trava aqui em vez de causar pânico no kernel.
  (loop (sleep 3600)))
