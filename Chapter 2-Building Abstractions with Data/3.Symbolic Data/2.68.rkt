(load "2.67.rkt")

(define (encode message tree)
  (if (null? message)
      '()
      (append (encode-symbol (car message) tree)
              (encode (cdr message) tree))))

(define (encode-symbol s tree)
  (define (recur tree)
    (cond ((leaf? tree) '())
          ((memq s (symbols (left-branch tree)))
           (cons 0 (recur (left-branch tree))))
          (else
           (cons 1 (recur (right-branch tree))))))
  
  (if (memq s (symbols tree))
      (recur tree)
      (error "symbol not found -- ENCODE-SYMBOL" s)))

(newline)
(display (encode (decode sample-message sample-tree) sample-tree))
; sample-message:
; (0 1 1 0 0 1 0 1 0 1 1 1 0)