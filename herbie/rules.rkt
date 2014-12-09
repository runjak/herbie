#lang racket

;; Arithmetic identities for rewriting programs.

(require herbie/common)

(provide (struct-out rule) *rules*
	 *simplify-rules* get-rule define-ruleset)


; A rule has a name and an input and output pattern.
; It also has a relative path into the output where simplification
; should happen if the rule applies.

(struct rule (name input output slocations)
        #:methods gen:custom-write
        [(define (write-proc rule port mode)
           (display "#<rule " port)
           (write (rule-name rule) port)
           (display ">" port))])

(define *rulesets* (make-parameter '()))

(define (contains-expr haystack needle)
  (cond [(equal? haystack needle)
	 #t]
	[(list? haystack)
	 (ormap (curryr contains-expr needle) (cdr haystack))]
	[#t #f]))

(define-syntax-rule (define-ruleset name
		      [rulename input output]
		      ...)
  (begin (define name '())
	 (for ([rec (list (rule 'rulename 'input 'output
				(if (list? 'output)
				    (apply append
					   (for/list ([index (sequence-tail (in-naturals) 1)]
						      [subexpr (cdr 'output)])
					     (if (contains-expr 'input subexpr)
						 '()
						 (list (list index)))))
				    '())) ...)])
	   (set! name (cons rec name)))
	 (*rulesets* (cons name (*rulesets*)))))

(define (get-rule name)
  (let ([results (filter (λ (rule) (eq? (rule-name rule) name)) (*rules*))])
    (if (null? results)
	(error "Could not find a rule by the name" name)
	(car results))))

; Commutativity
(define-ruleset commutivity
  [+-commutative     (+ a b)               (+ b a)]
  [*-commutative     (* a b)               (* b a)])

; Associativity
(define-ruleset associativity
  [associate-+-lft   (+ a (+ b c))         (+ (+ a b) c)]
  [associate-+-rgt   (+ (+ a b) c)         (+ a (+ b c))]
  [associate---lft   (+ a (- b c))         (- (+ a b) c)]
  [associate---lft2  (- a (+ b c))         (- (- a b) c)]
  [associate---rgt   (- (+ a b) c)         (+ a (- b c))]
  [associate-*-lft   (* a (* b c))         (* (* a b) c)]
  [associate-*-rgt   (* (* a b) c)         (* a (* b c))]
  [associate-/-lft   (* a (/ b c))         (/ (* a b) c)]
  [associate-/-rgt   (/ (* a b) c)         (* a (/ b c))])

; Distributivity
(define-ruleset distributivity
  [distribute-lft-in     (* a (+ b c))         (+ (* a b) (* a c))]
  [distribute-rgt-in     (* a (+ b c))         (+ (* b a) (* c a))]
  [distribute-lft-out    (+ (* a b) (* a c))   (* a (+ b c))]
  [distribute-lft-out--  (- (* a b) (* a c))   (* a (- b c))]
  [distribute-rgt-out    (+ (* b a) (* c a))   (* a (+ b c))]
  [distribute-rgt-out--  (- (* b a) (* c a))   (* a (- b c))]
  [distribute-lft1-in    (+ (* b a) a)         (* (+ b 1) a)]
  [distribute-rgt1-in    (+ a (* c a))         (* (+ c 1) a)]
  [distribute-lft-neg-in (- (* a b))           (* (- a) b)]
  [distribute-rgt-neg-in (- (* a b))           (* a (- b))]
  [distribute-lft-neg-out (* (- a) b)          (- (* a b))]
  [distribute-rgt-neg-out (* a (- b))          (- (* a b))]
  [distribute-neg-in     (- (+ a b))           (+ (- a) (- b))]
  [distribute-neg-out    (+ (- a) (- b))       (- (+ a b))]
  [distribute-inv-in     (/ (* a b))           (* (/ a) (/ b))]
  [distribute-inv-out    (* (/ a) (/ b))       (/ (* a b))]
  [distribute-inv-neg    (/ (- a))             (- (/ a))]
  [distribute-neg-inv    (- (/ a))             (/ (- a))])
  
; Difference of squares
(define-ruleset difference-of-squares-canonicalize
  [difference-of-squares (- (sqr a) (sqr b))   (* (+ a b) (- a b))]
  [difference-of-sqr-1   (- (sqr a) 1)         (* (+ a 1) (- a 1))]
  [difference-of-sqr--1  (+ (sqr a) -1)        (* (+ a 1) (- a 1))])

(define-ruleset difference-of-squares-flip
  [flip-+     (+ a b)  (/ (- (sqr a) (sqr b)) (- a b))]
  [flip--     (- a b)  (/ (- (sqr a) (sqr b)) (+ a b))])

; Difference of cubes
(define-ruleset difference-of-cubes
  [sum-cubes        (+ (expt a 3) (expt b 3)) (* (+ (sqr a) (- (sqr b) (* a b))) (+ a b))]
  [difference-cubes (- (expt a 3) (expt b 3)) (* (+ (sqr a) (+ (sqr b) (* a b))) (+ a b))]
  [flip3-+    (+ a b)  (/ (- (expt a 3) (expt b 3)) (+ (sqr a) (- (sqr b) (* a b))))]
  [flip3--    (- a b)  (/ (- (expt a 3) (expt b 3)) (+ (sqr a) (+ (sqr b) (* a b))))])

; Identity
(define-ruleset id-reduce
  [+-lft-identity    (+ 0 a)               a]
  [+-rgt-identity    (+ a 0)               a]
  [+-inverses        (- a a)               0]
  [sub0-neg          (- 0 b)               (- b)]
  [remove-double-neg (- (- a))             a]
  [*-lft-identity    (* 1 a)               a]
  [*-rgt-identity    (* a 1)               a]
  [*-inverses        (/ a a)               1]
  [remove-double-div (/ 1 (/ 1 a))         a]
  [div0              (/ 0 a)               0]
  [mul0              (* 0 a)               0]
  [mul-1-neg         (* -1 a)              (- a)])

(define-ruleset id-transform
  [sub-neg           (- a b)               (+ a (- b))]
  [unsub-neg         (+ a (- b))           (- a b)]
  [neg-sub0          (- b)                 (- 0 b)]
  [*-un-lft-identity a                     (* 1 a)]
  [div-inv           (/ a b)               (* a (/ 1 b))]
  [un-div-inv        (* a (/ 1 b))         (/ a b)]
  [neg-mul-1         (- a)                 (* -1 a)]
  [clear-num         (/ a b)               (/ 1 (/ b a))])

; Dealing with fractions
(define-ruleset fractions-distribute
  [div-sub     (/ (- a b) c)        (- (/ a c) (/ b c))]
  [times-frac  (/ (* a b) (* c d))  (* (/ a c) (/ b d))])

(define-ruleset fractions-transform
  [sub-div     (- (/ a c) (/ b c))  (/ (- a b) c)]
  [frac-add    (+ (/ a b) (/ c d))  (/ (+ (* a d) (* b c)) (* b d))]
  [frac-sub    (- (/ a b) (/ c d))  (/ (- (* a d) (* b c)) (* b d))]
  [frac-times  (* (/ a b) (/ c d))  (/ (* a c) (* b d))])

; Square root
(define-ruleset squares-reduce
  [rem-square-sqrt   (sqr (sqrt x))     x]
  [rem-sqrt-square   (sqrt (sqr x))     (abs x)]
  [sqr-neg           (sqr (- x))        (sqr x)])

(define-ruleset squares-distribute
  [square-prod       (sqr (* x y))      (* (sqr x) (sqr y))]
  [square-div        (sqr (/ x y))      (/ (sqr x) (sqr y))])

(define-ruleset squares-transform
  [sqrt-prod         (sqrt (* x y))     (* (sqrt x) (sqrt y))]
  [sqrt-div          (sqrt (/ x y))     (/ (sqrt x) (sqrt y))]
  [sqrt-unprod       (* (sqrt x) (sqrt y)) (sqrt (* x y))]
  [sqrt-undiv        (/ (sqrt x) (sqrt y)) (sqrt (/ x y))]
  [square-mult       (sqr x)            (* x x)]
  [add-sqr-sqrt      x                  (sqr (sqrt x))]
  [square-unprod     (* (sqr x) (sqr y)) (sqr (* x y))]
  [square-undiv      (/ (sqr x) (sqr y)) (sqr (/ x y))])

(define-ruleset squares-canonicalize
    [square-unmult     (* x x)            (sqr x)])

; Exponentials
(define-ruleset exp-expand
  [add-exp-log  x                    (exp (log x))]
  [add-log-exp  x                    (log (exp x))])

(define-ruleset exp-reduce
  [rem-exp-log  (exp (log x))        x]
  [rem-log-exp  (log (exp x))        x])

(define-ruleset exp-distribute
  [exp-sum      (exp (+ a b))        (* (exp a) (exp b))]
  [exp-neg      (exp (- a))          (/ 1 (exp a))]
  [exp-diff     (exp (- a b))        (/ (exp a) (exp b))])

(define-ruleset exp-factor
  [prod-exp     (* (exp a) (exp b))  (exp (+ a b))]
  [rec-exp      (/ 1 (exp a))        (exp (- a))]
  [div-exp      (/ (exp a) (exp b))  (exp (- a b))]
  [exp-prod     (exp (* a b))        (expt (exp a) b)])

; Powers
(define-ruleset pow-reduce
  [unexpt1         (expt a 1)                  a]
  [unexpt0         (expt a 0)                  1])

(define-ruleset pow-expand
  [expt1           a                           (expt a 1)])

(define-ruleset pow-canonicalize
  [exp-to-expt     (exp (* (log a) b))         (expt a b)]
  [expt-plus       (* (expt a b) a)            (expt a (+ b 1))]
  [unexpt2         (expt a 2)                  (sqr a)]
  [unexpt1/2       (expt a 1/2)                (sqrt a)])

(define-ruleset pow-transform
  [expt-exp        (expt (exp a) b)            (exp (* a b))]
  [expt-to-exp     (expt a b)                  (exp (* (log a) b))]
  [expt-prod-up    (* (expt a b) (expt a c))   (expt a (+ b c))]
  [expt-prod-down  (* (expt b a) (expt c a))   (expt (* b c) a)]
  [unexpt-prod-down (expt (* b c) a)           (* (expt b a) (expt c a))]
  [inv-expt        (/ 1 a)                     (expt a -1)]
  [expt1/2         (sqrt a)                    (expt a 1/2)]
  [expt2           (sqr a)                     (expt a 2)])

; Logarithms
(define-ruleset log-distribute
  [log-prod     (log (* a b))        (+ (log a) (log b))]
  [log-div      (log (/ a b))        (- (log a) (log b))]
  [log-rec      (log (/ 1 a))        (- (log a))]
  [log-pow      (log (expt a b))     (* b (log a))])

(define-ruleset log-factor
  [sum-log      (+ (log a) (log b))  (log (* a b))]
  [diff-log     (- (log a) (log b))  (log (/ a b))]
  [neg-log      (- (log a))          (log (/ 1 a))])

; Trigonometry
(define-ruleset trig-reduce
  [cos-sin-sum (+ (sqr (cos a)) (sqr (sin a))) 1]
  [1-sub-cos   (- 1 (sqr (cos a))) (sqr (sin a))]
  [1-sub-sin   (- 1 (sqr (sin a))) (sqr (cos a))]
  [-1-add-cos  (+ (sqr (cos a)) -1) (- (sqr (sin a)))]
  [-1-add-sin  (+ (sqr (sin a)) -1) (- (sqr (cos a)))]
  [sin-neg     (sin (- x))         (- (sin x))]
  [cos-neg     (cos (- x))         (cos x)])

(define-ruleset trig-expand
  [sin-sum     (sin (+ x y))       (+ (* (sin x) (cos y)) (* (cos x) (sin y)))]
  [cos-sum     (cos (+ x y))       (- (* (cos x) (cos y)) (* (sin x) (sin y)))]
  [sin-diff    (sin (- x y))       (- (* (sin x) (cos y)) (* (cos x) (sin y)))]
  [cos-diff    (cos (- x y))       (+ (* (cos x) (cos y)) (* (sin x) (sin y)))]
  [diff-atan   (- (atan x) (atan y)) (atan2 (- x y) (+ 1 (* x y)))]
  [quot-tan    (/ (sin x) (cos x)) (tan x)]
  [tan-quot    (tan x)             (/ (sin x) (cos x))]
  [cotan-quot  (cotan x)           (/ (cos x) (sin x))]
  [quot-tan    (/ (sin x) (cos x)) (tan x)]
  [quot-cotan  (/ (cos x) (sin x)) (cotan x)]
  [cotan-tan   (cotan x)           (/ 1 (tan x))]
  [tan-cotan   (tan x)             (/ 1 (cotan x))])

(define *rules* (make-parameter (apply append (*rulesets*))))
(define *simplify-rules*
  (append trig-reduce
	  log-distribute
	  pow-canonicalize
	  pow-reduce
	  exp-distribute
	  exp-reduce
	  squares-reduce
	  squares-distribute
	  squares-canonicalize
	  fractions-distribute
	  id-reduce
	  difference-of-squares-canonicalize
	  distributivity
	  associativity
	  commutivity))