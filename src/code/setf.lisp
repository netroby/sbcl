;;;; SETF and friends
;;;;
;;;; Note: The expansions for SETF and friends sometimes create
;;;; needless LET-bindings of argument values. The compiler will
;;;; remove most of these spurious bindings, so SETF doesn't worry too
;;;; much about creating them.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;; The inverse for a generalized-variable reference function is stored in
;;; one of two ways:
;;;
;;; A SETF inverse property corresponds to the short form of DEFSETF. It is
;;; the name of a function takes the same args as the reference form, plus a
;;; new-value arg at the end.
;;;
;;; A SETF method expander is created by the long form of DEFSETF or
;;; by DEFINE-SETF-EXPANDER. It is a function that is called on the reference
;;; form and that produces five values: a list of temporary variables, a list
;;; of value forms, a list of the single store-value form, a storing function,
;;; and an accessing function.
(declaim (ftype (function (t &optional (or null sb!c::lexenv))) sb!xc:get-setf-expansion))
(defun sb!xc:get-setf-expansion (form &optional environment)
  #!+sb-doc
  "Return five values needed by the SETF machinery: a list of temporary
   variables, a list of values with which to fill them, a list of temporaries
   for the new values, the setting function, and the accessing function."
  (let (temp)
    (cond ((symbolp form)
           (multiple-value-bind (expansion expanded)
               (sb!xc:macroexpand-1 form environment)
             (if expanded
                 (sb!xc:get-setf-expansion expansion environment)
                 (let ((new-var (sb!xc:gensym "NEW")))
                   (values nil nil (list new-var)
                           `(setq ,form ,new-var) form)))))
          ;; Local functions inhibit global SETF methods.
          ((and environment
                (let ((name (car form)))
                  (dolist (x (sb!c::lexenv-funs environment))
                    (when (and (eq (car x) name)
                               (not (sb!c::defined-fun-p (cdr x))))
                      (return t)))))
           (expand-or-get-setf-inverse form environment))
          ((setq temp (info :setf :inverse (car form)))
           (get-setf-method-inverse form `(,temp) nil environment))
          ((setq temp (info :setf :expander (car form)))
           ;; KLUDGE: It may seem as though this should go through
           ;; *MACROEXPAND-HOOK*, but the ANSI spec seems fairly explicit
           ;; that *MACROEXPAND-HOOK* is a hook for MACROEXPAND-1, not
           ;; for macroexpansion in general. -- WHN 19991128
           (funcall temp
                    form
                    ;; As near as I can tell from the ANSI spec,
                    ;; macroexpanders have a right to expect an actual
                    ;; lexical environment, not just a NIL which is to
                    ;; be interpreted as a null lexical environment.
                    ;; -- WHN 19991128
                    (coerce-to-lexenv environment)))
          (t
           (expand-or-get-setf-inverse form environment)))))

;;; If a macro, expand one level and try again. If not, go for the
;;; SETF function.
(declaim (ftype (function (t (or null sb!c::lexenv)))
                expand-or-get-setf-inverse))
(defun expand-or-get-setf-inverse (form environment)
  (multiple-value-bind (expansion expanded)
      (%macroexpand-1 form environment)
    (if expanded
        (sb!xc:get-setf-expansion expansion environment)
        (get-setf-method-inverse form
                                 `(funcall #'(setf ,(car form)))
                                 t
                                 environment))))

(defun get-setf-method-inverse (form inverse setf-fun environment)
  (let ((new-var (sb!xc:gensym "NEW"))
        (vars nil)
        (vals nil)
        (args nil))
    (dolist (x (reverse (cdr form)))
      (cond ((sb!xc:constantp x environment)
             (push x args))
            (t
             (let ((temp (gensymify x)))
               (push temp args)
               (push temp vars)
               (push x vals)))))
    (values vars
            vals
            (list new-var)
            (if setf-fun
                `(,@inverse ,new-var ,@args)
                `(,@inverse ,@args ,new-var))
            `(,(car form) ,@args))))

;;;; SETF itself

;;; Except for atoms, we always call GET-SETF-EXPANSION, since it has
;;; some non-trivial semantics. But when there is a setf inverse, and
;;; G-S-E uses it, then we return a call to the inverse, rather than
;;; returning a hairy LET form. This is probably important mainly as a
;;; convenience in allowing the use of SETF inverses without the full
;;; interpreter.
(defmacro-mundanely setf (&whole form &rest args &environment env)
  #!+sb-doc
  "Takes pairs of arguments like SETQ. The first is a place and the second
  is the value that is supposed to go into that place. Returns the last
  value. The place argument may be any of the access forms for which SETF
  knows a corresponding setting form."
  (unless args
    (return-from setf nil))
  (destructuring-bind (place value-form . more) args
    (when more
      (return-from setf `(progn ,@(sb!c::explode-setq form 'error))))
    ;; Macros without a SETF expander/inverse can be expanded now,
    ;; for shorter output in the case where (M) is a macro invocation
    ;; expanding to *A-VAR*, rather than deferring the macroexpansion
    ;; to GET-SETF-EXPANSION which will introduce a needless gensym.
    (loop
       (when (and (listp place)
                  (let ((op (car place)))
                    (or (info :setf :expander op) (info :setf :inverse op))))
         (return))
       (multiple-value-bind (expansion macro-p) (%macroexpand-1 place env)
         (cond (macro-p (setq place expansion)) ; iterate
               ((symbolp place) (return-from setf `(setq ,place ,value-form)))
               (t (return)))))
    (multiple-value-bind (temps vals newval setter getter)
        (sb!xc:get-setf-expansion place env)
      (declare (ignore getter))
      (let ((inverse (info :setf :inverse (car place))))
        (if (and inverse (eq inverse (car setter)))
            `(,inverse ,@(cdr place) ,value-form)
            `(let* (,@(mapcar #'list temps vals))
               (multiple-value-bind ,newval ,value-form ,setter)))))))

;;;; various SETF-related macros

;; Code shared by PSETQ, PSETF, SHIFTF attempting to minimize the expansion.
;; This has significant speed+space benefit to a non-preprocessing interpreter,
;; and to some degree a preprocessing interpreter.
(labels
    ((expand (args env operator single-op)
       (cond ((singleton-p (cdr args)) ; commonest case probably
              (return-from expand `(progn (,single-op ,@args) nil)))
             ((not args)
              (return-from expand nil)))
       (collect ((let*-bindings) (mv-bindings) (setters))
         (do ((a args (cddr a)))
             ((endp a))
           (when (endp (cdr a))
             (error "Odd number of args to ~S." operator))
           (let ((place (car a))
                 (value-form (cadr a)))
             (when (and (not (symbolp place)) (eq operator 'psetq))
               (error 'simple-program-error
                      :format-control "Place ~S in PSETQ is not a SYMBOL"
                      :format-arguments (list place)))
             (multiple-value-bind (temps vals stores setter)
                 (sb!xc:get-setf-expansion place env)
               (let*-bindings (mapcar #'list temps vals))
               (mv-bindings (cons stores value-form))
               (setters setter))))
         (car (build (let*-bindings) (mv-bindings)
                     (de-values-ify (setters))))))
     ;; Instead of emitting (PROGN (VALUES (SETQ ...) (SETQ ...)) NIL)
     ;; the SETQs can be lifted into the PROGN. This is an unimportant tweak
     ;; for compiled code, but it helps the interpreter not needlessly collect
     ;; arguments to call VALUES; and it's more human-readable.
     (de-values-ify (forms)
       (mapcan (lambda (form)
                 (if (and (listp form) (eq (car form) 'values))
                     (cdr form)
                     (list form))) forms))
     ;; The next three functions each return lists of forms to avoid having
     ;; to specially recognize a PROGN as the recursion base case.
     (build (let*-bindings mv-bindings setters)
       (if let*-bindings
           (gen-let* (car let*-bindings)
                     (gen-mv-bind (caar mv-bindings) (cdar mv-bindings)
                                  (build (cdr let*-bindings) (cdr mv-bindings)
                                         setters)))
           `(,@setters nil)))
     (gen-let* (bindings body-forms)
       (cond ((not bindings) body-forms)
             (t
              (when (and (singleton-p body-forms) (eq (caar body-forms) 'let*))
                (let ((nested (cdar body-forms))) ; extract the nested LET*
                  (setq bindings (append bindings (car nested))
                        body-forms (cdr nested))))
              `((let* ,bindings ,@body-forms)))))
     (gen-mv-bind (stores values body-forms)
       (if (singleton-p stores)
           (gen-let* `((,(car stores) ,values)) body-forms)
           `((multiple-value-bind ,stores ,values ,@body-forms)))))

  (defmacro-mundanely shiftf (&whole form &rest args &environment env)
  #!+sb-doc
  "One or more SETF-style place expressions, followed by a single
   value expression. Evaluates all of the expressions in turn, then
   assigns the value of each expression to the place on its left,
   returning the value of the leftmost."
  (declare (type sb!c::lexenv env))
  (when (< (length args) 2)
    (error "~S called with too few arguments: ~S" 'shiftf form))
  (collect ((let-bindings) (mv-bindings) (setters) (getters))
    (dolist (arg (butlast args))
      (multiple-value-bind (temps subforms store-vars setter getter)
          (sb!xc:get-setf-expansion arg env)
        (let-bindings (mapcar #'list  temps subforms))
        (mv-bindings store-vars)
        (setters setter)
        (getters getter)))
    ;; Handle the last arg specially here. The getter is just the last
    ;; arg itself.
    (getters (car (last args)))
    (labels ((thunk (mv-bindings getters setters)
               (if mv-bindings
                   (gen-mv-bind (car mv-bindings) (car getters)
                                (thunk (cdr mv-bindings) (cdr getters) setters))
                   setters)))
      (let ((outputs (loop for i below (length (car (mv-bindings)))
                           collect (sb!xc:gensym "OUT"))))
        `(let ,(reduce #'append (let-bindings))
           ,@(gen-mv-bind outputs (car (getters))
                          (thunk (mv-bindings) (cdr (getters))
                                 `(,@(de-values-ify (setters))
                                   (values ,@outputs)))))))))

  (defmacro-mundanely psetf (&rest pairs &environment env)
  #!+sb-doc
  "This is to SETF as PSETQ is to SETQ. Args are alternating place
  expressions and values to go into those places. All of the subforms and
  values are determined, left to right, and only then are the locations
  updated. Returns NIL."
    (expand pairs env 'psetf 'setf))

  (defmacro-mundanely psetq (&rest pairs &environment env)
  #!+sb-doc
  "PSETQ {var value}*
   Set the variables to the values, like SETQ, except that assignments
   happen in parallel, i.e. no assignments take place until all the
   forms have been evaluated."
    (expand pairs env 'psetq 'setq)))

;;; FIXME: Compiling this definition of ROTATEF apparently blows away the
;;; definition in the cross-compiler itself, so that after that, any
;;; ROTATEF operations can no longer be compiled, because
;;; GET-SETF-EXPANSION is called instead of SB!XC:GET-SETF-EXPANSION.
(defmacro-mundanely rotatef (&rest args &environment env)
  #!+sb-doc
  "Takes any number of SETF-style place expressions. Evaluates all of the
   expressions in turn, then assigns to each place the value of the form to
   its right. The rightmost form gets the value of the leftmost.
   Returns NIL."
  (declare (type sb!c::lexenv env))
  (when args
    (collect ((let*-bindings) (mv-bindings) (setters) (getters))
      (dolist (arg args)
        (multiple-value-bind (temps subforms store-vars setter getter)
            (sb!xc:get-setf-expansion arg env)
          (let*-bindings (mapcar #'list temps subforms))
          (mv-bindings store-vars)
          (setters setter)
          (getters getter)))
      (setters nil)
      (getters (car (getters)))
      (labels ((thunk (mv-bindings getters)
                 (if mv-bindings
                     `((multiple-value-bind ,(car mv-bindings) ,(car getters)
                         ,@(thunk (cdr mv-bindings) (cdr getters))))
                     (setters))))
        `(let* ,(reduce #'append(let*-bindings))
           ,@(thunk (mv-bindings) (cdr (getters))))))))

(defmacro-mundanely push (obj place &environment env)
  #!+sb-doc
  "Takes an object and a location holding a list. Conses the object onto
  the list, returning the modified list. OBJ is evaluated before PLACE."
  (multiple-value-bind (dummies vals newval setter getter)
      (sb!xc:get-setf-expansion place env)
    (let ((g (gensym)))
      `(let* ((,g ,obj)
              ,@(mapcar #'list dummies vals)
              (,(car newval) (cons ,g ,getter))
              ,@(cdr newval))
         ,setter))))

(defmacro-mundanely pushnew (obj place &rest keys
                             &key key test test-not &environment env)
  #!+sb-doc
  "Takes an object and a location holding a list. If the object is
  already in the list, does nothing; otherwise, conses the object onto
  the list. Returns the modified list. If there is a :TEST keyword, this
  is used for the comparison."
  (declare (ignore key test test-not))
  (multiple-value-bind (dummies vals newval setter getter)
      (sb!xc:get-setf-expansion place env)
    (let ((g (gensym)))
      `(let* ((,g ,obj)
              ,@(mapcar #'list dummies vals)
              (,(car newval) (adjoin ,g ,getter ,@keys))
              ,@(cdr newval))
         ,setter))))

(defmacro-mundanely pop (place &environment env)
  #!+sb-doc
  "The argument is a location holding a list. Pops one item off the front
  of the list and returns it."
  (multiple-value-bind (dummies vals newval setter getter)
      (sb!xc:get-setf-expansion place env)
    (let ((list-head (gensym)))
      `(let* (,@(mapcar #'list dummies vals)
              (,list-head ,getter)
              (,(car newval) (cdr ,list-head))
              ,@(cdr newval))
         ,setter
         (car ,list-head)))))

(defmacro-mundanely remf (place indicator &environment env)
  #!+sb-doc
  "Place may be any place expression acceptable to SETF, and is expected
  to hold a property list or (). This list is destructively altered to
  remove the property specified by the indicator. Returns T if such a
  property was present, NIL if not."
  (multiple-value-bind (temps vals newval setter getter)
      (sb!xc:get-setf-expansion place env)
    (let* ((flag (make-symbol "FLAG"))
           (body `(multiple-value-bind (,(car newval) ,flag)
              ;; See ANSI 5.1.3 for why we do out-of-order evaluation
                      (truly-the (values list boolean)
                                 (%remf ,indicator ,getter))
                    ,(if (cdr newval) `(let ,(cdr newval) ,setter) setter)
                    ,flag)))
      (if temps `(let* ,(mapcar #'list temps vals) ,body) body))))

;; Perform the work of REMF.
(defun %remf (indicator plist)
  (let ((tail plist) (predecessor))
    (loop
     (when (endp tail) (return (values plist nil)))
     (let ((key (pop tail)))
       (when (atom tail)
         (error (if tail
                    "Improper list in REMF."
                    "Odd-length list in REMF.")))
       (let ((next (cdr tail)))
         (when (eq key indicator)
           ;; This function is strict in its return type!
           (the list next) ; for effect
           (return (values (cond (predecessor
                                  (setf (cdr predecessor) next)
                                  plist)
                                 (t
                                  next))
                           t)))
         (setq predecessor tail tail next))))))

;;; INCF and DECF have a straightforward expansion, avoiding temp vars,
;;; when the PLACE is a non-macro symbol. Otherwise we do the generalized
;;; SETF-like thing. The compiler doesn't care either way, but this
;;; reduces the incentive to treat some macros as special-forms when
;;; squeezing more performance from a Lisp interpreter.
;;; we can't use DEFINE-MODIFY-MACRO because of ANSI 5.1.3
(declaim (inline xsubtract))
(defun xsubtract (a b) (- b a)) ; exchanged subtract
(flet ((expand (place delta env operator)
         (when (symbolp place)
           (multiple-value-bind (expansion expanded)
               (sb!xc:macroexpand-1 place env)
             (unless expanded
               (return-from expand `(setq ,place (,operator ,delta ,place))))
             ;; GET-SETF-EXPANSION would have macroexpanded too, so do it now.
             (setq place expansion)))
         (multiple-value-bind (dummies vals newval setter getter)
             (sb!xc:get-setf-expansion place env)
           `(let* (,@(mapcar #'list dummies vals)
                   (,(car newval) (,operator ,delta ,getter))
                   ,@(cdr newval))
              ,setter))))
  (defmacro-mundanely incf (place &optional (delta 1) &environment env)
  #!+sb-doc
  "The first argument is some location holding a number. This number is
  incremented by the second argument, DELTA, which defaults to 1."
    (expand place delta env '+))

  (defmacro-mundanely decf (place &optional (delta 1) &environment env)
  #!+sb-doc
  "The first argument is some location holding a number. This number is
  decremented by the second argument, DELTA, which defaults to 1."
    (expand place delta env 'xsubtract)))

;;;; DEFINE-MODIFY-MACRO stuff

;; FIXME: the comments (at INCF/DECF/REMF) saying not to use DEFINE-MODIFY-MACRO
;; "because of ANSI 5.1.3" deflect the real issue - D-M-M expands incorrectly.
;; If it were right, you should definitely be able to use it for at least INCF.
;; An example of the problem:
;; * (define-modify-macro buggy-incf (x) +)
;; * (macroexpand-1 '(buggy-incf (cadr (l)) (delta)))
;; -> (LET* ((#:LIST553 (CDR (L))) (#:NEW554 (+ (CAR #:LIST553) (DELTA))))
;;      (SB-KERNEL:%RPLACA #:LIST553 #:NEW554))
;; wherein (DELTA) was supposed to have been evaluated _before_ reading the
;; PLACE but is actually evaluated after it.
;; Specifically, 5.1.3 says "For each of the ``read-modify-write'' operators
;;   in the next figure and for any additional macros defined by the programmer
;;   using define-modify-macro, an exception is made ..."
;; Because of the word "and" in that sentence it doesn't matter whether INCF
;; was defined manually or with DEFINE-MODIFY-MACRO. Those should be the same.
;;
(def!macro sb!xc:define-modify-macro (name lambda-list function &optional doc-string)
  #!+sb-doc
  "Creates a new read-modify-write macro like PUSH or INCF."
  (let ((other-args nil)
        (rest-arg nil)
        (env (make-symbol "ENV"))          ; To beautify resulting arglist.
        (reference (make-symbol "PLACE"))) ; Note that these will be nonexistent
                                           ;  in the final expansion anyway.
    ;; Parse out the variable names and &REST arg from the lambda list.
    (do ((ll lambda-list (cdr ll))
         (arg nil))
        ((null ll))
      (setq arg (car ll))
      (cond ((eq arg '&optional))
            ((eq arg '&rest)
             (if (symbolp (cadr ll))
               (setq rest-arg (cadr ll))
               (error "Non-symbol &REST argument in definition of ~S." name))
             (if (null (cddr ll))
               (return nil)
               (error "Illegal stuff after &REST argument.")))
            ((memq arg '(&key &allow-other-keys &aux))
             (error "~S not allowed in DEFINE-MODIFY-MACRO lambda list." arg))
            ((symbolp arg)
             (push arg other-args))
            ((and (listp arg) (symbolp (car arg)))
             (push (car arg) other-args))
            (t (error "Illegal stuff in lambda list."))))
    (setq other-args (nreverse other-args))
    `(#-sb-xc-host sb!xc:defmacro
      #+sb-xc-host defmacro-mundanely
         ,name (,reference ,@lambda-list &environment ,env)
       ,doc-string
       (multiple-value-bind (dummies vals newval setter getter)
           (sb!xc:get-setf-expansion ,reference ,env)
         (let ()
             `(let* (,@(mapcar #'list dummies vals)
                     (,(car newval)
                      ,,(if rest-arg
                          `(list* ',function getter ,@other-args ,rest-arg)
                          `(list ',function getter ,@other-args)))
                     ,@(cdr newval))
                ,setter))))))

;;;; DEFSETF

(eval-when (#-sb-xc :compile-toplevel :load-toplevel :execute)
  ;;; Assign SETF macro information for NAME, making all appropriate checks.
  (macrolet ((assign-it ()
               `(progn
                  (when inverse
                    (clear-info :setf :expander name)
                    (setf (info :setf :inverse name) inverse))
                  (when expander
                    #-sb-xc-host (setf (%fun-lambda-list expander)
                                       expander-lambda-list)
                    (clear-info :setf :inverse name)
                    (setf (info :setf :expander name) expander))
                  (when doc
                    (setf (fdocumentation name 'setf) doc))
                  name)))
  (defun assign-setf-macro (name expander expander-lambda-list inverse doc)
    #+sb-xc-host (declare (ignore expander-lambda-list))
    (with-single-package-locked-error
        (:symbol name "defining a setf-expander for ~A"))
    (let ((setf-fn-name `(setf ,name)))
      (multiple-value-bind (where-from present-p)
          (info :function :where-from setf-fn-name)
        ;; One might think that :DECLARED merits a style warning, but SBCL
        ;; provides ~58 standard accessors as both (SETF F) and a macro.
        ;; So allow the user to declaim an FTYPE and we'll hush up.
        ;; What's good for the the goose is good for the gander.
        (case where-from
          (:assumed
           ;; This indicates probable user error. Compilation assumed something
           ;; to be functional; a macro says otherwise. Because :where-from's
           ;; default can be :assumed, PRESENT-P disambiguates "defaulted" from
           ;; "known" to have made an existence assumption.
           (when present-p
             (warn "defining setf macro for ~S when ~S was previously ~
             treated as a function" name setf-fn-name)))
          (:defined
           ;; Somebody defined (SETF F) but then also said F has a macro.
           ;; A soft warning seems appropriate because in this case it's
           ;; at least in theory not wrong to call the function.
           ;; The user can declare an FTYPE if both things are intentional.
           (style-warn "defining setf macro for ~S when ~S is also defined"
                       name setf-fn-name)))))
    (assign-it))
  (defun !quietly-assign-setf-macro ; For cold-init
      (name expander expander-lambda-list inverse doc)
    (assign-it))))

(def!macro sb!xc:defsetf (access-fn &rest rest)
  #!+sb-doc
  "Associates a SETF update function or macro with the specified access
  function or macro. The format is complex. See the manual for details."
  (unless (symbolp access-fn)
    (error "~S access-function name ~S is not a symbol."
           'sb!xc:defsetf access-fn))
  (typecase rest
    ((cons (and symbol (not null)) (or null (cons string null)))
     `(eval-when (:load-toplevel :compile-toplevel :execute)
        (assign-setf-macro ',access-fn nil nil ',(car rest) ',(cadr rest))))
    ((cons list (cons list))
     (destructuring-bind (lambda-list (&rest store-variables) &body body) rest
       (with-unique-names (whole access-form environment)
         (multiple-value-bind (body local-decs doc)
                 (parse-defmacro `(,lambda-list ,@store-variables)
                                 whole body access-fn 'defsetf
                                 :environment environment
                                 :anonymousp t)
           `(eval-when (:compile-toplevel :load-toplevel :execute)
              (assign-setf-macro
                   ',access-fn
                   (lambda (,access-form ,environment)
                     ,@local-decs
                     (%defsetf ,access-form ,(length store-variables)
                               (lambda (,whole)
                                 ,body)))
                   ',lambda-list
                   nil
                   ',doc))))))
    (t
     (error "Ill-formed DEFSETF for ~S" access-fn))))

(defun %defsetf (orig-access-form num-store-vars expander)
  (declare (type function expander))
  (let (subforms
        subform-vars
        subform-exprs
        store-vars)
    (dolist (subform (cdr orig-access-form))
      (if (constantp subform)
        (push subform subforms)
        (let ((var (gensym)))
          (push var subforms)
          (push var subform-vars)
          (push subform subform-exprs))))
    (dotimes (i num-store-vars)
      (push (gensym) store-vars))
    (let ((r-subforms (nreverse subforms))
          (r-subform-vars (nreverse subform-vars))
          (r-subform-exprs (nreverse subform-exprs))
          (r-store-vars (nreverse store-vars)))
      (values r-subform-vars
              r-subform-exprs
              r-store-vars
              (funcall expander (cons r-subforms r-store-vars))
              `(,(car orig-access-form) ,@r-subforms)))))

;;;; DEFMACRO DEFINE-SETF-EXPANDER and various DEFINE-SETF-EXPANDERs

;;; DEFINE-SETF-EXPANDER is a lot like DEFMACRO.
(def!macro sb!xc:define-setf-expander (access-fn lambda-list &body body)
  #!+sb-doc
  "Syntax like DEFMACRO, but creates a setf expander function. The body
  of the definition must be a form that returns five appropriate values."
  (unless (symbolp access-fn)
    (error "~S access-function name ~S is not a symbol."
           'sb!xc:define-setf-expander access-fn))
  (with-unique-names (whole environment)
    (multiple-value-bind (body local-decs doc)
        (parse-defmacro lambda-list whole body access-fn
                        'sb!xc:define-setf-expander
                        :environment environment)
      `(eval-when (:compile-toplevel :load-toplevel :execute)
         (assign-setf-macro ',access-fn
                            (lambda (,whole ,environment)
                              ,@local-decs
                              ,body)
                            ',lambda-list
                            nil
                            ',doc)))))

(sb!xc:define-setf-expander values (&rest places &environment env)
  (declare (type sb!c::lexenv env))
  (collect ((setters) (getters))
    (let ((all-dummies '())
          (all-vals '())
          (newvals '()))
      (dolist (place places)
        (multiple-value-bind (dummies vals newval setter getter)
            (sb!xc:get-setf-expansion place env)
          ;; ANSI 5.1.2.3 explains this logic quite precisely.  --
          ;; CSR, 2004-06-29
          (setq all-dummies (append all-dummies dummies (cdr newval))
                all-vals (append all-vals vals
                                 (mapcar (constantly nil) (cdr newval)))
                newvals (append newvals (list (car newval))))
          (setters setter)
          (getters getter)))
      (values all-dummies all-vals newvals
              `(values ,@(setters)) `(values ,@(getters))))))

(sb!xc:define-setf-expander getf (place prop
                                  &optional default
                                  &environment env)
  (declare (type sb!c::lexenv env))
  (multiple-value-bind (temps values stores set get)
      (sb!xc:get-setf-expansion place env)
    (let ((newval (gensym))
          (ptemp (gensym))
          (def-temp (if default (gensym))))
      (values `(,@temps ,ptemp ,@(if default `(,def-temp)))
              `(,@values ,prop ,@(if default `(,default)))
              `(,newval)
              `(let ((,(car stores) (%putf ,get ,ptemp ,newval))
                     ,@(cdr stores))
                 ,def-temp ;; prevent unused style-warning
                 ,set
                 ,newval)
              `(getf ,get ,ptemp ,@(if default `(,def-temp)))))))

(sb!xc:define-setf-expander get (symbol prop &optional default)
  (let ((symbol-temp (gensym))
        (prop-temp (gensym))
        (def-temp (if default (gensym)))
        (newval (gensym)))
    (values `(,symbol-temp ,prop-temp ,@(if default `(,def-temp)))
            `(,symbol ,prop ,@(if default `(,default)))
            (list newval)
            `(progn ,def-temp ;; prevent unused style-warning
                    (%put ,symbol-temp ,prop-temp ,newval))
            `(get ,symbol-temp ,prop-temp ,@(if default `(,def-temp))))))

(sb!xc:define-setf-expander gethash (key hashtable &optional default)
  (let ((key-temp (gensym))
        (hashtable-temp (gensym))
        (default-temp (if default (gensym)))
        (new-value-temp (gensym)))
    (values
     `(,key-temp ,hashtable-temp ,@(if default `(,default-temp)))
     `(,key ,hashtable ,@(if default `(,default)))
     `(,new-value-temp)
     `(progn ,default-temp ;; prevent unused style-warning
             (%puthash ,key-temp ,hashtable-temp ,new-value-temp))
     `(gethash ,key-temp ,hashtable-temp ,@(if default `(,default-temp))))))

(sb!xc:define-setf-expander logbitp (index int &environment env)
  (declare (type sb!c::lexenv env))
  (multiple-value-bind (temps vals stores store-form access-form)
      (sb!xc:get-setf-expansion int env)
    (let ((ind (gensym))
          (store (gensym))
          (stemp (first stores)))
      (values `(,ind ,@temps)
              `(,index
                ,@vals)
              (list store)
              `(let ((,stemp
                      (dpb (if ,store 1 0) (byte 1 ,ind) ,access-form))
                     ,@(cdr stores))
                 ,store-form
                 ,store)
              `(logbitp ,ind ,access-form)))))

;;; CMU CL had a comment here that:
;;;   Evil hack invented by the gnomes of Vassar Street (though not as evil as
;;;   it used to be.)  The function arg must be constant, and is converted to
;;;   an APPLY of the SETF function, which ought to exist.
;;;
;;; It may not be clear (wasn't to me..) that this is a standard thing, but See
;;; "5.1.2.5 APPLY Forms as Places" in the ANSI spec. I haven't actually
;;; verified that this code has any correspondence to that code, but at least
;;; ANSI has some place for SETF APPLY. -- WHN 19990604
(sb!xc:define-setf-expander apply (functionoid &rest args)
  (unless (and (listp functionoid)
               (= (length functionoid) 2)
               (eq (first functionoid) 'function)
               (symbolp (second functionoid)))
    (error "SETF of APPLY is only defined for function args like #'SYMBOL."))
  (let ((function (second functionoid))
        (new-var (gensym))
        (vars (make-gensym-list (length args))))
    (values vars args (list new-var)
            `(apply #'(setf ,function) ,new-var ,@vars)
            `(apply #',function ,@vars))))

;;; Special-case a BYTE bytespec so that the compiler can recognize it.
;;; FIXME: it is suboptimal that (INCF (LDB (BYTE 9 0) (ELT X 0)))
;;; performs two reads of (ELT X 0), once to get the value from which
;;; to extract a 9-bit subfield, and again to combine the incremented
;;; value with the other bits. I don't think it's wrong per se,
;;; but is worthy of some thought as to whether it can be improved.
(sb!xc:define-setf-expander ldb (bytespec place &environment env)
  #!+sb-doc
  "The first argument is a byte specifier. The second is any place form
acceptable to SETF. Replace the specified byte of the number in this
place with bits from the low-order end of the new value."
  (declare (type sb!c::lexenv env))
  (multiple-value-bind (dummies vals newval setter getter)
      (sb!xc:get-setf-expansion place env)
    (if (and (consp bytespec) (eq (car bytespec) 'byte))
        (let ((n-size (gensym))
              (n-pos (gensym))
              (n-new (gensym)))
          (values (list* n-size n-pos dummies)
                  (list* (second bytespec) (third bytespec) vals)
                  (list n-new)
                  `(let ((,(car newval) (dpb ,n-new (byte ,n-size ,n-pos)
                                             ,getter))
                         ,@(cdr newval))
                     ,setter
                     ,n-new)
                  `(ldb (byte ,n-size ,n-pos) ,getter)))
        (let ((btemp (gensym))
              (gnuval (gensym)))
          (values (cons btemp dummies)
                  (cons bytespec vals)
                  (list gnuval)
                  `(let ((,(car newval) (dpb ,gnuval ,btemp ,getter)))
                     ,setter
                     ,gnuval)
                  `(ldb ,btemp ,getter))))))

(sb!xc:define-setf-expander mask-field (bytespec place &environment env)
  #!+sb-doc
  "The first argument is a byte specifier. The second is any place form
acceptable to SETF. Replaces the specified byte of the number in this place
with bits from the corresponding position in the new value."
  (declare (type sb!c::lexenv env))
  (multiple-value-bind (dummies vals newval setter getter)
      (sb!xc:get-setf-expansion place env)
    (let ((btemp (gensym))
          (gnuval (gensym)))
      (values (cons btemp dummies)
              (cons bytespec vals)
              (list gnuval)
              `(let ((,(car newval) (deposit-field ,gnuval ,btemp ,getter))
                     ,@(cdr newval))
                 ,setter
                 ,gnuval)
              `(mask-field ,btemp ,getter)))))

(defun setf-expand-the (the type place env)
  (declare (type sb!c::lexenv env))
  (multiple-value-bind (temps subforms store-vars setter getter)
      (sb!xc:get-setf-expansion place env)
    (values temps subforms store-vars
            `(multiple-value-bind ,store-vars
                 (,the ,type (values ,@store-vars))
               ,setter)
            `(,the ,type ,getter))))

(sb!xc:define-setf-expander the (type place &environment env)
  (setf-expand-the 'the type place env))

(sb!xc:define-setf-expander truly-the (type place &environment env)
  (setf-expand-the 'truly-the type place env))