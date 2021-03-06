#lang racket

(require "common.rkt" "programs.rkt" "points.rkt" "alternative.rkt" "errors.rkt"
         "timeline.rkt" "syntax/rules.rkt" "syntax/types.rkt"
         "core/localize.rkt" "core/taylor.rkt" "core/alt-table.rkt" "sampling.rkt"
         "core/simplify.rkt" "core/matcher.rkt" "core/regimes.rkt" "interface.rkt")

(provide (all-defined-out))

;; I'm going to use some global state here to make the shell more
;; friendly to interact with without having to store your own global
;; state in the repl as you would normally do with debugging. This is
;; probably a bad idea, and I might change it back later. When
;; extending, make sure this never gets too complicated to fit in your
;; head at once, because then global state is going to mess you up.

(struct shellstate
  (table next-alt locs children gened-series gened-rewrites simplified)
  #:mutable)

(define ^shell-state^ (make-parameter (shellstate #f #f #f #f #f #f #f)))

(define (^locs^ [newval 'none])
  (when (not (equal? newval 'none)) (set-shellstate-locs! (^shell-state^) newval))
  (shellstate-locs (^shell-state^)))
(define (^table^ [newval 'none])
  (when (not (equal? newval 'none))  (set-shellstate-table! (^shell-state^) newval))
  (shellstate-table (^shell-state^)))
(define (^next-alt^ [newval 'none])
  (when (not (equal? newval 'none)) (set-shellstate-next-alt! (^shell-state^) newval))
  (shellstate-next-alt (^shell-state^)))
(define (^children^ [newval 'none])
  (when (not (equal? newval 'none)) (set-shellstate-children! (^shell-state^) newval))
  (shellstate-children (^shell-state^)))

;; Keep track of state for (finish-iter!)
(define (^gened-series^ [newval 'none])
  (when (not (equal? newval 'none)) (set-shellstate-gened-series! (^shell-state^) newval))
  (shellstate-gened-series (^shell-state^)))
(define (^gened-rewrites^ [newval 'none])
  (when (not (equal? newval 'none)) (set-shellstate-gened-rewrites! (^shell-state^) newval))
  (shellstate-gened-rewrites (^shell-state^)))
(define (^simplified^ [newval 'none])
  (when (not (equal? newval 'none)) (set-shellstate-simplified! (^shell-state^) newval))
  (shellstate-simplified (^shell-state^)))

(define *sampler* (make-parameter #f))

(define (check-unused-variables vars precondition expr)
  ;; Fun story: you might want variables in the precondition that
  ;; don't appear in the `expr`, because that can allow you to do
  ;; non-uniform sampling. For example, if you have the precondition
  ;; `(< x y)`, where `y` is otherwise unused, then `x` is sampled
  ;; non-uniformly (biased toward small values).
  (define used (set-union (free-variables expr) (free-variables precondition)))
  (unless (set=? vars used)
    (define unused (set-subtract vars used))
    (warn 'unused-variable
          "unused ~a ~a" (if (equal? (set-count unused) 1) "variable" "variables")
          (string-join (map ~a unused) ", "))))

;; Setting up
(define (setup-prog! prog
                     #:precondition [precondition 'TRUE]
                     #:precision [precision 'binary64]
                     #:specification [specification #f])
  (*output-repr* (get-representation precision))
  (*var-reprs* (map (curryr cons (*output-repr*)) (program-variables prog)))
  (*start-prog* prog)
  (rollback-improve!)
  (check-unused-variables (program-variables prog) (program-body precondition) (program-body prog))

  (debug #:from 'progress #:depth 3 "[1/2] Preparing points")
  ;; If the specification is given, it is used for sampling points
  (timeline-event! 'analyze)
  (*sampler* (make-sampler (*output-repr*) precondition (or specification prog)))
  (timeline-event! 'sample)
  (*pcontext* (prepare-points (or specification prog) precondition (*output-repr*) (*sampler*)))
  (debug #:from 'progress #:depth 3 "[2/2] Setting up program.")
  (define alt (make-alt prog))
  (^table^ (make-alt-table (*pcontext*) alt (*output-repr*)))
  alt)

;; Information
(define (list-alts)
  (printf "Key: [.] = done, [>] = chosen\n")
  (let ([ndone-alts (atab-not-done-alts (^table^))])
    (for ([alt (atab-all-alts (^table^))]
	  [n (in-naturals)])
      (printf "~a ~a ~a\n"
       (cond [(equal? alt (^next-alt^)) ">"]
             [(set-member? ndone-alts alt) " "]
             [else "."])
       (~r #:min-width 4 n)
       (program-body (alt-program alt)))))
  (printf "Error: ~a bits\n" (errors-score (atab-min-errors (^table^)))))

;; Begin iteration
(define (choose-alt! n)
  (if (>= n (length (atab-all-alts (^table^))))
      (printf "We don't have that many alts!\n")
      (let-values ([(picked table*) (atab-pick-alt (^table^) #:picking-func (curryr list-ref n)
						   #:only-fresh #f)])
	(^next-alt^ picked)
	(^table^ table*)
	(void))))

(define (best-alt alts repr)
  (argmin (λ (alt) (errors-score (errors (alt-program alt) (*pcontext*) repr)))
		   alts))

(define (choose-best-alt!)
  (let-values ([(picked table*) (atab-pick-alt (^table^)
                                  #:picking-func (curryr best-alt (*output-repr*))
                                  #:only-fresh #t)])
    (^next-alt^ picked)
    (^table^ table*)
    (debug #:from 'pick #:depth 4 "Picked " picked)
    (void)))

;; Invoke the subsystems individually
(define (localize!)
  (timeline-event! 'localize)
  (define locs (localize-error (alt-program (^next-alt^)) (*output-repr*)))
  (for/list ([(err loc) (in-dict locs)])
    (timeline-push! 'locations
                    (location-get loc (alt-program (^next-alt^)))
                    (errors-score err)))
  (^locs^ (map cdr locs))
  (void))

(define transforms-to-try
  (let ([invert-x (λ (x) `(/ 1 ,x))] [exp-x (λ (x) `(exp ,x))] [log-x (λ (x) `(log ,x))]
	[ninvert-x (λ (x) `(/ 1 (neg ,x)))])
    `((0 ,identity ,identity)
      (inf ,invert-x ,invert-x)
      (-inf ,ninvert-x ,ninvert-x)
      #;(exp ,exp-x ,log-x)
      #;(log ,log-x ,exp-x))))

(define (taylor-alt altn loc)
  (define expr (location-get loc (alt-program altn)))
  (define vars (free-variables expr))
  (if (or (null? vars) ;; `approximate` cannot be called with a null vars list
          (not (set-member? '(binary64 binary32) ; currently taylor/reduce breaks with posits
                            (repr-of expr (*output-repr*) (*var-reprs*)))))
      (list altn)
      (for/list ([transform-type transforms-to-try])
        (match-define (list name f finv) transform-type)
        (define transformer (map (const (cons f finv)) vars))
        (alt
         (location-do loc 
                      (alt-program altn) 
                      (λ (x) ; taylor uses older format, resugaring and desugaring needed
                        (desugar-program
                            (approximate (resugar-program x (*output-repr*) #:full #f)
                                         vars #:transform transformer)
                            (*output-repr*) (*var-reprs*)
                            #:full #f)))
         `(taylor ,name ,loc)
         (list altn)))))

(define (gen-series!)
  (when (flag-set? 'generate 'taylor)
    (timeline-event! 'series)

    (define series-expansions
      (apply
       append
       (for/list ([location (^locs^)] [n (in-naturals 1)])
         (debug #:from 'progress #:depth 4 "[" n "/" (length (^locs^)) "] generating series at" location)
         (define tnow (current-inexact-milliseconds))
         (begin0
             (taylor-alt (^next-alt^) location)
           (timeline-push! 'times
                           (location-get location (alt-program (^next-alt^)))
                           (- (current-inexact-milliseconds) tnow))))))
    
    (timeline-log! 'inputs (length (^locs^)))
    (timeline-log! 'outputs (length series-expansions))

    (^children^ (append (^children^) series-expansions)))
  (^gened-series^ #t)
  (void))

(define (gen-rewrites!)
  (timeline-event! 'rewrite)
  (define rewrite (if (flag-set? 'generate 'rr) rewrite-expression-head rewrite-expression))
  (timeline-log! 'method (object-name rewrite))
  (define altn (alt-add-event (^next-alt^) '(start rm)))

  (define changelists
    (apply append
	   (for/list ([location (^locs^)] [n (in-naturals 1)])
	     (debug #:from 'progress #:depth 4 "[" n "/" (length (^locs^)) "] rewriting at" location)
             (define tnow (current-inexact-milliseconds))
             (define expr (location-get location (alt-program altn)))
             (begin0 (rewrite expr (*output-repr*) #:rules (*rules*) #:root location)
               (timeline-push! 'times expr (- (current-inexact-milliseconds) tnow))))))

  (define rules-used
    (append-map (curry map change-rule) changelists))
  (define rule-counts
    (sort
     (hash->list
      (for/hash ([rgroup (group-by identity rules-used)])
        (values (rule-name (first rgroup)) (length rgroup))))
     > #:key cdr))

  (define rewritten
    (for/list ([cl changelists])
      (for/fold ([altn altn]) ([cng cl])
        (alt (change-apply cng (alt-program altn)) (list 'change cng) (list altn)))))

  (timeline-log! 'inputs (length (^locs^)))
  (timeline-log! 'rules rule-counts)
  (timeline-log! 'outputs (length rewritten))

  (^children^ (append (^children^) rewritten))
  (^gened-rewrites^ #t)
  (void))

(define (num-nodes expr)
  (if (not (list? expr)) 1
      (add1 (apply + (map num-nodes (cdr expr))))))

(define (simplify!)
  (when (flag-set? 'generate 'simplify)
    (timeline-event! 'simplify)

    (define locs-list
      (for/list ([child (^children^)] [n (in-naturals 1)])
        ;; We want to avoid simplifying if possible, so we only
        ;; simplify things produced by function calls in the rule
        ;; pattern. This means no simplification if the rule output as
        ;; a whole is not a function call pattern, and no simplifying
        ;; subexpressions that don't correspond to function call
        ;; patterns.
        (match (alt-event child)
          [(list 'taylor _ loc) (list loc)]
          [(list 'change cng)
           (match-define (change rule loc _) cng)
           (define pattern (rule-output rule))
           (define expr (location-get loc (alt-program child)))
           (cond
            [(not (list? pattern)) '()]
            [else
             (for/list ([pos (in-naturals 1)]
                        [arg-pattern (cdr pattern)] #:when (list? arg-pattern))
               (append (change-location cng) (list pos)))])]
          [_ (list '(2))])))

    (define to-simplify
      (for/list ([child (^children^)] [locs locs-list]
                 #:when true [loc locs])
        (location-get loc (alt-program child))))

    (define simplifications
      (simplify-batch to-simplify #:rules (*simplify-rules*) #:precompute true))

    (define simplify-hash
      (make-immutable-hash (map cons to-simplify simplifications)))

    (define simplified
      (for/list ([child (^children^)] [locs locs-list])
        (for/fold ([child child]) ([loc locs])
          (define child* (location-do loc (alt-program child) (λ (expr) (hash-ref simplify-hash expr))))
          (if (not (equal? (alt-program child) child*))
              (alt child* (list 'simplify loc) (list child))
              child))))

    (timeline-log! 'inputs (length locs-list))
    (timeline-log! 'outputs (length simplified))

    (^children^ simplified))
  (^simplified^ #t)
  (void))


;; Finish iteration
(define (finalize-iter!)
  (timeline-event! 'prune)
  (define new-alts (^children^))
  (define orig-fresh-alts (atab-not-done-alts (^table^)))
  (define orig-done-alts (set-subtract (atab-all-alts (^table^)) (atab-not-done-alts (^table^))))
  (^table^ (atab-add-altns (^table^) (^children^) (*output-repr*)))
  (define final-fresh-alts (atab-not-done-alts (^table^)))
  (define final-done-alts (set-subtract (atab-all-alts (^table^)) (atab-not-done-alts (^table^))))

  (timeline-log! 'inputs (+ (length new-alts) (length orig-fresh-alts) (length orig-done-alts)))
  (timeline-log! 'outputs (+ (length final-fresh-alts) (length final-done-alts)))

  (define data
    (hash 'new (list (length new-alts)
                     (length (set-intersect new-alts final-fresh-alts)))
          'fresh (list (length orig-fresh-alts)
                       (length (set-intersect orig-fresh-alts final-fresh-alts)))
          'done (list (- (length orig-done-alts) (if (^next-alt^) 1 0))
                      (- (length (set-intersect orig-done-alts final-done-alts))
                         (if (set-member? final-done-alts (^next-alt^)) 1 0)))
          'picked (list (if (^next-alt^) 1 0)
                        (if (and (^next-alt^) (set-member? final-done-alts (^next-alt^))) 1 0))))
  (timeline-log! 'kept data)

  (timeline-log! 'min-error (errors-score (atab-min-errors (^table^))))
  (rollback-iter!)
  (void))

(define (inject-candidate! prog)
  (^table^ (atab-add-altns (^table^) (list (make-alt prog)) (*output-repr*)))
  (void))

(define (finish-iter!)
  (when (not (^next-alt^))
    (debug #:from 'progress #:depth 3 "picking best candidate")
    (choose-best-alt!))
  (when (not (^locs^))
    (debug #:from 'progress #:depth 3 "localizing error")
    (localize!))
  (when (not (^gened-series^))
    (debug #:from 'progress #:depth 3 "generating series expansions")
    (gen-series!))
  (when (not (^gened-rewrites^))
    (debug #:from 'progress #:depth 3 "generating rewritten candidates")
    (gen-rewrites!))
  (when (not (^simplified^))
    (debug #:from 'progress #:depth 3 "simplifying candidates")
    (simplify!))
  (debug #:from 'progress #:depth 3 "adding candidates to table")
  (finalize-iter!)
  (void))

(define (rollback-iter!)
  (^children^ '())
  (^locs^ #f)
  (^next-alt^ #f)
  (^gened-rewrites^ #f)
  (^gened-series^ #f)
  (^simplified^ #f)
  (void))

(define (rollback-improve!)
  (rollback-iter!)
  (reset!)
  (^table^ #f)
  (void))

;; Run a complete iteration
(define (run-iter!)
  (if (^next-alt^)
      (begin (printf "An iteration is already in progress!\n")
	     (printf "Finish it up manually, or by running (finish-iter!)\n")
	     (printf "Or, you can just run (rollback-iter!) to roll it back and start it over.\n"))
      (begin (debug #:from 'progress #:depth 3 "picking best candidate")
	     (choose-best-alt!)
	     (debug #:from 'progress #:depth 3 "localizing error")
	     (localize!)
	     (debug #:from 'progress #:depth 3 "generating rewritten candidates")
	     (gen-rewrites!)
	     (debug #:from 'progress #:depth 3 "generating series expansions")
	     (gen-series!)
	     (debug #:from 'progress #:depth 3 "simplifying candidates")
	     (simplify!)
	     (debug #:from 'progress #:depth 3 "adding candidates to table")
	     (finalize-iter!)))
  (void))

(define (run-improve prog iters
                     #:precondition [precondition 'TRUE]
                     #:precision [precision 'binary64]
                     #:specification [specification #f])
  (debug #:from 'progress #:depth 1 "[Phase 1 of 3] Setting up.")
  (define repr (get-representation precision))
  (define alt
    (setup-prog! prog #:specification specification #:precondition precondition #:precision precision))
  (cond
   [(and (flag-set? 'setup 'early-exit)
         (< (errors-score (errors (alt-program alt) (*pcontext*) repr)) 0.1))
    (debug #:from 'progress #:depth 1 "Initial program already accurate, stopping.")
    alt]
   [else
    (debug #:from 'progress #:depth 1 "[Phase 2 of 3] Improving.")
    (when (flag-set? 'setup 'simplify)
      (^children^ (atab-all-alts (^table^)))
      (simplify!)
      (finalize-iter!))
    (for ([iter (in-range iters)] #:break (atab-completed? (^table^)))
      (debug #:from 'progress #:depth 2 "iteration" (+ 1 iter) "/" iters)
      (run-iter!))
    (debug #:from 'progress #:depth 1 "[Phase 3 of 3] Extracting.")
    (get-final-combination repr)]))

(define (get-final-combination repr)
  (define all-alts (atab-all-alts (^table^)))
  (*all-alts* all-alts)
  (define joined-alt
    (cond
     [(and (flag-set? 'reduce 'regimes) (> (length all-alts) 1)
           (equal? (type-name (representation-type repr)) 'real))
      (timeline-event! 'regimes)
      (define option (infer-splitpoints all-alts repr))
      (timeline-event! 'bsearch)
      (combine-alts option repr (*sampler*))]
     [else
      (best-alt all-alts repr)]))
  (timeline-event! 'simplify)
  (define cleaned-alt
    (alt `(λ ,(program-variables (alt-program joined-alt))
            ,(simplify-expr (program-body (alt-program joined-alt))
                            #:rules (*fp-safe-simplify-rules*)))
         'final-simplify (list joined-alt)))
  (timeline-event! 'end)
  cleaned-alt)
