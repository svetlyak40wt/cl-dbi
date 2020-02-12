(defpackage #:dbi
  (:use #:cl
        #:dbi.error)
  (:nicknames #:cl-dbi)
  (:import-from #:dbi.driver
                #:list-all-drivers
                #:find-driver
                #:connection-driver-type
                #:connection-database-name
                #:make-connection
                #:disconnect
                #:prepare
                #:execute
                #:fetch
                #:fetch-all
                #:do-sql
                #:begin-transaction
                #:in-transaction
                #:commit
                #:rollback
                #:savepoint
                #:rollback-savepoint
                #:release-savepoint
                #:with-savepoint
                #:with-transaction
                #:ping
                #:row-count
                #:transaction-done-condition
                #:free-query-resources)
  (:import-from #:dbi.logger
                #:*sql-execution-hooks*
                #:simple-sql-logger)
  (:import-from #:bordeaux-threads
                #:current-thread
                #:thread-alive-p)
  (:export #:list-all-drivers
           #:find-driver
           #:connection-driver-type
           #:connection-database-name
           #:disconnect
           #:prepare
           #:execute
           #:fetch
           #:fetch-all
           #:do-sql
           #:begin-transaction
           #:in-transaction
           #:commit
           #:rollback
           #:savepoint
           #:rollback-savepoint
           #:release-savepoint
           #:with-savepoint
           #:with-transaction
           #:ping
           #:row-count
           #:free-query-resources

           #:dbi-error
           #:dbi-warning
           #:dbi-interface-error
           #:dbi-unimplemented-error
           #:dbi-database-error
           #:dbi-data-error
           #:dbi-operational-error
           #:dbi-integrity-error
           #:dbi-internal-error
           #:dbi-programming-error
           #:dbi-notsupported-error

           ;; logger
           #:*sql-execution-hooks*
           #:simple-sql-logger)
  (:export #:connect
           #:connect-cached
           #:with-connection))
(in-package #:dbi)

(defun connect (driver-name &rest params &key database-name &allow-other-keys)
  "Open a connection to the database which corresponds to `driver-name`."
  (declare (ignore database-name))
  (let ((driver (find-driver driver-name)))
    (unless driver
      (load-driver driver-name)
      (setf driver (find-driver driver-name)))

    (unless driver
      (error 'simple-error
             :format-control "Driver ~A is not found."
             :format-arguments driver-name))

    (apply #'make-connection (make-instance driver) params)))

(defun make-connection-pool ()
  (make-hash-table :test 'equal))

#+thread-support
(defun make-threads-connection-pool ()
  (let ((pool (make-hash-table :test 'eq)))
    (setf (gethash (bt:current-thread) pool) (make-connection-pool))
    pool))
#-thread-support
(defun make-threads-connection-pool ()
  (make-connection-pool))

(defvar *threads-connection-pool* (make-threads-connection-pool))

(defun get-connection-pool ()
  (or (gethash (bt:current-thread) *threads-connection-pool*)
      (setf (gethash (bt:current-thread) *threads-connection-pool*)
            (make-connection-pool))))

(defun connect-cached (&rest connect-args)
  (let* ((pool (get-connection-pool))
         (conn (gethash connect-args pool)))
    (cond
      ((null conn)
       (cleanup-connection-pool)
       (setf (gethash connect-args pool)
             (apply #'connect connect-args)))
      ((not (ping conn))
       (disconnect conn)
       (remhash connect-args pool)
       (cleanup-connection-pool)
       (setf (gethash connect-args pool)
             (apply #'connect connect-args)))
      (t conn))))

(defvar *connection-pool-cleanup-lock*
  (bt:make-lock "connection-pool-cleanup-lock"))
(defun cleanup-connection-pool ()
  (bt:with-lock-held (*connection-pool-cleanup-lock*)
    (maphash (lambda (thread pool)
               (unless (bt:thread-alive-p thread)
                 (maphash (lambda (args conn)
                            (declare (ignore args))
                            (disconnect conn))
                          pool)
                 (remhash thread *threads-connection-pool*)))
             *threads-connection-pool*)))

(defmacro with-retrying (&body body)
  (let ((retrying (gensym))
        (e (gensym))
        (restart (gensym)))
    `(let ((,retrying (make-hash-table :test 'equal)))
       (handler-bind ((asdf:missing-component
                        (lambda (,e)
                          (unless (gethash (asdf::missing-requires ,e) ,retrying)
                            (let ((,restart (find-restart 'asdf:retry)))
                              (when ,restart
                                (setf (gethash (asdf::missing-requires ,e) ,retrying) t)
                                (asdf:clear-configuration)
                                (invoke-restart ,restart)))))))
         ,@body))))

(defun load-driver (driver-name)
  (let ((driver-system (intern (format nil "DBD-~A" driver-name) :keyword)))
    #+quicklisp
    (with-retrying
      (ql:quickload driver-system :verbose nil :silent t))
    #-quicklisp
    (asdf:load-system driver-system :verbose nil)))


(defmacro with-connection ((conn-sym &rest rest) &body body)
  `(let ((,conn-sym (connect ,@rest)))
     (unwind-protect
          (progn ,@body)
       (disconnect ,conn-sym))))
