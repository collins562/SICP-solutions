(load "5.12b.rkt")

(define (filter proc seq)
  (cond ((null? seq) '())
        ((proc (car seq))
         (cons (car seq) (filter proc (cdr seq))))
        (else
         (filter proc (cdr seq)))))

;; machine implementation
(define (make-new-machine)
  (let ((pc (make-register 'pc))
        (flag (make-register 'flag))
        (stack (make-stack))
        (the-instruction-sequence '())
        ;-----------update-------------;
        (instruction-category '())
        (label-regs '())
        (stacked-regs '())
        (register-val-source '())
        ;------------------------------;
        )
    (let ((the-ops
           (list (list 'initialize-stack
                       (lambda () (stack 'initialize)))))
          (register-table
           (list (list 'pc pc) (list 'flag flag))))
      (define (allocate-register name)
        (if (assoc name register-table)
            (error "Multiple defined register: " name)
            (begin (add stack name)                  
                   (set! register-table
                         (cons (list name (make-register name))
                               register-table))))
        'register-allocated)
      (define (lookup-register name)
        (let ((val (assoc name register-table)))
          (if val
              (cadr val)
              (error "Unknown register:" name))))
      (define (execute)
        (let ((insts (get-contents pc)))
          (if (null? insts)
              'done
              (begin
                ((instruction-execution-proc (car insts)))
                (execute)))))
      ;----------------------update--------------------;
      (define (update-data cate lregs sregs sources)
        (set! instruction-category cate)
        (set! label-regs lregs)
        (set! stacked-regs sregs)
        (set! register-val-source sources)
        'finished)
      ; for presentation of collected data
      (define (display-newline str)
        (display str)
        (newline))
      (define (show-data)
        (display-newline "Instruction category:")
        (for-each (lambda (record)
                    (display "  ")
                    (display (car record))
                    (display-newline ":")
                    (for-each (lambda (inst)
                                (display "    ")
                                (display-newline inst))
                              (cdr record)))
                  instruction-category)
        (newline)
        (display-newline "Entry register:")
        (display "  ")
        (display-newline labels)
        (newline)
        (display-newline "Stacked registers:")
        (display "  ")
        (display-newline stacked-register)
        (newline)
        (display-newline "Register value source:")
        (for-each (lambda (record)
                    (display "  ")
                    (display (car record))
                    (display-newline ": ")
                    (for-each (lambda (source)
                                (display "    ")
                                (display-newline source))
                              (cdr record)))
                  register-val-source))
      ;------------------------------------------------;
      (define (dispatch message)
        (cond ((eq? message 'start)
               (set-contents! pc the-instruction-sequence)
               (execute))
              ((eq? message 'install-instruction-sequence)
               (lambda (seq)
                 (set! the-instruction-sequence seq)))
              ((eq? message 'allocate-register) allocate-register)
              ((eq? message 'get-register) lookup-register)
              ((eq? message 'install-operations)
               (lambda (ops) (set! the-ops (append the-ops ops))))
              ((eq? message 'stack) stack)
              ((eq? message 'operations) the-ops)
              ;---------------------update--------------------;
              ((eq? message 'update-data) update-data)
              ((eq? message 'show-data) (show-data))
              ;-----------------------------------------------;
              (else (error "Unknown request -- MACHINE" message))))
      dispatch)))

(define (show machine)              ; add
  (machine 'show-data))             ;

(define (start machine)
  (machine 'start))

(define (get-register machine reg-name)
  ((machine 'get-register) reg-name))

(define (get-register-contents machine register-name)
  (get-contents (get-register machine register-name)))

(define (set-register-contents! machine register-name value)
  (set-contents! (get-register machine register-name) value)
  'done)

(define (make-machine register-names ops controller-text)
  (let ((machine (make-new-machine)))
    (for-each (lambda (register-name)
                ((machine 'allocate-register) register-name))
              register-names)
    ((machine 'install-operations) ops)
    ((machine 'install-instruction-sequence)
     (assemble controller-text machine))
    ((machine 'update-data) controller-text)        ; add
    machine))

;; register implementation
(define (make-register name)
  (let ((contents '*unassigned*))
    (define (dispatch message)
      (cond ((eq? message 'get) contents)
            ((eq? message 'set)
             (lambda (value) (set! contents value)))
            (else
             (error "Unknown request -- REGISTER" message))))
    dispatch))

(define (get-contents register)
  (register 'get))

(define (set-contents! register value)
  ((register 'set) value))

;; stack implementation
(define (make-stack)
  (let ((s '()))
    (define (push reg-name val)                   
      (let ((reg-stack (assoc reg-name s)))       
        (set-cdr! reg-stack                       
                  (cons val (cdr reg-stack)))))
    (define (pop reg-name)
      (let ((reg-stack (assoc reg-name s)))
        (if (null? (cdr reg-stack))
            (error "Empty stack -- POP" (car reg))
            (let ((top (cadr reg-stack)))
              (set-cdr! reg-stack (cddr reg-stack))
              top))))
    (define (add reg-name)                       
      (set! s (cons (list reg-name) s)))         
    (define (initialize)
      (for-each (lambda (stack)
                  (set-cdr! stack '()))
                s)
      'done)
    (define (dispatch message)
      (cond ((eq? message 'push) push)
            ((eq? message 'pop) pop)
            ((eq? message 'add) add)             
            ((eq? message 'initialize) (initialize))
            (else (error "Unknown request -- STACK" message))))
    dispatch))

(define (pop stack reg-name)
  ((stack 'pop) reg-name))

(define (push stack reg-name val)
  ((stack 'push) reg-name val))

(define (add stack reg-name)                     
  ((stack 'add) reg-name))                      