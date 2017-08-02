(load "expression.rkt")
(load "stream-operations.rkt")
(load "environment.rkt")
(load "table.rkt")

(define (instantiate exp frame unbound-var-handler)
  (define (copy exp)
    (cond ((var? exp)
           (let ((binding (binding-in-frame exp frame)))
             (if binding
                 (copy (binding-value binding))
                 (unbound-var-handler exp frame))))
          ((pair? exp)
           (cons (copy (car exp)) (copy (cdr exp))))
          (else exp)))
  (copy exp))

(define (qeval query frame-stream)
  (let ((qproc (get (type query) 'qeval)))
    (if qproc
        (qproc (contents query) frame-stream)
        (simple-query query frame-stream))))

;; simple query
(define (simple-query query-pattern frame-stream)
  (stream-flatmap
   (lambda (frame)
     ; if query is a direct query to assertions, the apply-rules will
     ; return an empty list; if query is a indirect query to assertions,
     ; the find-assertions will return an empty list.
     (stream-append-delayed
      (find-assertions query-pattern frame)       ; for assertions
      (delay (apply-rules query-pattern frame)))) ; for rules
   frame-stream))

;; for assertions
(define (find-assertions pattern frame)
  ;; fetch assertions from operation table and check them
  (stream-flatmap (lambda (datum)
                    (check-an-assertion datum pattern frame))
                  (fetch-assertions pattern frame)))

(define (check-an-assertion assertion query-pat query-frame)
  (let ((match-result
         (pattern-match query-pat assertion query-frame)))
    (if (eq? match-result 'failed)
        the-empty-stream
        (singleton-stream match-result))))

(define (pattern-match pat dat frame)
  ;; pat has 2 kinds: (cons 'computer (cons (cons '? 'type) '())) and
  ;;                  (cons 'computer (? type)) which is '(computer .?type)
  ;; both of it will work in this procudure
  (cond ((eq? frame 'failed) 'failed)
        ((equal? pat dat) frame)
        ((var? pat) (extend-if-consistent pat dat frame))
        ((and (pair? pat) (pair? dat))
         (pattern-match (cdr pat)
                        (cdr dat)
                        (pattern-match (car pat)
                                       (car dat)
                                       frame)))
        (else 'failed)))

(define (extend-if-consistent var dat frame)
  (let ((binding (binding-in-frame var frame)))
    (if binding
        (pattern-match (binding-value binding) dat frame)
        ;; bind var to dat if var has no binding
        (extend var dat frame))))

;; for rules
(define (apply-rules pattern frame)
  (stream-flatmap (lambda (rule)
                    (apply-a-rule rule pattern frame))
                  (fetch-rules pattern frame)))

(define (apply-a-rule rule query-pattern query-frame)
  (let ((clean-rule (rename-variables-in rule)))
    (let ((unify-result
           (unify-match query-pattern
                        (conclusion clean-rule)
                        query-frame)))
      ;; bind the variables in rule's conclusion to the
      ;; query-pattern's variables (unify-match).
      (if (eq? unify-result 'failed)
          the-empty-stream
          (qeval (rule-body clean-rule)
                 (singleton-stream unify-result))))))

(define (rename-variables-in rule)
  (let ((rule-application-id (new-rule-application-id)))
    (define (tree-walk exp)
      (cond ((var? exp)
             (make-new-variable exp rule-application-id))
            ((pair? exp)
             (cons (tree-walk (car exp))
                   (tree-walk (cdr exp))))
            (else exp)))
    (tree-walk rule)))

(define (unify-match p1 p2 frame)
  (cond ((eq? frame 'failed) 'failed)
        ((equal? p1 p2) frame)
        ((var? p1) (extend-if-possible p1 p2 frame))
        ((var? p2) (extend-if-possible p2 p1 frame))  ; ***
        ((and (pair? p1) (pair? p2))
         (unify-match (cdr p1)
                      (cdr p2)
                      (unify-match (car p1)
                                   (car p2)
                                   frame)))
        (else 'failed)))

(define (extend-if-possible var val frame)
  (let ((binding (binding-in-frame var frame)))
    (cond (binding
           (unify-match
            (binding-value binding) val frame))
          ; var has no binding check if val is variable.
          ((var? val)
           (let ((binding (binding-in-frame val frame)))
             (if binding
                 ; check if var and binding are matched
                 (unify-match
                  var (binding-value binding) frame)
                 ; bind var to val if both of them are variable
                 (extend var val frame))))
          ; check if var itself is in val
          ((depends-on? val var frame)
           'failed)
          (else (extend var val frame)))))

(define (depends-on? exp var frame)
  (define (tree-walk e)
    (cond ((var? e)
           (if (equal? var e)
               true
               (let ((b (binding-in-frame e frame)))
                 (if b
                     (tree-walk (binding-value b))
                     false))))
          ((pair? e)
           (or (tree-walk (car e))
               (tree-walk (cdr e))))
          (else false)))
  (tree-walk exp))

;; compound query
;;;; and
(define (conjoin-o conjuncts frame-stream)
  (if (null? conjuncts)
      frame-stream
      (conjoin (rest-conjuncts conjuncts)
               (qeval (first-conjunct conjuncts)
                      frame-stream))))

(define (conjoin conjuncts frame-stream)
  (conjoin-mix conjuncts '() frame-stream))

(define (conjoin-mix conjs delayed-conjs frame-stream)
  (if (null? conjs)
      (if (null? delayed-conjs)
          frame-stream
          the-empty-stream)
      (let ((first (first-conjunct conjs)))
        (cond ((or (lisp-value? first) (not? first))
               (if (has-unbound-var? (contents first)
                                     (stream-car frame-stream))
                   (conjoin-mix (rest-conjuncts conjs)
                                (cons first delayed-conjs)
                                frame-stream)
                   (conjoin-mix (rest-conjuncts conjs)
                                delayed-conjs
                                (qeval first frame-stream))))
              (else
               (let ((new-frame-stream (qeval first frame-stream)))
                 (if (null? delayed-conjs)
                     (conjoin-mix (rest-conjuncts conjs)
                                  '()
                                  new-frame-stream)
                     (let ((res (conjoin-delayed delayed-conjs
                                                 '()
                                                 new-frame-stream)))
                       (let ((d-conjs (car res))
                             (f-stream (cdr res)))
                         (conjoin-mix (rest-conjuncts conjs)
                                      d-conjs
                                      f-stream))))))))))
      
(define (conjoin-delayed delayed-conjs rest-conjs frame-stream)
  (if (null? delayed-conjs)
      (cons rest-conjs frame-stream)
      (let ((first (first-conjunct delayed-conjs)))
        (if (has-unbound-var? first (stream-car frame-stream))
            (conjoin-delayed (cdr delayed-conjs)
                             (cons first rest-conjs)
                             frame-stream)
            (conjoin-delayed (cdr delayed-conjs)
                             rest-conjs
                             (qeval first frame-stream))))))

(define (has-unbound-var? exp frame)
  (define (tree-walk exp)
    (cond ((var? exp)
           (let ((binding (binding-in-frame exp frame)))
             (if binding
                 (tree-walk (binding-value binding))
                 true)))
          ((pair? exp)
           (or (tree-walk (car exp)) (tree-walk (cdr exp))))
          (else false)))
  (tree-walk exp))

;; 4.76
(define (conjoin-o conjuncts frame-stream)
  (if (empty-conjunction? (rest-conjuncts conjuncts))
      (qeval (first-conjunct conjuncts) frame-stream)
      (merge (qeval (first-conjunct conjuncts) frame-stream)
             (conjoin (rest-conjuncts conjuncts)
                      frame-stream))))

(define (merge frame-stream-1 frame-stream-2)
  (stream-flatmap
   (lambda (frame-1)
     (stream-flatmap
      (lambda (frame-2) (check-bindings frame-1 frame-2))
      frame-stream-2))
   frame-stream-1))

(define (check-bindings frame-1 frame-2)
  (let ((match-result
         (merge-match frame-1 frame-2)))
    (if (eq? match-result 'failed)
        the-empty-stream
        (singleton-stream match-result))))

(define (merge-match frame-1 frame-2)
  (define (iter f-1 f-2 res)
    (if (null? f-1)
        (append res f-2)
        (let ((first (car f-1)))
          (let ((match (binding-in-frame (binding-variable first) f-2)))
            (if match
                (let ((val1 (bind-final-value first frame-1))
                      (val2 (bind-final-value match frame-2)))
                  (cond ((and (has-var? val1) (not (has-var? val2)))
                         (iter (cdr f-1)
                               f-2
                               (append (bind-pair-or-var val1 val2)
                                       (cons first res))))
                        ((and (not (has-var? val1)) (has-var? val2))
                         (iter (cdr f-1)
                               (append (bind-pair-or-var val2 val1)
                                       f-2)
                               (cons first res)))
                        ((eq? val1 val2)
                         (iter (cdr f-1) f-2 res))
                        (else 'failed)))
                (iter (cdr f-1) f-2 (cons first res)))))))
  (iter frame-1 frame-2 '()))

(define (bind-final-value bind frame)
  (define (copy exp)
    (cond ((var? exp)
           (let ((binding (binding-in-frame exp frame)))
             (if binding
                 (copy (binding-value binding))
                 exp)))
          ((pair? exp)
           (cons (copy (car exp)) (copy (cdr exp))))
          (else exp)))
  (copy (binding-value bind)))

(define (has-var? exp)
  (cond ((null? exp) false)
        ((var? exp) true)
        ((pair? exp)
         (or (has-var? (car exp))
             (has-var? (cdr exp))))
        (else false)))

(define (bind-pair-or-var var val)
  ;; var can be (? 12 x) or (1 ? 12 x)
  ;; or some more complex combination
  (cond ((null? var) '())
        ((var? var)
         (list (cons var val)))
        ((pair? var)
         (let ((1st (bind-pair-or-var (car var) (car val))))
           (if (not 1st)
               (bind-pair-or-var (cdr var) (cdr val))
               (append 1st (bind-pair-or-var (cdr var) (cdr val))))))
        (else false)))

;;;; or
(define (disjoin disjuncts frame-stream)
  (if (empty-disjunction? disjuncts)
      the-empty-stream
      (interleave-delayed
       (qeval (first-disjunct disjuncts) frame-stream)
       (delay (disjoin (rest-disjuncts disjuncts)
                       frame-stream)))))

;; filter
;;;; not
(define (negate operands frame-stream)
  (stream-flatmap
   (lambda (frame)
     (if (stream-null? (qeval (negated-query operands)
                              (singleton-stream frame)))
         (singleton-stream frame)
         the-empty-stream))
   frame-stream))

;;;; lisp-value
(define (lisp-value call frame-stream)
  (stream-flatmap
   (lambda (frame)
     (if (execute
          (instantiate
            call
            frame
            (lambda (v f)
              (error "Unknown pat var -- LISP-VALUE" v))))
         (singleton-stream frame)
         the-empty-stream))
   frame-stream))

(define (execute exp)
  (apply (eval (predicate exp) user-initial-environment)
         (args exp)))

;; always true for no-body query
(define (always-true ignore frame-stream) frame-stream)

;; unique
(define (uniquely-asserted operands frame-stream)
  (stream-flatmap
   (lambda (frame)
     (let ((res-f (qeval (unique-query operands)
                         (singleton-stream frame))))
       (if (single-stream? res-f)
           res-f
           the-empty-stream)))
   frame-stream))

(put 'and 'qeval conjoin)
(put 'or 'qeval disjoin)
(put 'not 'qeval negate)
(put 'lisp-value 'qeval lisp-value)
(put 'always-true 'qeval always-true)
(put 'unique 'qeval uniquely-asserted)