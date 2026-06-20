;;;; Cerne — núcleo Lisp inicializável (unikernel)
;;;;
;;;; Este arquivo vira o processo de inicialização (PID 1) da máquina.
;;;; Ao ligar, o kernel Linux carrega este binário diretamente como /init,
;;;; sem shell, sem systemd, sem espaço de usuário — só parênteses.
;;;;
;;;; Tudo escrito em português do Brasil de propósito.

(require :sb-posix)         ; opendir/readdir, para listar diretórios (inclui /proc)
(require :sb-bsd-sockets)   ; sockets TCP, para o REPL via telnet

(defpackage :cerne
  (:use :cl)
  (:export :inicializar
           ;; operador
           :ajuda :desligar :reiniciar :memoria :tempo :cronometrar
           ;; introspecção do sistema
           :uptime :meminfo :cpuinfo :data :uname :cmdline :modulos :pci :rtc
           ;; sistema de arquivos
           :arquivos :ver
           ;; rede
           :rede :telnet
           ;; loja chave-valor
           :lembrar :recordar :esquecer :tudo-que-lembro
           ;; persistência em disco cru
           :salvar :restaurar :disco-bruto
           ;; meta / Lisp
           :quine :desmontar :macroexpandir
           ;; diversão
           :mandelbrot :adivinhe :vida :vaca :pi-digitos :historico
           :matrix :fortune :senha :cores :relogio :arvore :grafico
           :fogo :plasma :snake))

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

;; finit_module(2): carrega um módulo do kernel a partir de um descritor.
;; Número da syscall no x86_64 = 313.
(sb-alien:define-alien-routine ("syscall" sys-finit-module) sb-alien:long
  (numero sb-alien:long)
  (fd sb-alien:int)
  (parametros sb-alien:c-string)
  (flags sb-alien:int))

(defun carregar-modulo (caminho)
  "Insere um módulo .ko (descomprimido) no kernel. Usado pra ter /dev/vda."
  (handler-case
      (with-open-file (s caminho :element-type '(unsigned-byte 8)
                                 :if-does-not-exist nil)
        (when s
          (zerop (sys-finit-module 313 (sb-sys:fd-stream-fd s) "" 0))))
    (error () nil)))

(defparameter *disco* "/dev/vda" "Bloco onde a loja chave-valor é persistida.")

(defun esperar-disco (&optional (tentativas 25))
  "Espera o devtmpfs criar o node /dev/vda, sem dormir mais que o necessário."
  (loop repeat tentativas
        when (probe-file *disco*) return t
        do (sleep 0.02)))

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

