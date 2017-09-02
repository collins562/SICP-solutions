(load "ev-operations\\expression.rkt")
(load "compiler-instruction-sequence.rkt")
(load "compiler-label.rkt")
(load "compiler-lexical-address.rkt")
(load "compiler-open-code.rkt")
(load "scan-out-defines.rkt")

; log:
; >> an original compiler
; >> adopt implementation about open code in ex-5.38
; >> adopt implementation about lexical address in ex-5.39 ~ ex-5.44
;    and change the implementation about open code
; >> adopt implementation of scan-out-defines
; >> adopt implementation of checking rebound open code operators
; >> use expression.rkt from directory <ev-operations>

(define (test text)
  (for-each (lambda (x)
              (if (pair? x)
                  (begin (display "  ")))
              (display x)
              (newline))
            (caddr (compile text 'val 'next '()))))

(define (compile exp target linkage compile-env)   ; changed
  (cond ((self-evaluating? exp)
         (compile-self-evaluating exp target linkage))
        ((open-code? exp compile-env)
         (compile-open-code exp target linkage compile-env))
        ((quoted? exp) (compile-quoted exp target linkage))
        ((variable? exp)
         (compile-variable exp target linkage compile-env))
        ((assignment? exp)
         (compile-assignment exp target linkage compile-env))
        ((definition? exp)
         (compile-definition exp target linkage compile-env))
        ((if? exp)
         (compile-if exp target linkage compile-env))
        ((lambda? exp)
         (compile-lambda exp target linkage compile-env))
        ((begin? exp)
         (compile-sequence (begin-actions exp) target linkage compile-env))
        ((cond? exp) (compile (cond->if exp) target linkage compile-env))
        ((let? exp) (compile (let->combination exp)
                             target linkage compile-env))
        ((application? exp)
         (compile-application exp target linkage compile-env))
        (else
         (error "Unknown expression type -- COMPILE" exp))))

(define (compile-linkage linkage)
  (cond ((eq? linkage 'return)
         (make-instruction-sequence '(continue) '()
          '((goto (reg continue)))))
        ((eq? linkage 'next)
         (empty-instruction-sequence))
        (else
         (make-instruction-sequence '() '()
          `((goto (label ,linkage)))))))

(define (end-with-linkage linkage instruction-sequence)
  (preserving '(continue)
              instruction-sequence
              (compile-linkage linkage)))

(define (compile-self-evaluating exp target linkage)
  (end-with-linkage linkage
   (make-instruction-sequence
    '() (list target)
    `((assign ,target (const ,exp))))))

(define (compile-quoted exp target linkage)
  (end-with-linkage linkage
   (make-instruction-sequence '() (list target)
    `((assign ,target (const ,(text-of-quotation exp)))))))

; variable
(define (compile-variable exp target linkage compile-env)
  (let ((address (find-variable exp compile-env))
        (op 'lookup-variable-value))
    (if (not (eq? address 'not-found))
        (begin (set! op 'lexical-address-lookup)
               (set! exp address)))
    (end-with-linkage linkage
     (make-instruction-sequence '(env) (list target)
      `((assign ,target
                (op ,op)
                (const ,exp)
                (reg env)))))))

; assignment
(define (compile-assignment exp target linkage compile-env)
  (let* ((var (assignment-variable exp))
         (get-value-code
          (compile (assignment-value exp) 'val 'next compile-env))
         (address (find-variable var compile-env))
         (op 'set-variable-value!))
    (if (not (eq? address 'not-found))
        (begin (set! op 'lexical-address-set!)
               (set! var address)))
    (end-with-linkage linkage
     (preserving '(env)
      get-value-code
      (make-instruction-sequence '(env val) (list target)
       `((perform (op ,op)
                  (const ,var)
                  (reg val)
                  (reg env))
         (assign ,target (const ok))))))))

; define
(define (compile-definition exp target linkage compile-env)
  ; the interval definition was transformed, so definition don't
  ; to extend compile-env
  (let ((var (definition-variable exp))
        (get-value-code
         (compile (definition-value exp) 'val 'next compile-env)))
    (end-with-linkage linkage
     (preserving '(env)
      get-value-code
      (make-instruction-sequence '(env val) (list target)
       `((perform (op define-variable!)
                  (const ,var)
                  (reg val)
                  (reg env))
         (assign ,target (const ok))))))))

; if:
;  <compiling if-predicate with val as target and next as linkage>
;  (test (op false?) (reg val))
;  (branch (label false-branch))
; true-branch
;  <compiling result of if-consequent with given target and linkage,
;   or with after-if as it linkage>
; false-branch
;  <compiling result of if-alternative with fiven target and linkage>
; after-if

(define (compile-if exp target linkage compile-env)
  (let ((t-branch (make-label 'true-branch))
        (f-branch (make-label 'false-branch))
        (after-if (make-label 'after-if)))
    (let ((consequent-linkage
           (if (eq? linkage 'next) after-if linkage)))
      (let ((p-code (compile (if-predicate exp) 'val 'next compile-env))
            (c-code (compile (if-consequent exp)
                             target
                             consequent-linkage
                             compile-env))
            (a-code
             (compile (if-alternative exp) target linkage compile-env)))
        (preserving '(env continue)
         p-code
         (append-instruction-sequences
          (make-instruction-sequence '(val) '()
           `((test (op false?) (reg val))
             (branch (label ,f-branch))))
          (parallel-instruction-sequences
           (append-instruction-sequences t-branch c-code)
           (append-instruction-sequences f-branch a-code))
          after-if))))))

; sequence
(define (compile-sequence seq target linkage compile-env)
  (if (last-exp? seq)
      (compile (first-exp seq) target linkage compile-env)
      (preserving '(env continue)
       (compile (first-exp seq) target 'next compile-env)
       (compile-sequence (rest-exps seq) target linkage compile-env))))

; complied procedure
(define (make-compiled-procedure entry env)
  (list 'compiled-procedure entry env)) ; save the entry and current env

(define (compiled-procedure? proc)
  (tagged-list? proc 'compiled-procedure))

(define (compiled-procedure-entry c-proc) (cadr c-proc))
(define (compiled-procedure-env c-proc) (caddr c-proc))

; lambda:
;  <construct procedure and assign it to target>
;  <code turn to linkage or (goto (label after-lambda))
;  <compiling result of lambda body>
; after-lambda 
(define (compile-lambda exp target linkage compile-env)
  (let ((proc-entry (make-label 'entry))
        (after-lambda (make-label 'after-lambda)))
    (let ((lambda-linkage
           (if (eq? linkage 'next) after-lambda linkage)))
      (append-instruction-sequences
       (tack-on-instruction-sequence
        (end-with-linkage lambda-linkage
         (make-instruction-sequence '(env) (list target)
          `((assign ,target
                    (op make-compiled-procedure)
                    (label ,proc-entry)
                    (reg env)))))
        (compile-lambda-body exp proc-entry compile-env))
       after-lambda))))

(define (compile-lambda-body exp proc-entry compile-env)
  (let ((formals (lambda-parameters exp)))
    (append-instruction-sequences
     (make-instruction-sequence '(env proc argl) '(env)
      `(,proc-entry
        (assign env (op compiled-procedure-env) (reg proc))
        (assign env
                (op extend-environment)
                (const ,formals)
                (reg argl)
                (reg env))))
     (compile-sequence (scan-out-defines (lambda-body exp))
                       'val 'return
                       (cons formals compile-env)))))

(define (compile-application exp target linkage compile-env)
  (let ((proc-code (compile (operator exp) 'proc 'next compile-env))
        (operand-codes
         (map (lambda (operand) (compile operand 'val 'next compile-env))
              (operands exp))))
    (preserving '(env continue)
     proc-code
     (preserving '(proc continue)
      (construct-arglist operand-codes)
      (compile-procedure-call target linkage)))))

; <compiling result of last operand with val as its target>
; (assign argl (op list) (reg val))
; <compiling result of next operand with val as its target>
; ...
; <compiling result of first opernad with val as its target>
; (assign argl (op cons) (reg val) (reg argl))
(define (construct-arglist operand-codes)
  (let ((operand-codes (reverse operand-codes)))
    (if (null? operand-codes)
        (make-instruction-sequence '() '(argl)
         '((assign argl (const ()))))
        (let ((code-to-get-last-arg
               (append-instruction-sequences
                (car operand-codes)
                (make-instruction-sequence '(val) '(argl)
                 '((assign argl (op list) (reg val)))))))
          (if (null? (cdr operand-codes))
              code-to-get-last-arg
              (preserving '(env)
               code-to-get-last-arg
               (code-to-get-rest-args (cdr operand-codes))))))))

(define (code-to-get-rest-args operand-codes)
  (let ((code-for-next-arg
         (preserving '(argl)
          (car operand-codes)
          (make-instruction-sequence
           '(val argl) '(argl)
           '((assign argl (op cons) (reg val) (reg argl)))))))
    (if (null? (cdr operand-codes))
        code-for-next-arg
        (preserving '(env)
         code-for-next-arg
         (code-to-get-rest-args (cdr operand-codes))))))

; procedure apply:
;  (test (op primitive-procedure?) (reg proc))
;  (branch (label primitive-branch))
; compiled-branch
;  <codes applying the compiled procedure to given target and linkage>
; primitive-branch
;  (assign <target>
;          (op apply-primitive-pricedure)
;          (reg proc)
;          (reg argl))
;  <linkage>
; after-call
(define (compile-procedure-call target linkage)
  (let ((primitive-branch (make-label 'primitive-branch))
        (compiled-branch (make-label 'compiled-branch))
        (after-call (make-label 'after-call)))
    (let ((compiled-linkage
           (if (eq? linkage 'next) after-call linkage)))
      (append-instruction-sequences
       (make-instruction-sequence '(proc) '()
        `((test (op primitive-procedure?) (reg proc))
          (branch (label ,primitive-branch))))
       (parallel-instruction-sequences
        (append-instruction-sequences
         compiled-branch
         (compile-proc-appl target compiled-linkage))
        (append-instruction-sequences
         primitive-branch
         (end-with-linkage linkage
          (make-instruction-sequence '(proc argl) (list target)
           `((assign
              ,target
              (op apply-primitive-procedure)
              (reg proc)
              (reg argl)))))))
       after-call))))

(define all-regs '(env proc val argl continue))

(define (compile-proc-appl target linkage)
  (cond ((and (eq? target 'val) (not (eq? linkage 'return)))
         (make-instruction-sequence '(proc) all-regs
          `((assign continue (label ,linkage))
            (assign val (op compiled-procedure-entry) (reg proc))
            (goto (reg val)))))
        ((and (not (eq? target 'val))
              (not (eq? linkage 'return)))
         (let ((proc-return (make-label 'proc-return)))
           (make-instruction-sequence '(proc) all-regs
            `((assign continue (label ,proc-return))
              (assign val (op compiled-procedure-entry)
                      (reg proc))
              (goto (reg val))
              ,proc-return
              (assign ,target (reg val))
              (goto (label ,linkage))))))
        ((and (eq? target 'val) (eq? linkage 'return))
         (make-instruction-sequence '(proc continue) all-regs
          '((assign val (op compiled-procedure-entry) (reg proc))
            (goto (reg val)))))
        ((and (not (eq? target 'val)) (eq? linkage 'return))
         (error "return linkage, target not val -- COMPILE" target))))