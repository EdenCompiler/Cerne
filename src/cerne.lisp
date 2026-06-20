;;;; Cerne — núcleo Lisp inicializável (unikernel)
;;;;
;;;; Este arquivo vira o processo de inicialização (PID 1) da máquina.
;;;; Ao ligar, o kernel Linux carrega este binário diretamente como /init,
;;;; sem shell, sem systemd, sem espaço de usuário — só parênteses.
;;;;
;;;; Tudo escrito em português do Brasil de propósito.

(require :sb-posix)   ; opendir/readdir, para listar diretórios (inclui /proc)

(defpackage :cerne
  (:use :cl)
  (:export :inicializar
           ;; operador
           :ajuda :desligar :reiniciar :memoria :tempo :cronometrar
           ;; introspecção do sistema
           :uptime :meminfo :cpuinfo :data :uname :cmdline :modulos
           ;; sistema de arquivos
           :arquivos :ver
           ;; loja chave-valor
           :lembrar :recordar :esquecer :tudo-que-lembro
           ;; persistência em disco cru
           :salvar :restaurar :disco-bruto
           ;; diversão
           :mandelbrot :adivinhe :vida :vaca :pi-digitos :historico
           :matrix :fortune :senha :cores))

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

;;; ===========================================================================
;;; Ajuda
;;; ===========================================================================

(defun ajuda ()
  "Lista os comandos disponíveis."
  (format t "~&~a~%~
  Operador:~%~
    (ajuda) (memoria) (tempo) (cronometrar forma...) (reiniciar) (desligar)~%~
  Sistema (via /proc):~%~
    (uptime) (meminfo) (cpuinfo) (data) (uname) (cmdline) (modulos)~%~
  Arquivos:~%~
    (arquivos \"/proc\") (ver \"/proc/cmdline\")~%~
  Memória chave-valor:~%~
    (lembrar chave valor) (recordar chave) (esquecer chave) (tudo-que-lembro)~%~
  Persistência em disco cru (/dev/vda, sem sistema de arquivos):~%~
    (salvar) (restaurar) (disco-bruto)~%~
  Diversão:~%~
    (mandelbrot) (vida) (matrix) (cores) (vaca \"texto\") (pi-digitos 80)~%~
    (adivinhe) (fortune) (senha 16) (historico)~%~
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
         (push forma *historico*)
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