(defun uname ()
  "Versão e identificação do kernel, lidos de /proc/sys/kernel/."
  (flet ((ler (c) (let ((s (ler-arquivo c)))
                    (and s (string-trim '(#\Newline #\Space) s)))))
    (format t "~&~a ~a~%~a~%"
            (or (ler "/proc/sys/kernel/ostype") "Linux")
            (or (ler "/proc/sys/kernel/osrelease") "?")
            (or (ler "/proc/sys/kernel/version") "")))
  (values))

(defun cmdline ()
  "Argumentos de boot passados pelo kernel (/proc/cmdline)."
  (let ((s (ler-arquivo "/proc/cmdline")))
    (format t "~&~a" (or s "/proc/cmdline indisponível.~%")))
  (values))

(defun modulos ()
  "Lista os módulos do kernel carregados (/proc/modules)."
  (let ((txt (ler-arquivo "/proc/modules")))
    (if (and txt (plusp (length txt)))
        (with-input-from-string (s txt)
          (loop for l = (read-line s nil) while l
                do (format t "~&  ~a~%" (subseq l 0 (or (position #\Space l)
                                                        (length l))))))
        (format t "~&Nenhum módulo carregado.~%")))
  (values))

(defun pci ()
  "Lista os dispositivos PCI lendo /sys/bus/pci/devices/."
  (let ((dir "/sys/bus/pci/devices"))
    (handler-case
        (let ((d (sb-posix:opendir dir)) (achou nil))
          (unwind-protect
               (loop for e = (sb-posix:readdir d)
                     until (sb-alien:null-alien e)
                     for nome = (sb-posix:dirent-name e)
                     unless (member nome '("." "..") :test #'string=)
                       do (setf achou t)
                          (flet ((campo (c)
                                   (let ((s (ler-arquivo (format nil "~a/~a/~a" dir nome c))))
                                     (and s (string-trim '(#\Newline #\Space) s)))))
                            (format t "~&  ~a  ~a:~a  classe ~a~%"
                                    nome
                                    (or (campo "vendor") "?")
                                    (or (campo "device") "?")
                                    (or (campo "class") "?"))))
            (sb-posix:closedir d))
          (unless achou (format t "~&Nenhum dispositivo PCI.~%")))
      (error (e) (format t "~&Não consegui ler ~a: ~a~%" dir e))))
  (values))

(defun cmos (registrador)
  "Lê um registrador do chip RTC/CMOS via as portas 0x70/0x71 (/dev/port)."
  (with-open-file (p "/dev/port" :direction :io
                                 :element-type '(unsigned-byte 8)
                                 :if-exists :overwrite)
    (file-position p #x70) (write-byte registrador p) (finish-output p)
    (file-position p #x71) (read-byte p)))

(defun rtc ()
  "Lê data/hora direto do chip RTC pela porta de I/O (flex bare-metal)."
  (handler-case
      (flet ((bcd (v) (+ (* 10 (ash v -4)) (logand v #x0f))))
        (let ((s (bcd (cmos 0))) (mi (bcd (cmos 2))) (h (bcd (cmos 4)))
              (d (bcd (cmos 7))) (mo (bcd (cmos 8))) (a (bcd (cmos 9))))
          (format t "~&RTC (chip, via porta 0x70/0x71): ~2,'0d/~2,'0d/20~2,'0d ~2,'0d:~2,'0d:~2,'0d~%"
                  d mo a h mi s)))
    (error (e) (format t "~&Não consegui ler o RTC: ~a~%" e)))
  (values))

(defmacro cronometrar (&body corpo)
  "Avalia CORPO e imprime quanto tempo levou. Macro — porque é Lisp."
  (let ((t0 (gensym)))
    `(let ((,t0 (get-internal-real-time)))
       (multiple-value-prog1 (progn ,@corpo)
         (format t "~&; ~,3F ms~%"
                 (* 1000.0 (/ (- (get-internal-real-time) ,t0)
                              internal-time-units-per-second)))))))

(defun data ()
  "Data e hora atuais em UTC (relógio do hardware via gettimeofday)."
  (multiple-value-bind (s m h dia mes ano dow)
      (decode-universal-time (get-universal-time) 0)
    (let ((dias #("seg" "ter" "qua" "qui" "sex" "sáb" "dom")))
      (format t "~&~a ~2,'0d/~2,'0d/~d ~2,'0d:~2,'0d:~2,'0d UTC~%"
              (aref dias dow) dia mes ano h m s)))
  (values))

;;; ===========================================================================
;;; Comandos: sistema de arquivos (explore o /proc, /sys, /dev)
;;; ===========================================================================

(defun arquivos (&optional (caminho "/"))
  "Lista o conteúdo de um diretório (estilo ls)."
  (handler-case
      (let ((d (sb-posix:opendir caminho)))
        (unwind-protect
             ;; readdir devolve um alien; o fim é um ponteiro NULL, não NIL.
             (loop for e = (sb-posix:readdir d)
                   until (sb-alien:null-alien e)
                   for nome = (sb-posix:dirent-name e)
                   unless (member nome '("." "..") :test #'string=)
                     do (format t "~&  ~a~%" nome))
          (sb-posix:closedir d)))
    (error (e) (format t "~&Não consegui listar ~a: ~a~%" caminho e)))
  (values))

(defun ver (caminho)
  "Mostra o conteúdo de um arquivo (estilo cat)."
  (let ((texto (ler-arquivo caminho)))
    (if texto
        (write-string texto)
        (format t "~&Não consegui ler ~a~%" caminho)))
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
;;; Comandos: persistência em disco CRU (sem sistema de arquivos!)
;;;
;;; A loja chave-valor é gravada como uma S-expressão direto nos primeiros
;;; bytes do bloco /dev/vda. Nada de ext4, FAT ou partição — só bytes no
;;; disco. Bem no espírito bare-metal.
;;; ===========================================================================

(defun kv->alist ()
  (let (acc) (maphash (lambda (k v) (push (cons k v) acc)) *kv*) acc))

(defun salvar ()
  "Grava a loja chave-valor direto no bloco /dev/vda."
  (handler-case
      (with-open-file (f *disco* :direction :output
                                 :if-exists :overwrite
                                 :if-does-not-exist :error)
        ;; uma S-expressão legível, seguida de espaço terminador
        (let ((*print-readably* nil) (*print-pretty* nil))
          (prin1 (kv->alist) f)
          (write-char #\Space f))
        (format t "~&Loja gravada em ~a (~d itens).~%"
                *disco* (hash-table-count *kv*)))
    (error (e) (format t "~&Não consegui salvar: ~a~%" e)))
  (values))

(defun restaurar (&optional (silencioso nil))
  "Recarrega a loja chave-valor a partir do bloco /dev/vda."
  (handler-case
      (with-open-file (f *disco* :direction :input :if-does-not-exist nil)
        (when f
          (let* ((*read-eval* nil)            ; nunca avalia #. de disco
                 (dados (read f nil nil)))
            (when (listp dados)
              (clrhash *kv*)
              (dolist (par dados)
                (setf (gethash (car par) *kv*) (cdr par)))
              (unless silencioso
                (format t "~&Loja restaurada de ~a (~d itens).~%"
                        *disco* (hash-table-count *kv*)))
              (return-from restaurar (values))))))
    (error (e) (unless silencioso
                 (format t "~&Não consegui restaurar: ~a~%" e))))
  (unless silencioso (format t "~&Nada salvo em ~a ainda.~%" *disco*))
  (values))

(defun disco-bruto (&optional (n 128))
  "Hexdump dos primeiros N bytes do bloco /dev/vda — os bytes crus da loja."
  (handler-case
      (with-open-file (f *disco* :element-type '(unsigned-byte 8)
                                 :if-does-not-exist nil)
        (if (null f)
            (format t "~&~a indisponível.~%" *disco*)
            (let ((buf (make-array n :element-type '(unsigned-byte 8))))
              (let ((lidos (read-sequence buf f)))
                (loop for base from 0 below lidos by 16 do
                  (format t "~&~4,'0X  " base)
                  (loop for i from base below (min lidos (+ base 16))
                        do (format t "~2,'0X " (aref buf i)))
                  (loop repeat (- (+ base 16) (min lidos (+ base 16)))
                        do (format t "   "))
                  (write-string " |")
                  (loop for i from base below (min lidos (+ base 16))
                        for b = (aref buf i)
                        do (write-char (if (<= 32 b 126) (code-char b) #\.)))
                  (write-char #\|))))))
    (error (e) (format t "~&Erro lendo o disco: ~a~%" e)))
  (values))

;;; ===========================================================================
;;; Comandos: meta (o Lisp olhando pra si mesmo)
;;; ===========================================================================

(defun quine ()
  "Mostra uma forma que se reproduz quando avaliada (um quine)."
  (let ((q '((lambda (x) (list x (list 'quote x)))
             '(lambda (x) (list x (list 'quote x))))))
    (format t "~&Forma que se reproduz ao ser avaliada:~%")
    (let ((*print-pretty* nil)) (prin1 q) (terpri))
    (format t "; (eval forma) é igual à forma? ~a~%" (equal q (eval q))))
  (values))

(defun desmontar (fn)
  "Mostra o código de máquina de uma função (FN pode ser símbolo ou função).
Prova que o Cerne compila Lisp pra instruções reais da CPU."
  (disassemble (if (symbolp fn) (symbol-function fn) fn))
  (values))

(defun macroexpandir (forma)
  "Expande uma macro um nível. Passe a forma com quote: (macroexpandir '(when a b))."
  (let ((*print-pretty* t))
    (prin1 (macroexpand-1 forma)) (terpri))
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

(defun vida (&optional (geracoes 40) (largura 60) (altura 22))
  "Jogo da Vida de Conway, animado no terminal (sopa aleatória inicial)."
  (setf *random-state* (make-random-state t))
  (let ((g (make-array (list altura largura)))
        (esc (code-char 27)))
    (dotimes (y altura) (dotimes (x largura)
                          (setf (aref g y x) (if (< (random 100) 30) 1 0))))
    (flet ((vizinhos (y x)
             (let ((c 0))
               (loop for dy from -1 to 1 do
                 (loop for dx from -1 to 1 do
                   (unless (and (zerop dy) (zerop dx))
                     (incf c (aref g (mod (+ y dy) altura)
                                     (mod (+ x dx) largura))))))
               c)))
      (dotimes (_ geracoes)
        (format t "~c[2J~c[H" esc esc)          ; limpa tela e volta ao topo
        (dotimes (y altura)
          (dotimes (x largura)
            (if (plusp (aref g y x))
                (write-string (verde "#"))
                (write-char #\Space)))
          (terpri))
        (finish-output)
        (sleep 0.08)
        (let ((novo (make-array (list altura largura))))
          (dotimes (y altura)
            (dotimes (x largura)
              (let ((n (vizinhos y x)) (viva (plusp (aref g y x))))
                (setf (aref novo y x)
                      (if (or (= n 3) (and viva (= n 2))) 1 0)))))
          (setf g novo)))))
  (values))

(defun vaca (&optional (texto "Mééé! Lisp no metal."))
  "Cowsay em português. A vaca diz o que você mandar."
  (let* ((s (princ-to-string texto)) (n (length s)))
    (format t "~& ~a~%" (make-string (+ n 2) :initial-element #\_))
    (format t " < ~a >~%" s)
    (format t " ~a~%" (make-string (+ n 2) :initial-element #\-))
    (write-line "        \\   ^__^")
    (write-line "         \\  (oo)\\_______")
    (write-line "            (__)\\       )\\/\\")
    (write-line "                ||----w |")
    (write-line "                ||     ||"))
  (values))

(defun pi-digitos (&optional (digitos 50))
  "Calcula DIGITOS casas de π pela fórmula de Machin, em aritmética exata.
   pi = 16*arctan(1/5) - 4*arctan(1/239)"
  ;; usa uma casa extra de guarda pra não arredondar errado a última
  (let ((escala (expt 10 (+ digitos 2))))
    (flet ((arctan-inv (x)
             (let ((soma 0) (k 0)
                   (potencia (truncate escala x))
                   (x2 (* x x)))
               (loop while (/= potencia 0) do
                 (let ((parcela (truncate potencia (1+ (* 2 k)))))
                   (if (evenp k) (incf soma parcela) (decf soma parcela)))
                 (setf potencia (truncate potencia x2))
                 (incf k))
               soma)))
      (let ((p (truncate (- (* 16 (arctan-inv 5)) (* 4 (arctan-inv 239))) 100)))
        (multiple-value-bind (inteiro resto) (truncate p (expt 10 digitos))
          (format t "~&~d.~v,'0d~%" inteiro digitos resto)))))
  (values))

(defvar *historico* '() "Formas avaliadas nesta sessão, mais recente primeiro.")

(defun historico ()
  "Mostra os comandos avaliados nesta sessão."
  (if (null *historico*)
      (format t "~&Histórico vazio.~%")
      (loop for forma in (reverse *historico*)
            for i from 1
            do (format t "~&~3d  ~s~%" i forma)))
  (values))

(defun matrix (&optional (quadros 120) (largura 78) (altura 24))
  "Chuva digital estilo Matrix, em verde no terminal."
  (setf *random-state* (make-random-state t))
  (let ((esc (code-char 27))
        (alfa "01ABCDEFGHIKLMNPRSTVXZ#$%&*+=<>?@")
        (gotas (make-array largura))
        (rastro 9))
    (dotimes (c largura) (setf (aref gotas c) (- (random altura))))
    (flet ((sorteia () (char alfa (random (length alfa)))))
      (format t "~c[2J" esc)
      (dotimes (_ quadros)
        (format t "~c[H" esc)                ; volta ao topo (sem limpar = menos flicker)
        (dotimes (y altura)
          (dotimes (c largura)
            (let ((d (- (aref gotas c) y)))   ; distância acima da cabeça
              (cond
                ((= d 0)  (format t "~c[1;37m~c" esc (sorteia)))   ; cabeça branca
                ((<= 1 d rastro)
                 (format t "~c[0;32m~c" esc (sorteia)))            ; rastro verde
                (t (write-char #\Space)))))
          (terpri))
        (format t "~c[0m" esc)
        (finish-output)
        (sleep 0.06)
        (dotimes (c largura)
          (incf (aref gotas c))
          (when (> (- (aref gotas c) rastro) altura)
            (setf (aref gotas c) (- (random (truncate altura 2)))))))
      (format t "~c[0m" esc)))
  (values))

(defparameter *fortunes*
  '("LISP: a única linguagem que é seu próprio interpretador."
    "Todo programa cresce até poder ler e-mail. O Cerne ainda resiste."
    "Não há sistema operacional. Há apenas o REPL."
    "Parênteses não são complexidade. São honestidade."
    "Macros: quando você quer reescrever a linguagem antes do café."
    "O metal é frio. O Lisp é eterno."
    "Garbage collector roda. A consciência, não."
    "Quem precisa de shell quando se tem eval?"
    "A recursão é só um loop que confia em si mesmo."
    "Code is data. Data is code. O resto é detalhe."
    "Greenspun, regra 10: todo programa grande contém um Lisp mal feito."
    "car, cdr, e a fé de que a lista tem fim."
    "PID 1 não pede permissão. PID 1 é a permissão."
    "Booto, logo penso. Penso em S-expressões."
    "Não existe bug. Existe um caso que você ainda não fez quote."
    "O kernel dá os syscalls. O Lisp dá os parênteses. Casamento perfeito."
    "Lambda é o operador. O resto é açúcar."
    "Quem controla as macros controla o universo."
    "Closures: variáveis que se recusam a morrer."
    "setq é confissão. let é redenção."
    "Em caso de pânico do kernel: respire, e (desligar)."
    "Homoiconicidade: a palavra mais difícil que você vai amar."
    "Tail call: a recursão que não enche a pilha de orgulho."
    "Memória é volátil. /dev/vda nem tanto. Use (salvar)."
    "Um nil bem colocado vale mais que mil ifs."
    "Compilar é só pedir desculpa ao processador com antecedência."
    "O verdadeiro unikernel mora no coração de quem evita o systemd."
    "A vaca diz mééé. O Lisp diz (quote mééé)."
    "Stack overflow não é um site. É um estilo de vida recursivo."
    "Primeiro resolva o problema. Depois escreva a macro."))

(defun fortune ()
  "Imprime uma frase aleatória."
  (setf *random-state* (make-random-state t))
  (format t "~&~a~%" (ciano (nth (random (length *fortunes*)) *fortunes*)))
  (values))

(defun senha (&optional (tamanho 16))
  "Gera uma senha forte usando entropia de /dev/urandom."
  (let ((alfa "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#%&*+=?")
        (saida (make-string tamanho)))
    (handler-case
        (with-open-file (f "/dev/urandom" :element-type '(unsigned-byte 8))
          (dotimes (i tamanho)
            (setf (char saida i) (char alfa (mod (read-byte f) (length alfa))))))
      (error ()
        ;; sem /dev/urandom, cai no PRNG do Lisp
        (setf *random-state* (make-random-state t))
        (dotimes (i tamanho)
          (setf (char saida i) (char alfa (random (length alfa)))))))
    (format t "~&~a~%" (amarelo saida)))
  (values))

(defun cores ()
  "Mostra a paleta de cores ANSI que o terminal suporta."
  (let ((esc (code-char 27)))
    (dolist (base '(30 90))
      (loop for c from base to (+ base 7)
            do (format t "~c[~am ~3d ~c[0m" esc c c esc))
      (terpri))
    (dolist (base '(40 100))
      (loop for c from base to (+ base 7)
            do (format t "~c[~am ~3d ~c[0m" esc c c esc))
      (terpri)))
  (values))

(defparameter *digitos-grandes*
  (let ((h (make-hash-table)))
    (flet ((p (ch &rest linhas) (setf (gethash ch h) linhas)))
      (p #\0 "####" "#  #" "#  #" "#  #" "####")
      (p #\1 "  # " " ## " "  # " "  # " " ###")
      (p #\2 "####" "   #" "####" "#   " "####")
      (p #\3 "####" "   #" " ###" "   #" "####")
      (p #\4 "#  #" "#  #" "####" "   #" "   #")
      (p #\5 "####" "#   " "####" "   #" "####")
      (p #\6 "####" "#   " "####" "#  #" "####")
      (p #\7 "####" "   #" "  # " " #  " " #  ")
      (p #\8 "####" "#  #" "####" "#  #" "####")
      (p #\9 "####" "#  #" "####" "   #" "####")
      (p #\: "    " " ## " "    " " ## " "    "))
    h))

(defun relogio (&optional (segundos 10))
  "Relógio digital grande, ao vivo, em UTC (Ctrl-C ou aguarde o fim)."
  (let ((esc (code-char 27)))
    (dotimes (_ segundos)
      (multiple-value-bind (s m h) (decode-universal-time (get-universal-time) 0)
        (let ((txt (format nil "~2,'0d:~2,'0d:~2,'0d" h m s)))
          (format t "~c[2J~c[H~%~%" esc esc)
          (dotimes (linha 5)
            (write-string "   ")
            (loop for ch across txt
                  for padrao = (gethash ch *digitos-grandes*)
                  do (write-string (ciano (if padrao (nth linha padrao) "    ")))
                     (write-string " "))
            (terpri))
          (finish-output)))
      (sleep 1)))
  (values))

(defun arvore (&optional (profundidade 9) (largura 70) (altura 30))
  "Desenha uma árvore fractal em ASCII."
  (let ((grade (make-array (list altura largura) :initial-element #\Space)))
    (labels ((plota (x y c)
               (let ((ix (round x)) (iy (round y)))
                 (when (and (<= 0 iy (1- altura)) (<= 0 ix (1- largura)))
                   (setf (aref grade iy ix) c))))
             (galho (x y angulo comprimento prof)
               (let* ((x2 (+ x (* (cos angulo) comprimento)))
                      (y2 (- y (* (sin angulo) comprimento)))
                      (passos (max 1 (round comprimento)))
                      (c (cond ((> (cos angulo) 0.4) #\\)
                               ((< (cos angulo) -0.4) #\/)
                               (t #\|))))
                 (dotimes (i (1+ passos))
                   (let ((tt (/ i passos)))
                     (plota (+ x (* (- x2 x) tt)) (+ y (* (- y2 y) tt))
                            (if (zerop prof) #\* c))))
                 (when (> prof 0)
                   (galho x2 y2 (+ angulo 0.5) (* comprimento 0.72) (1- prof))
                   (galho x2 y2 (- angulo 0.5) (* comprimento 0.72) (1- prof))))))
      (galho (/ largura 2.0) (1- altura) (/ pi 2) (/ altura 3.2) profundidade)
      (dotimes (y altura)
        (dotimes (x largura)
          (let ((c (aref grade y x)))
            (if (char= c #\*) (write-string (verde "*")) (write-char c))))
        (terpri))))
  (values))

(defun grafico (dados &optional (altura 10))
  "Gráfico de barras ASCII de uma lista de números."
  (when dados
    (let* ((maxv (reduce #'max dados))
           (maxv (if (zerop maxv) 1 maxv)))
      (loop for r from altura downto 1 do
        (dolist (v dados)
          (if (>= (* (/ v maxv) altura) r)
              (write-string (ciano "##"))
              (write-string "  "))
          (write-char #\Space))
        (terpri))
      (dotimes (i (length dados)) (write-string "---"))
      (terpri)))
  (values))

(defun fogo (&optional (frames 90) (largura 70) (altura 24))
  "Efeito de fogo ASCII animado (estilo demoscene)."
  (setf *random-state* (make-random-state t))
  (let ((g (make-array (list (1+ altura) largura) :initial-element 0))
        (paleta " ..::!!**##@@")
        (esc (code-char 27)))
    (format t "~c[2J" esc)                 ; limpa a tela antes de começar
    (dotimes (_ frames)
      ;; base quente embaixo
      (dotimes (x largura) (setf (aref g altura x) (random 12)))
      ;; propaga pra cima com resfriamento
      (loop for y from (1- altura) downto 0 do
        (dotimes (x largura)
          (let ((soma (+ (aref g (1+ y) x)
                         (aref g (1+ y) (mod (1- x) largura))
                         (aref g (1+ y) (mod (1+ x) largura))
                         (aref g (min altura (+ y 2)) x))))
            (setf (aref g y x) (max 0 (- (truncate soma 4) (if (zerop (random 3)) 1 0)))))))
      (format t "~c[H" esc)
      (dotimes (y altura)
        (dotimes (x largura)
          (let* ((v (min 11 (aref g y x)))
                 (cor (cond ((>= v 9) "1;37") ((>= v 6) "1;33")
                            ((>= v 3) "0;31") (t "0;31"))))
            (format t "~c[~am~c" esc cor (char paleta v))))
        (terpri))
      (format t "~c[0m" esc) (finish-output)
      (sleep 0.05))
    (format t "~c[0m" esc))
  (values))

(defun plasma (&optional (frames 80) (largura 72) (altura 24))
  "Plasma colorido animado (combinação de senos), em cores 256."
  (let ((esc (code-char 27)))
    (format t "~c[2J" esc)
    (dotimes (f frames)
      (format t "~c[H" esc)
      (dotimes (y altura)
        (dotimes (x largura)
          (let* ((v (+ (sin (+ (/ x 6.0) (* f 0.2)))
                       (sin (/ y 4.0))
                       (sin (/ (+ x y) 8.0))
                       (sin (+ (/ (sqrt (+ (* x x) (* y y))) 7.0) (* f 0.15)))))
                 ;; mapeia -4..4 para uma rampa de cores 256
                 (cor (+ 16 (mod (round (* (+ v 4) 32)) 216))))
            (format t "~c[48;5;~dm " esc cor)))
        (terpri))
      (format t "~c[0m" esc) (finish-output)
      (sleep 0.05))
    (format t "~c[0m~c[2J~c[H" esc esc esc))
  (values))

(defun snake (&optional (largura 40) (altura 18))
  "Jogo da cobra. Setas ou WASD pra virar, 'q' sai. Precisa de terminal."
  (setf *random-state* (make-random-state t))
  (let* ((esc (code-char 27))
         (cobra (list (cons (truncate largura 2) (truncate altura 2))))
         (dx 1) (dy 0)
         (comida (cons (random largura) (random altura)))
         (vivo t) (pontos 0))
    (labels ((tecla ()
               (loop while (listen *standard-input*)
                     do (let ((c (read-char *standard-input* nil nil)))
                          (cond
                            ((null c) (return))
                            ((char= c esc)
                             (when (and (listen *standard-input*)
                                        (eql (read-char *standard-input* nil nil) #\[))
                               (case (read-char *standard-input* nil nil)
                                 (#\A (unless (= dy 1) (setf dx 0 dy -1)))
                                 (#\B (unless (= dy -1) (setf dx 0 dy 1)))
                                 (#\C (unless (= dx -1) (setf dx 1 dy 0)))
                                 (#\D (unless (= dx 1) (setf dx -1 dy 0))))))
                            ((member c '(#\w #\W)) (unless (= dy 1) (setf dx 0 dy -1)))
                            ((member c '(#\s #\S)) (unless (= dy -1) (setf dx 0 dy 1)))
                            ((member c '(#\d #\D)) (unless (= dx -1) (setf dx 1 dy 0)))
                            ((member c '(#\a #\A)) (unless (= dx 1) (setf dx -1 dy 0)))
                            ((member c '(#\q #\Q)) (setf vivo nil))))))
             (desenha ()
               (format t "~c[H" esc)
               (format t "Cobra — pontos: ~d  (q sai)~%" pontos)
               (dotimes (y altura)
                 (dotimes (x largura)
                   (cond
                     ((member (cons x y) cobra :test #'equal) (write-string (verde "#")))
                     ((equal (cons x y) comida) (write-string (amarelo "@")))
                     (t (write-char #\.))))
                 (terpri))
               (finish-output)))
      (format t "~c[2J" esc)
      (loop while vivo do
        (tecla)
        (let* ((cab (car cobra))
               (nx (+ (car cab) dx)) (ny (+ (cdr cab) dy))
               (nova (cons nx ny)))
          (when (or (< nx 0) (>= nx largura) (< ny 0) (>= ny altura)
                    (member nova cobra :test #'equal))
            (setf vivo nil) (return))
          (push nova cobra)
          (if (equal nova comida)
              (progn (incf pontos)
                     (setf comida (cons (random largura) (random altura))))
              (setf cobra (nbutlast cobra)))
          (desenha)
          (sleep 0.11)))
      (format t "~c[2J~c[HFim de jogo! Pontos: ~d~%" esc esc pontos)))
  (values))

;;; ===========================================================================
;;; Ajuda
;;; ===========================================================================

(defun ajuda (&optional comando)
  "Lista os comandos. Com argumento, mostra a doc: (ajuda 'mandelbrot)."
  (if comando
      (let* ((sim (if (symbolp comando) comando
                      (and (functionp comando) (nth-value 2 (function-lambda-expression comando)))))
             (doc (and sim (documentation sim 'function))))
        (format t "~&~a: ~a~%" (or sim comando) (or doc "sem documentação")))
      (format t "~&~a~%~
  Operador:~%~
    (ajuda [cmd]) (memoria) (tempo) (cronometrar forma...) (reiniciar) (desligar)~%~
  Sistema (via /proc e /sys):~%~
    (uptime) (meminfo) (cpuinfo) (data) (uname) (cmdline) (modulos) (pci) (rtc)~%~
  Arquivos:~%~
    (arquivos \"/proc\") (ver \"/proc/cmdline\")~%~
  Rede:~%~
    (rede) (telnet 2323)~%~
  Lisp / meta:~%~
    (quine) (desmontar (quote fib)) (macroexpandir (quote (when a b)))~%~
  Memória chave-valor:~%~
    (lembrar chave valor) (recordar chave) (esquecer chave) (tudo-que-lembro)~%~
  Persistência em disco cru (/dev/vda, sem sistema de arquivos):~%~
    (salvar) (restaurar) (disco-bruto)~%~
  Diversão:~%~
    (mandelbrot) (vida) (matrix) (plasma) (fogo) (snake) (cores) (relogio 10)~%~
    (arvore) (grafico (list 3 7 2 9 5)) (vaca \"texto\") (pi-digitos 80)~%~
    (adivinhe) (fortune) (senha 16) (historico)~%~
~%  Dica: setas ←→ movem, ↑↓ navegam o histórico de comandos.~%~
~%  Fora isso, é Common Lisp puro: (+ 1 2 3), (loop for i below 5 collect (* i i))~%"
          (negrito "Comandos do Cerne (tudo é Lisp — chame como função):")))
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
;;; Edição de linha (modo cru do terminal: setas, histórico, backspace)
;;; ===========================================================================

(defvar *termios-salvo* nil)
(defparameter *linhas* (make-array 0 :element-type t :adjustable t :fill-pointer 0)
  "Histórico de linhas digitadas, para navegar com as setas.")

(defun ativar-modo-cru ()
  "Põe a tty em modo cru (sem eco e sem buffer de linha). NIL se não for tty."
  (handler-case
      (let ((tm (sb-posix:tcgetattr 0)))
        (setf *termios-salvo* (sb-posix:tcgetattr 0))
        (setf (sb-posix:termios-lflag tm)
              (logandc2 (sb-posix:termios-lflag tm)
                        (logior sb-posix:icanon sb-posix:echo)))
        (sb-posix:tcsetattr 0 sb-posix:tcsanow tm)
        t)
    (error () nil)))

(defun restaurar-modo ()
  (when *termios-salvo*
    (ignore-errors (sb-posix:tcsetattr 0 sb-posix:tcsanow *termios-salvo*))))

(defun ler-linha-editada (prompt)
  "Lê uma linha com edição: setas ←→, ↑↓ (histórico), backspace, Ctrl-A/E/D.
Retorna a string, ou :eof."
  (let ((buf (make-array 16 :element-type 'character :adjustable t :fill-pointer 0))
        (cur 0)
        (nav (fill-pointer *linhas*))   ; índice no histórico; = tamanho => linha nova
        (esc (code-char 27)))
    (labels ((tam () (fill-pointer buf))
             (texto () (coerce buf 'string))
             (trocar (s)
               (setf (fill-pointer buf) 0)
               (loop for c across s do (vector-push-extend c buf))
               (setf cur (tam)))
             (inserir (c)
               (vector-push-extend #\Space buf)
               (loop for i from (1- (tam)) above cur do (setf (aref buf i) (aref buf (1- i))))
               (setf (aref buf cur) c)
               (incf cur))
             (apagar ()
               (when (> cur 0)
                 (loop for i from (1- cur) below (1- (tam)) do (setf (aref buf i) (aref buf (1+ i))))
                 (decf (fill-pointer buf))
                 (decf cur)))
             (redesenha ()
               (format t "~c~a~a~c[K" #\Return prompt (texto) esc)
               (when (< cur (tam)) (format t "~c[~dD" esc (- (tam) cur)))
               (finish-output)))
      (format t "~a" prompt) (finish-output)
      (loop
        (let ((c (read-char *standard-input* nil :eof)))
          (cond
            ((eq c :eof) (return :eof))
            ((or (char= c #\Return) (char= c #\Newline)) (terpri) (return (texto)))
            ((or (char= c #\Rubout) (char= c (code-char 8))) (apagar) (redesenha))
            ((char= c (code-char 1)) (setf cur 0) (redesenha))            ; Ctrl-A
            ((char= c (code-char 5)) (setf cur (tam)) (redesenha))        ; Ctrl-E
            ((char= c (code-char 4)) (when (zerop (tam)) (return :eof)))  ; Ctrl-D
            ((char= c esc)
             (when (eql (read-char *standard-input* nil :eof) #\[)
               (case (read-char *standard-input* nil :eof)
                 (#\C (when (< cur (tam)) (incf cur) (redesenha)))        ; →
                 (#\D (when (> cur 0) (decf cur) (redesenha)))            ; ←
                 (#\A (when (> nav 0)                                     ; ↑
                        (decf nav) (trocar (aref *linhas* nav)) (redesenha)))
                 (#\B (cond ((< nav (1- (fill-pointer *linhas*)))         ; ↓
                             (incf nav) (trocar (aref *linhas* nav)) (redesenha))
                            (t (setf nav (fill-pointer *linhas*)) (trocar "") (redesenha)))))))
            ((>= (char-code c) 32) (inserir c) (redesenha))))))))

;;; ===========================================================================
;;; Laço de leitura-avaliação-impressão (REPL)
;;; ===========================================================================

(defun ler-uma-linha (cru prompt)
  (if cru
      (ler-linha-editada prompt)
      (progn (format t "~a" prompt) (finish-output)
             (read-line *standard-input* nil :eof))))

(defun ler-forma (primeira cru)
  "Lê uma forma Lisp completa, pedindo mais linhas se estiver incompleta.
Retorna (values forma :ok) | (values nil :eof) | (values condição :erro)."
  (let ((texto primeira))
    (loop
      (handler-case
          (return (values (read-from-string texto) :ok))
        (end-of-file ()
          (let ((mais (ler-uma-linha cru "  ...> ")))
            (when (eq mais :eof) (return (values nil :eof)))
            (setf texto (concatenate 'string texto (string #\Newline) mais))))
        (error (e) (return (values e :erro)))))))

(defun repl (&optional (editar t))
  "REPL em português, com edição de linha quando há terminal.
EDITAR nil desliga o modo cru (usado quando se serve por rede)."
  (let ((cru (and editar (ativar-modo-cru))))
    (unwind-protect
         (loop
           (let ((linha (ler-uma-linha cru (format nil "~a " (ciano "cerne>")))))
             (cond
               ((eq linha :eof) (format t "~&Entrada encerrada.~%") (return))
               ((string= (string-trim '(#\Space #\Tab) linha) "") nil)
               (t
                (when (and cru (plusp (length linha)))
                  (vector-push-extend linha *linhas*))
                (multiple-value-bind (forma estado) (ler-forma linha cru)
                  (case estado
                    (:eof (format t "~&Entrada encerrada.~%") (return))
                    (:erro (format t "~&Erro de leitura: ~a~%" forma))
                    (:ok
                     (push forma *historico*)
                     (handler-case
                         (let ((resultados (multiple-value-list (eval forma))))
                           (if resultados
                               (dolist (r resultados) (format t "~&~a ~s~%" (amarelo "=>") r))
                               (format t "~&; sem valor~%")))
                       (error (e)
                         (format t "~&~a ~a~%" (amarelo "Falha ao avaliar:") e))))))))))
      (restaurar-modo))))

;;; ===========================================================================
;;; Rede: sobe a interface virtio-net e serve um REPL por telnet
;;;
;;; A rede do QEMU em modo "user" entrega o IP fixo 10.0.2.15 ao convidado.
;;; Configuramos a interface na unha via ioctl (struct ifreq), sem ifconfig.
;;; ===========================================================================

(defparameter *ip-cerne* "10.0.2.15")
(defparameter *mascara* "255.255.255.0")
(defparameter *rede-pronta* nil)

(defun ip->bytes (s)
  "\"10.0.2.15\" -> (10 0 2 15)"
  (let (acc (n 0))
    (loop for c across s do
      (if (char= c #\.) (progn (push n acc) (setf n 0))
          (setf n (+ (* n 10) (- (char-code c) 48)))))
    (push n acc)
    (nreverse acc)))

(defun nome-interface ()
  "Primeira interface em /sys/class/net que não seja lo."
  (handler-case
      (let ((d (sb-posix:opendir "/sys/class/net")) (achado nil))
        (unwind-protect
             (loop for e = (sb-posix:readdir d)
                   until (sb-alien:null-alien e)
                   for n = (sb-posix:dirent-name e)
                   unless (member n '("." ".." "lo") :test #'string=)
                     do (setf achado n) (return))
          (sb-posix:closedir d))
        achado)
    (error () nil)))

(defmacro com-ifreq ((buf nome) &body corpo)
  "Aloca uma struct ifreq (40 bytes) zerada com o nome da interface."
  `(sb-alien:with-alien ((,buf (sb-alien:array sb-alien:unsigned-char 40)))
     (dotimes (i 40) (setf (sb-alien:deref ,buf i) 0))
     (loop for i below (min 15 (length ,nome))
           do (setf (sb-alien:deref ,buf i) (char-code (char ,nome i))))
     ,@corpo))

(defun ioctl-buf (fd req buf)
  (chamada-de-sistema 16 fd req (sb-sys:sap-int (sb-alien:alien-sap buf)) 0))

(defun definir-endereco (fd nome req ip)
  "SIOCSIFADDR / SIOCSIFNETMASK: grava um IP no campo sockaddr_in da ifreq."
  (com-ifreq (buf nome)
    (setf (sb-alien:deref buf 16) 2)          ; sin_family = AF_INET (little-endian)
    (let ((b (ip->bytes ip)))
      (loop for i below 4 do (setf (sb-alien:deref buf (+ 20 i)) (nth i b))))
    (ioctl-buf fd req buf)))

(defun subir-interface (fd nome)
  "SIOCGIFFLAGS + SIOCSIFFLAGS: liga os bits IFF_UP|IFF_RUNNING."
  (com-ifreq (buf nome)
    (ioctl-buf fd #x8913 buf)                  ; pega flags
    (let ((flags (logior (sb-alien:deref buf 16)
                         (ash (sb-alien:deref buf 17) 8)
                         1 64)))               ; IFF_UP | IFF_RUNNING
      (setf (sb-alien:deref buf 16) (logand flags #xff)
            (sb-alien:deref buf 17) (logand (ash flags -8) #xff)))
    (ioctl-buf fd #x8914 buf)))                ; aplica flags

(defun configurar-rede ()
  "Carrega os módulos de rede e configura a interface com IP estático."
  (when *rede-pronta* (return-from configurar-rede t))
  (handler-case
      (progn
        (carregar-modulo "/lib/modules/failover.ko")
        (carregar-modulo "/lib/modules/net_failover.ko")
        (carregar-modulo "/lib/modules/virtio_net.ko")
        (sleep 0.4)
        (let ((nome (nome-interface)))
          (unless nome (format t "~&Nenhuma interface de rede encontrada.~%")
                  (return-from configurar-rede nil))
          (let* ((sock (make-instance 'sb-bsd-sockets:inet-socket
                                      :type :stream :protocol :tcp))
                 (fd (sb-bsd-sockets:socket-file-descriptor sock)))
            (unwind-protect
                 (progn
                   (definir-endereco fd nome #x8916 *ip-cerne*)   ; SIOCSIFADDR
                   (definir-endereco fd nome #x891c *mascara*)    ; SIOCSIFNETMASK
                   (subir-interface fd nome))
              (sb-bsd-sockets:socket-close sock))
            (setf *rede-pronta* t)
            (format t "~&Interface ~a no ar: ~a~%" nome *ip-cerne*)
            t)))
    (error (e) (format t "~&Falha ao configurar rede: ~a~%" e) nil)))

(defun rede ()
  "Sobe a rede (se preciso) e mostra o status."
  (configurar-rede)
  (let ((nome (nome-interface)))
    (if nome
        (format t "~&Interface: ~a~%IP:        ~a~%Telnet:    (telnet 2323) e conecte do host~%"
                nome *ip-cerne*)
        (format t "~&Rede indisponível.~%")))
  (values))

(defun telnet (&optional (porta 2323))
  "Serve um REPL do Cerne por TCP. Conecte do host: nc localhost <porta>."
  (unless (configurar-rede)
    (format t "~&Sem rede; telnet cancelado.~%")
    (return-from telnet (values)))
  (let ((srv (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address srv) t)
    (handler-case
        (progn
          (sb-bsd-sockets:socket-bind srv #(0 0 0 0) porta)
          (sb-bsd-sockets:socket-listen srv 1)
          (format t "~&REPL servido em TCP ~a:~d. Ctrl-C aqui para parar.~%"
                  *ip-cerne* porta)
          (unwind-protect
               (loop
                 (let ((cli (sb-bsd-sockets:socket-accept srv)))
                   (let ((s (sb-bsd-sockets:socket-make-stream
                             cli :input t :output t :element-type 'character
                                 :buffering :none)))
                     (unwind-protect
                          (let ((*standard-input* s) (*standard-output* s))
                            (banner)
                            (format s "~&(REPL remoto do Cerne — boa diversão)~%")
                            (repl nil))   ; sem modo cru: a tty local não é a daqui
                       (ignore-errors (close s))
                       (ignore-errors (sb-bsd-sockets:socket-close cli))))))
            (sb-bsd-sockets:socket-close srv)))
      (sb-sys:interactive-interrupt ()
        (ignore-errors (sb-bsd-sockets:socket-close srv))
        (format t "~&Servidor encerrado.~%"))))
  (values))

;;; ===========================================================================
;;; Ponto de entrada (chamado pelo kernel como /init)
;;; ===========================================================================

(defun inicializar ()
  "Função de entrada do binário. É o PID 1 da máquina."
  ;; Como PID 1, se a gente sair, o kernel entra em pânico.
  ;; Então montamos os FS, protegemos tudo e, no fim, desligamos limpo.
  (montar-sistemas-de-arquivos)
  (setf *package* (find-package :cerne))   ; (ajuda)/(desligar) resolvem direto
  (carregar-modulo "/lib/modules/virtio_blk.ko")  ; faz aparecer /dev/vda
  (esperar-disco)                          ; aguarda só o necessário pelo node
  (restaurar t)                            ; recarrega a loja do disco, se houver
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
