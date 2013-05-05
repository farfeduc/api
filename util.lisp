(in-package :tagit)

(defun file-contents (path)
  "Sucks up an entire file from PATH into a freshly-allocated string,
   returning two values: the string and the number of bytes read."
  (with-open-file (s path)
    (let* ((len (file-length s))
           (data (make-string len)))
      (values data (read-sequence data s)))))

(defun load-folder (path)
  "Load all lisp files in a directory."
  (dolist (file (directory (concatenate 'string path "*.lisp")))
    (load file)))

(defun db-sock ()
  "Makes connecting to the database a smidgen easier."
  (r:connect *db-host* *db-port* :db *db-name* :read-timeout 2))

(defun to-json (object)
  "Convert an object to JSON."
  (with-output-to-string (s)
    (yason:encode object s)))

(defun send-json (response object)
  "Wraps sending of JSON back to the client."
  (send-response response
                 :headers '(:content-type "application/json")
                 :body (to-json object)))

(defun add-id (hash-object &key (id "id"))
  "Add a mongo id to a hash table object."
  (setf (gethash id hash-object) (string-downcase (mongoid:oid-str (mongoid:oid)))))

(defun parse-float (string)
  "Return a float read from string, and the index to the remainder of string."
  (multiple-value-bind (integer i)
      (parse-integer string :junk-allowed t)
    (when (<= (1- (length string)) i) (return-from parse-float integer))
    (multiple-value-bind (fraction j)
        (parse-integer string :start (+ i 1) :junk-allowed t)
      (values (float (+ integer (/ fraction (expt 10 (- j i 1))))) j))))

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
      (let* ((key (car entry))
             (entry (cdr entry))
             (entry-type (getf entry :type))
             (obj-entry (multiple-value-list (gethash key object)))
             (obj-val (car obj-entry))
             (exists (cadr obj-entry))
             (default-val (getf entry :default)))
        ;; check required fields
        (when (and (getf entry :required)
                   (not edit)
                   (not obj-val))
          (if default-val
              (setf obj-val default-val)
              (val-error (format nil "Required field `~a` not present." key))))

        ;; if the field doesn't exist, there's no point in validating it further
        (unless exists (return))

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
        
        (case entry-type
          (string
            (let ((slength (getf entry :length)))
              (when (and (integerp slength)
                         (not (= slength (length obj-val))))
                (val-error (format nil "Field `~a` is not the required length (~a characters)" key slength))))))

        ;; TODO validate subobject/subsequence

        ;; set the value (in its processed form) back into the object
        (setf (gethash key object) obj-val)))
    ;; remove junk keys from object data
    (loop for key being the hash-keys of object do
      (unless (val-form key)
        (remhash key object))))
  nil)

(defmacro defvalidator (name validation-form)
  "Makes defining a validation function for a data type simpler."
  `(defmacro ,name ((object future &key edit) &body body)
     (let ((validation (gensym "validation")))
       `(let ((,validation (do-validate ,object ,'',validation-form :edit ,edit)))
          (if ,validation
              (signal-error ,future (make-instance 'validation-failed
                                                   :msg (format nil "Validation failed: ~s~%" ,validation)))
              (progn ,@body))))))

(defmacro defafun (name (future-var &key (forward-errors t)) args &body body)
  "Define an asynchronous function with a returned future that will be finished
   when the funciton completes. Also has the option to forward all async errors
   encountered during excution (in this lexical scope) to the returned future."
  (let* ((docstring (car body))
         (docstring (if (stringp docstring)
                        docstring
                        "")))
    (when (stringp docstring)
      (setf body (cdr body)))
    `(defun ,name ,args
       ,docstring
       (let ((,future-var (make-future)))
         ,(if forward-errors
              `(future-handler-case
                 (progn ,@body)
                 ((or error simple-error condition) (e)
                  (signal-error ,future-var e)))
              `(progn ,@body))
         ,future-var))))

(defun error-json (err)
  "Convert an error object to JSON."
  (let ((msg (error-msg err)))
    (to-json msg)))

(defmacro catch-errors ((response) &body body)
  "Define a macro that catches errors and responds via HTTP to them."
  `(future-handler-case
     (progn ,@body)
     ;; catch errors that can be easily transformed to HTTP
     (tagit-error (e)
      (send-response ,response
                     :status (error-code e)
                     :headers '(:content-type "application/json")
                     :body (error-json e)))
     ;; catch anything else and send a response out for it
     (t (e)
      (format t "(tagit) Caught error: ~a~%" e)
      (unless (as:socket-closed-p (get-socket ,response))
        (send-response ,response
                       :status 500
                       :headers '(:content-type "application/json")
                       :body (to-json
                               (with-output-to-string (s)
                                 (format s "Internal server error. Please report to ~a" *admin-email*)
                                 (when *display-errors*
                                   (format s "~%(~a)" (type-of e))
                                   (if (typep e 'cl-rethinkdb:query-error)
                                       (format s ": ~a~%" (cl-rethinkdb::query-error-msg e))
                                       (format s ": ~a~%" e))))))))))

