;;;; construir.lisp — gera o binário do núcleo Cerne.
;;;;
;;;; Uso: sbcl --non-interactive --load construir.lisp
;;;; Resultado: ./build/cerne (executável autônomo)

(load (merge-pathnames "src/cerne.lisp" *load-pathname*))

(let ((saida (concatenate 'string
                          (directory-namestring *load-pathname*)
                          "build/cerne")))
  (ensure-directories-exist saida)
  (format t "~&Gerando binário do Cerne em ~a~%" saida)
  (sb-ext:save-lisp-and-die
   saida
   :executable t
   :toplevel #'cerne:inicializar
   ;; comprime para o binário caber folgado no initramfs
   :compression (if (member :sb-core-compression *features*) t nil)
   ;; sem informação de salvamento interativo: isto é um núcleo, não um REPL de dev
   :save-runtime-options t))
