(define (assemble controller-text machine)
  (extract-labels controller-text
                  (lambda (insts labels)
                    (update-data! insts machine)            ; add
                    (update-insts! insts labels machine)
                    insts)))

(define (update-data! insts machine)
  (let ((inst-category (classify insts)))
    (display (car inst-category))
    ((machine 'update-data) inst-category
                            (find-label-regs inst-category)
                            (find-stacked-regs inst-category)
                            (find-val-sources inst-category))))

; classify the insts
(define (classify insts)
  (let ((inst-category '()))
    (for-each (lambda (inst)
                (let ((cate (assoc (car inst) inst-category)))
                  (if cate
                      (let ((records (cdr cate)))
                        (display records)
                        (newline)
                        (if (not (memq inst records))
                            (set-cdr! cate (cons inst (cdr cate)))))
                      (set! inst-category
                            (cons (list (car inst) inst)
                                  inst-category)))))
              insts)
    inst-category))

(define (classify-insts category inst inst-category)
  (let ((cate (assoc category inst-category)))
    (if cate
        (let ((records (cdr cate)))
          (if (not (memq inst records))
              (set-cdr! cate (cons inst (cdr cate)))))
        (set! inst-category
              (cons (list category inst)
                    inst-category)))
    inst-category))

; find registers that store entries
(define (find-label-regs inst-category)
  (let ((label-registers '())
        (goto-insts (assoc 'goto inst-category)))
    (for-each (lambda (inst)
                (let ((reg (cadr (cadr inst))))
                  (if (not (memq reg labels))
                      (set! label-registers (cons reg label-registers)))
                  'done))
              (filter (lambda (inst)
                        (register-exp? (cadr inst)))
                      (cdr goto-insts)))
    label-registers))

; find stacked registers
(define (find-stacked-regs inst-category)
  (let ((stacked-regs '())
        (stack-insts (append
                      (cdr (assoc 'save inst-category))
                      (cdr (assoc 'restore inst-category)))))
    (for-each (lambda (inst)
                (let ((reg-name (cadr inst)))
                  (if (not (memq reg-name stacked-regs))
                      (set! stacked-regs
                            (cons reg-name stacked-regs)))
                  'done))
              stack-insts)
    stacked-insts))

; find sources of registers' values
(define (find-val-sources inst-category)
  (let ((val-sources '())
        (assign-insts (assoc 'assign inst-category)))
    (for-each (lambda (inst)
                (let ((reg-name (cadr inst))
                      (source (cddr inst)))
                  (let ((val-seq (assoc reg-name val-sources)))
                    (if val-seq
                        (if (not (memq (cdr val-seq) source))
                            (set-cdr! val-seq
                                      (cons source (cdr val-seq))))
                        (set! val-sources
                              (cons (list reg-name source)
                                    val-sources)))
                    'done)))
              (cdr assign-insts))
    val-sources))

;-------------------------------------------------------------------------;

(define (extract-labels text receive)
  (if (null? text)
      (receive '() '())
      (extract-labels (cdr text)
                      (lambda (insts labels)
                        (let ((next-inst (car text)))
                          (if (symbol? next-inst)
                              (if (assoc next-inst labels)
                                  (error "Multiple used label: " next-inst)
                                  (receive insts
                                           (cons (make-label-entry
                                                  next-inst
                                                  insts)
                                                 labels)))
                              (receive (cons (make-instruction next-inst)
                                             insts)
                                       labels)))))))

(define (update-insts! insts labels machine)
  (let ((pc (get-register machine 'pc))
        (flag (get-register machine 'flag))
        (stack (machine 'stack))
        (ops (machine 'operations)))
    (for-each
     (lambda (inst)
       (set-instruction-execution-proc!
        inst
        (make-execution-procedure
         (instruction-text inst) labels machine
         pc flag stack ops)))
     insts)))

;; instruction
(define (make-instruction text)
  (cons text '()))

(define (instruction-text inst)
  (car inst))

(define (instruction-execution-proc inst)
  (cdr inst))

(define (set-instruction-execution-proc! inst proc)
  (set-cdr! inst proc))  ; the insts in the label entry will also change

;; label
(define (make-label-entry label-name insts)
  (cons label-name insts))

(define (lookup-label labels label-name)
  (let ((val (assoc label-name labels)))
    (if val
        (cdr val)
        (error "Undefined label -- ASSEMBLE" label-name))))

;; make execution procedure for instructions
(define (make-execution-procedure inst labels machine
                                  pc flag stack ops)
  (cond ((eq? (car inst) 'assign)
         (make-assign inst machine labels ops pc))
        ((eq? (car inst) 'test)
         (make-test inst machine labels ops flag pc))
        ((eq? (car inst) 'branch)
         (make-branch inst machine labels flag pc))
        ((eq? (car inst) 'goto)
         (make-goto inst machine labels pc))
        ((eq? (car inst) 'save)
         (make-save inst machine stack pc))
        ((eq? (car inst) 'restore)
         (make-restore inst machine stack pc))
        ((eq? (car inst) 'perform)
         (make-perform inst machine labels ops pc))
        (else (error "Unknown instruction type -- ASSEMBLE" inst))))

;; update pc when procedures finish except for branch and goto
(define (advance-pc pc)
  (set-contents! pc (cdr (get-contents pc))))

;; assign
(define (make-assign inst machine labels operations pc)
  (let ((target
         (get-register machine (assign-reg-name inst)))
        (value-exp (assign-value-exp inst)))
    (let ((value-proc
           (if (operation-exp? value-exp)
               (make-operation-exp
                value-exp machine labels operations)
               (make-primitive-exp
                (car value-exp) machine labels))))
      ; return a execution procedure for assign
      (lambda ()
        (set-contents! target (value-proc))
        (advance-pc pc)))))

;;;; (assign <var> (const <num>))    or
;;;; (assign <var> (reg <var2>)      or
;;;; (assign <var> (op <operation>) <arg1> ...)
(define (assign-reg-name assign-instruction)
  (cadr assign-instruction))

(define (assign-value-exp assign-instruction)
  (cddr assign-instruction))

;; test
(define (make-test inst machine labels operations flag pc)
  (let ((condition (test-condition inst)))
    (if (operation-exp? condition)
        (let ((condition-proc
               (make-operation-exp
                condition machine labels operations)))
          (lambda ()
            (set-contents! flag (condition-proc))
            (advance-pc pc)))
        (error "Bad TEST instruction -- ASSEMBLE" inst))))

;;;; (test (op <operation>) <arg1> <arg2> ...)
(define (test-condition test-instruction)
  (cdr test-instruction))

;;branch: checking register flag, set up the pc to branch target
;;        or just update pc (if there is no need to branch)
(define (make-branch inst machine labels flag pc)
  (let ((dest (branch-dest inst)))
    (if (label-exp? dest)
        (let ((insts
               (lookup-label labels (label-exp-label dest))))
          (lambda ()
            (if (get-contents flag)
                (set-contents! pc insts)
                (advance-pc pc))))
        (error "Bad BRANCH instruction -- ASSEMBLE" inst))))

;;;; (branch (label <name>))
(define (branch-dest branch-instruction)
  (cadr branch-instruction))

;; goto: the target of goto instruction could be a label or
;;       a register, which will be the new destination of pc.
(define (make-goto inst machine labels pc)
  (let ((dest (goto-dest inst)))
    (cond ((label-exp? dest)
           (let ((insts
                  (lookup-label labels
                                (label-exp-label dest))))
             (lambda () (set-contents! pc insts))))
          ((register-exp? dest)
           (let ((reg
                  (get-register machine
                                (register-exp-reg dest))))
             (lambda ()
               (set-contents! pc (get-contents reg)))))
          (else (error "Bad GOTO instruction -- ASSEMBLE"
                       inst)))))

;;;; (goto (label <name>))   or
;;;; (goto (reg <name>))
(define (goto-dest goto-instruction)
  (cadr goto-instruction))

;; instructions of save and restore
;; the data inside the stack is not specificly pointed to some
;; registers. so the order of save and restore should be considered
;; carefully
(define (make-save inst machine stack pc)
  (let ((reg-name (stack-inst-reg-name inst)))
    (let ((reg (get-register machine reg-name)))
      (lambda ()
        (push stack reg-name (get-contents reg))
        (advance-pc pc)))))

(define (make-restore inst machine stack pc)
  (let ((reg-name (stack-inst-reg-name inst)))
    (let ((reg (get-register machine reg-name)))
      (lambda ()
        (set-contents! reg (pop stack reg-name))
        (advance-pc pc)))))

;;;; (save <name>) and
;;;; (restore <name>) and
(define (stack-inst-reg-name stack-instruction)
  (cadr stack-instruction))

;; perform
(define (make-perform inst machine labels operations pc)
  (let ((action (perform-action inst)))
    (if (operation-exp? action)
        (let ((action-proc
               (make-operation-exp
                action machine labels operations)))
          (lambda ()
            (action-proc)
            (advance-pc pc)))
        (error "Bad PERFORM instruction -- ASSEMBLE" inst))))

;;;; 
(define (perform-action inst) (cdr inst))

;; make execution procedures for subexpressions
;; primitve expression
(define (make-primitive-exp exp machine labels)
  (cond ((constant-exp? exp)
         (let ((c (constant-exp-value exp)))
           (lambda () c)))
        ((label-exp? exp)
         (let ((insts
                (lookup-label labels
                              (label-exp-label exp))))
           (lambda () insts)))
        ((register-exp? exp)
         (let ((r (get-register machine
                                (register-exp-reg exp))))
           (lambda () (get-contents r))))
        (else
         (error "Unknown expression type -- ASSEMBLE" exp))))

;;;; syntactic forms for reg, label and const
(define (tagged-list? exp tag)
  (and (pair? exp) (eq? (car exp) tag)))

(define (register-exp? exp) (tagged-list? exp 'reg))

(define (register-exp-reg exp) (cadr exp))

(define (constant-exp? exp) (tagged-list? exp 'const))

(define (constant-exp-value exp) (cadr exp))

(define (label-exp? exp) (tagged-list? exp 'label))

(define (label-exp-label exp) (cadr exp))

;; operation expressioin
(define (make-operation-exp exp machine labels operations)
  (let ((op (lookup-prim (operation-exp-op exp) operations))
        (aprocs
         (map (lambda (e)
                (if (label-exp? e)
                    (error "CANNOT operate on label -- MAKE-OPERATION-EXP"
                           e)
                    (make-primitive-exp e machine labels)))
              (operation-exp-operands exp))))
    (lambda ()
      (apply op (map (lambda (p) (p)) aprocs)))))

;;;; syntactic forms
(define (operation-exp? exp)
  (and (pair? exp) (tagged-list? (car exp) 'op)))

(define (operation-exp-op operation-exp)
  (cadr (car operation-exp)))

(define (operation-exp-operands operation-exp)
  (cdr operation-exp))

(define (lookup-prim symbol operations)
  (let ((val (assoc symbol operations)))
    (if val
        (cadr val)
        (error "Unknown operation -- ASSEMBLE" symbol))))