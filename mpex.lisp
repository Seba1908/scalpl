(defpackage #:scalpl.mpex
  (:nicknames #:mpex)
  (:export #:*mpex* #:mpex-agent)
  (:use #:cl #:chanl #:anaphora #:local-time
        #:split-sequence #:scalpl.util #:scalpl.exchange))

(in-package #:scalpl.mpex)

;;; General Parameters
(defparameter +base-path+ "http://mpex.co/")  ; TODO: auto-fallback to proxies
(defparameter +public-stub+ "mpex-")

(defun raw-request (path &rest keys)
  (multiple-value-bind (body status)
      (apply #'http-request (concatenate 'string +base-path+ path) keys)
    (if (= status 200) body
        (values nil (format nil "HTTP Error ~D~%~A" status body)))))

(defun get-request (path)
  (raw-request (concatenate 'string +public-stub+ path ".php") :want-stream t))

(defvar *mpex* (make-instance 'exchange :name :mpex))

;; (defun post-request (method key signer &optional params &aux (nonce (nonce)))
;;   (push (cons "method" method) params)
;;   (push (cons "nonce" nonce) params)
;;   (let ((data (urlencode-params params)))
;;     (raw-request (concatenate 'string +private-stub+)
;;                  :method :post :content data
;;                  :additional-headers `(("Key"  . ,key)
;;                                        ("Sign" . ,(funcall signer data))))))

(defclass mpex-market (market) ((exchange :initform *mpex*)))  ; FIXME is-a → has-a

(defun get-info ()
  (flet ((make-asset (name &optional (d 0))
           (make-instance 'asset :name name :decimals d :exchange *mpex*)))
    (let* ((bitcoin (make-asset "CxBTC" 8)) (assets (list bitcoin)))
      (values (mapcar (lambda (name &aux (asset (make-asset name)))
                        (push asset assets)
                        (make-instance 'mpex-market :primary asset :counter bitcoin
                                       :exchange *mpex* :decimals 8 :name name))
                      (mapcar #'car (read-json (get-request "mktdepth"))))
              assets))))

(defmethod fetch-exchange-data ((exchange (eql *mpex*)))
  (with-slots (markets assets) exchange
    (setf (values markets assets) (get-info))))

;;; https://github.com/jurov/MPExAgent
(defclass mpex-agent (gate)
  ((exchange :allocation :class :initform *mpex*)))

(defmethod gate-post ((gate (eql *mpex*)) key secret request
                      &aux (reply-id (sxhash request)))
  (json:json-bind (jsonrpc result error id)
      (http-request key :content-type "text/plain" :method :post
                    :want-stream t :external-format-in :ascii
                    :basic-authorization secret :content
                    (json:encode-json-plist-to-string
                     `("method" ,(car request)
                       "params" ,(apply 'vector (cdr request))
                       "jsonrpc" "2.0" "id" ,reply-id)))
    (assert (string= jsonrpc "2.0")) (when id (assert (= reply-id id)))
    (list result error)))

;;;
;;; Public Data API
;;;

(defmethod get-book ((market mpex-market) &key)
  (awhen (assoc (name market) (read-json (get-request "mktdepth")))
    (flet ((process (side class predicate)
             (destructuring-bind (token &rest data) (pop it)
               (assert (eq token side))
               (mapcar (lambda (pair)
                         (make-instance class :market market
                                        :price (car pair) :volume (cadr pair)))
                       (sort data predicate :key #'first)))))
      (pop it) (values (process :S 'ask #'<) (process :B 'bid #'>)))))

(defun parse-trade (item)
  (destructuring-bind (amount market price)
      (split-sequence #\Space (rss:title item))
    (make-instance 'trade :market (find-market market *mpex*)
                   ;; TODO: :timestamp, :cost
                   :volume (parse-integer (remove #\` amount))
                   :price (parse-price (subseq price 1) 8)
                   :direction (fourth (split-sequence #\Space (rss:description item))))))
(defmethod trades-since ((market mpex-market) &optional since)
  (remove market (mapcar #'parse-trade
                         (rss:items (rss:parse-rss-stream (get-request "rss"))))
          :test-not #'eq :key #'market))

;;;
;;; Private Data API
;;;

(defmethod placed-offers ((gate mpex-agent)) (error "FIXME"))

(defmethod account-balances ((gate mpex-agent)) (error "FIXME"))

;;; All sellers are assesed a 0.2% fee at the moment the sale completes (so if
;;; you sell 500 stocks for 100 satoshi each you get 49`900 satoshi or
;;; 0.000499 BTC). All MKOPT and MKFUT orders are assesed a 2% fee
(defmethod market-fee ((gate t) (market mpex-market)) '(0 . 0.2))

(defun parse-execution (txid json) (error "FIXME"))
(defun raw-executions (gate &key pair from end) (error "FIXME"))
(defmethod execution-since ((gate mpex-agent) market since) (error "FIXME"))

(defun post-raw-limit (gate type market price volume) (error "FIXME"))
(defmethod post-offer ((gate mpex-agent) offer) (error "FIXME"))

(defun cancel-raw-order (gate oid) (error "FIXME"))
(defmethod cancel-offer ((gate mpex-agent) offer) (error "FIXME"))