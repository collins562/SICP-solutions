(define (cont-frac n d k)
  (if (= k 1)
      (/ (n k) (d k))
      (/ (n k)
         (+ (d k)
            (cont-frac n d (- k 1))))))

(define (cont-frac-iter n d k)
  (define (helper-iter count result)
    (if (= count 0)
        result
        (helper-iter (- count 1)
                     (/ (n count)
                        (+ (d k)
                           result)))))
  (helper-iter (- k 1) (/ (n k) (d k))))

; find out the value of k which can make the accuracy of
; cont-frac hit the tolerance
(define tolerance 0.0001)

(define (cont-frac-k-guess f)
  (define (close-enough? v1 v2)
    (< (abs (- v1 v2)) tolerance))
  (define (try guess k)
    (let ((next (f (+ k 1))))
      (if (close-enough? guess next)
          (+ k 1)
          (try next (+ k 1)))))
  (try (f 1) 1))

(cont-frac-k-guess (lambda (k) (cont-frac (lambda (i) 1.0)
                                          (lambda (i) 1.0)
                                          k)))

(cont-frac-iter (lambda (i) 1.0)
                (lambda (i) 1.0)
                11)