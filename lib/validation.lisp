(in-package :turtl)

(defun idp (id) (cl-ppcre:scan "^[0-9a-f]{24,80}" id))
(deftype id () '(satisfies idp))

(defvar *validation-forms* nil
  "Holds name -> form mappings for validation forms.")

(defun do-validate (object validation-form &key edit)
  "Validation a hash object against a set of rules. Returns nil on *success* and
   returns the errors on failure."
  (flet ((val-form (key)
           (let ((form nil))
             (dolist (entry validation-form)
               (when (string= key (car entry))
                 (setf form entry)
                 (return)))
             form))
         (val-error (str)
           (return-from do-validate str)))
    (dolist (entry validation-form)
      (block do-validate-next
        (let* ((key (car entry))
               (entry (cdr entry))
               (entry-type (getf entry :type))
               (coerce-to (getf entry :coerce))
               (transform (getf entry :transform))
               (validator (getf entry :validator))
               (obj-entry (multiple-value-list (gethash key object)))
               (obj-val (car obj-entry))
               (exists (cadr obj-entry))
               (default-val (getf entry :default)))
          ;; check required fields
          (when (and (getf entry :required)
                     (not edit)
                     (not exists))
            (cond ((and default-val (symbolp default-val))
                   (setf obj-val (funcall default-val)))
                  (default-val
                   (setf obj-val default-val))
                  (t
                   (val-error (format nil "Required field `~a` not present." key)))))

          ;; if the field doesn't exist, there's no point in validating it further
          (unless exists (return-from do-validate-next))

          ;; check sub-objects against the given validator
          (when (and (typep obj-val 'hash-table)
                     validator)
            (let ((validation (do-validate obj-val
                                           (getf *validation-forms* validator)
                                           :edit edit)))
              (if validation
                  (return-from do-validate validation)
                  (progn
                    (setf (gethash key object) obj-val)
                    (return-from do-validate-next)))))

          ;; do some typing work
          (when entry-type
            ;; convert strings to int/float if needed
            (when (and (typep obj-val 'string)
                       (subtypep entry-type 'number))
              (let ((new-val (ignore-errors (parse-float obj-val))))
                (when new-val
                  (setf obj-val new-val))))
            ;; make sure the types match up
            (when (not (typep obj-val entry-type))
              (val-error (format nil "Field `~a` is not of the expected type ~a" key entry-type))))

          ;; check if we want to convert this object to a definitive type
          (when coerce-to
            (setf obj-val (coerce obj-val coerce-to)))
          
          (case entry-type
            (string
              (let ((length (getf entry :length))
                    (min-length (getf entry :min-length))
                    (max-length (getf entry :max-length)))
                (when (and (integerp length)
                           (not (= length (length obj-val))))
                  (val-error (format nil "Field `~a` is not the required length (~a characters)" key length)))
                (when (and (integerp min-length)
                           (not (<= min-length (length obj-val))))
                  (val-error (format nil "Field `~a` must be at least ~a characters long" key min-length)))
                (when (and (integerp max-length)
                           (not (<= (length obj-val) max-length)))
                  (val-error (format nil "Field `~a` must be no more than ~a characters long" key max-length))))))

          (when transform
            (setf obj-val (funcall transform obj-val)))

          ;; set the value (in its processed form) back into the object
          (setf (gethash key object) obj-val))))
    ;; remove junk keys from object data
    (loop for key being the hash-keys of object do
      (unless (val-form key)
        (remhash key object))))
  nil)

(defmacro defvalidator (name validation-form &key old)
  "Makes defining a validation function for a data type simpler."
  `(progn
     (setf (getf *validation-forms* ',name) ',validation-form)
     (defmacro ,name (,(append '(object)
                               (when old '(future))
                               '(&key edit))
                       &body body)
       (let ((validation (gensym "validation"))
             (validation-form-var (gensym "validation-form"))
             (future-var (gensym "future")))
         `(let* ((,future-var ,,(when old 'future))
                 (,validation-form-var (getf *validation-forms* ,'',name))
                 (,validation (do-validate ,object ,validation-form-var :edit ,edit)))
            (declare (ignorable ,future-var))
            (if ,validation
                ,(if ,old
                     `(signal-error ,future-var (make-instance 'validation-failed
                                                              :msg (format nil "Validation failed: ~s~%" ,validation)))
                     `(error 'validation-failed :msg (format nil "Validation failed: ~s~%" ,validation)))
                (progn ,@body)))))))

;(defmacro defvalidator (name validation-form)
;  "Makes defining a validation function for a data type simpler."
;  `(progn
;     (setf (getf *validation-forms* ',name) ',validation-form)
;     (defun ,name (object &key edit)
;       (let ((validation (gensym "validation"))
;             (validation-form-var (gensym "validation-form")))
;         (with-promise (res rej)
;           (let* ((validation-form (getf *validation-forms* ',name))
;                  (validation (do-validate object validation-form :edit edit)))
;             (if validation
;                 (rej (make-instance 'validation-failed
;                                     :msg (format nil "Validation failed: ~s~%" validation)))
;                 (res))))))))

