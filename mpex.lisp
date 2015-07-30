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
                      (mapcar #'car (with-open-stream
                                        (response (get-request "mktdepth"))
                                      (read-json response))))
              assets))))

(defmethod fetch-exchange-data ((exchange (eql *mpex*)))
  (with-slots (markets assets) exchange
    (setf (values markets assets) (get-info))))

;;; https://github.com/jurov/MPExAgent
(defclass mpex-agent (gate)
  ((exchange :allocation :class :initform *mpex*)))

(defmethod gate-post ((gate (eql *mpex*)) key secret request
                      &aux (reply-id (sxhash request)))
  (with-open-stream (response
      (http-request key :content-type "text/plain" :method :post
                    :want-stream t :external-format-in :ascii
                    :basic-authorization secret :content
                    (json:encode-json-plist-to-string
                     `("method" ,(car request)
                       "params" ,(apply 'vector (cdr request))
                       "jsonrpc" "2.0" "id" ,reply-id))))
    (json:json-bind (jsonrpc result error id) response
        (assert (string= jsonrpc "2.0")) (when id (assert (= reply-id id)))
        (list result error))))

;;;
;;; Public Data API
;;;

(defmethod get-book ((market mpex-market) &key)
  (awhen (with-open-stream (response (get-request "mktdepth"))
           (assoc (name market) (read-json response)))
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
    (let* ((price (parse-float price :start 1 :type 'rational))
           (volume (parse-integer (remove #\` amount)))
           (cost (* price volume)))
      (make-instance 'trade :market (find-market market *mpex*) :cost cost
                     :timestamp (parse-rfc1123-timestring (rss:pub-date item))
                     :price price :direction "slold" :volume volume))))

(defun trades-rss ()
  (with-open-stream (stream (get-request "rss"))
    (rss:items (rss:parse-rss-stream stream))))

(defmethod trades-since ((market mpex-market) &optional since)
  (aprog1 (nreverse (remove-if-not (lambda (trade)
                                     (eq (name (market trade)) (name market)))
                                   (mapcar #'parse-trade (trades-rss))))
    (when since
      (flet ((same-trade (a b)
               (and (timestamp= (timestamp a) (timestamp b))
                    (         =  (volume  a)     (volume b))
                    (         =   (price a)       (price b)))))
        (awhen (member since it :test #'same-trade)
          (return-from trades-since (rest it))))
      (flet ((hms (time) (subseq (princ-to-string (timestamp time)) 11 19)))
        (warn "missing trades: ~A - ~A" (hms since) (hms (first it)))))))

;;;
;;; Private Data API
;;;

(defun parse-placed (statjson)
  (mapcar (lambda (data &aux (oid (parse-integer (string (pop data)))))
            (flet ((value (key) (cdr (assoc key data)))) ; i smell a pattern
              (let ((aksp (string-equal (value :+bs+) "S"))
                    (market (find-market (value :+mpsic+) *mpex*))
                    (volume (value :*quantity)) (price (value :*price)))
                (make-instance 'placed :oid oid :volume volume :market market
                               :given (if aksp (cons-aq (primary market) volume)
                                          (cons-aq (counter market)
                                                   (* price volume)))
                               :price (* price (if aksp 1 -1))))))
          (cdr (assoc :*book statjson))))

(defun parse-balances (statjson)
  (let ((placed (parse-placed statjson))
        (funds (make-hash-table :size (length (assets *mpex*)))))
    (flet ((incf-fund (asset amount)
             (incf (gethash asset funds 0) amount)))
      (dolist (offer placed)
        (incf-fund (consumed-asset offer) (quantity (given offer)))))
    (mapcar (lambda (pair &aux (asset (asset pair)))
              (cons-aq asset (+ (quantity pair) (gethash asset funds 0))))
            (mapcar (lambda (data)
                      (destructuring-bind (a . q) data
                        (cons-aq (find-asset
                                  (if (eq a :*cx-+btc+) "CxBTC"
                                      (string-trim
                                       "+" (string (car data))))
                                  *mpex*) q)))
                    (cdr (assoc :*holdings statjson))))))

(defmethod placed-offers ((gate mpex-agent))
  (awhen (gate-request gate "statjson")  (parse-placed  it)))

(defmethod account-balances ((gate mpex-agent))
  (awhen (gate-request gate "statjson") (parse-balances it)))

;;; All sellers are assesed a 0.2% fee at the moment the sale completes (so if
;;; you sell 500 stocks for 100 satoshi each you get 49`900 satoshi or
;;; 0.000499 BTC). All MKOPT and MKFUT orders are assesed a 2% fee
(defmethod market-fee ((gate mpex-agent) (market market)) '(0 . 0.2))

(defun parse-execution (data)
  (flet ((value (key) (cdr (assoc key data))))  ; i smell a pattern
    (let* ((direction (value :+bs+)) (volume (value :*quantity))
           (market (find-market (value :+mpsic+) *mpex*))
           (phactor (expt 10 (- (decimals market))))
           (price (* (value :*price) phactor)) (cost (* price volume))
           (timestamp (parse-rfc3339-timestring (value :*date))))
      (make-instance 'execution :direction direction :market market
                     :price price :timestamp timestamp ; TODO: :fee?
                     ;; (sqrt (expt 16 4)) => unhappy birthday
                     :txid (format () "~A~A~D" (value :*track) direction
                                   (timestamp-to-unix timestamp))
                     :volume volume :net-volume volume :cost cost
                     :net-cost (if (string= direction "B") cost
                                   (* (floor (* cost 998/1000) ; yuck
                                             phactor) phactor))))))

;;; The trade and dividend history start with the first transaction after a
;;; point in time one hour previous to the last STAT issued to that user.
(defun raw-executions (gate)
  (cdr (assoc :*trade-history (gate-request gate "statjson"))))

(defmethod execution-since ((gate mpex-agent) market since)
  (awhen (raw-executions gate)          ; spot the twist?
    (let ((parsed (sort (remove market (mapcar #'parse-execution it)
                                :key #'market :test-not #'eq)
                        #'timestamp< :key #'timestamp)))
      (if (null since) parsed
          (member (timestamp since) parsed
                  :key #'timestamp :test #'timestamp<)))))

(defun post-raw-limit (gate type market price volume)
  ;; TODO: optional price & expiry
  (awhen (gate-request gate "neworder" (list type market volume price))
    (flet ((value (key) (cdr (assoc key it))))  ; i smell a pattern
      (and (string= (value :result) "OK") ; TODO: fail earlier
           (apply #'values (mapcar #'value '(:order :message :track)))))))

(defmethod post-offer ((gate mpex-agent) (offer offer))
  (with-slots (market volume price) offer
    (flet ((post (type) ; TODO: fail loudierly
             (awhen (post-raw-limit gate type (string (name market))
                                    (abs price) (round volume))
               (flet ((value (key) (cdr (assoc key it))))
                 (dotimes (verbosely-named-attempt-index 5)
                   (sleep (random (exp 1)))
                   (awhen (find-if (lambda (placed)
                                     (every #'eql
                                            (list (volume placed)
                                                  (price  placed)
                                                  (market placed))
                                            (list (value :amount)
                                                  price market)))
                                   (placed-offers gate))
                     (return (change-class offer 'placed :oid (oid it)
                                           :volume (value :amount)))))))))
      (post (if (< price 0) "B" "S")))))

(defmethod cancel-offer ((gate mpex-agent) offer)
  (awhen (gate-request gate "cancel" (list (oid offer)))
    (flet ((value (key) (cdr (assoc key it))))  ; i smell a pattern
      (if (string= (value :result) "OK") (value :message)
          (values () (value :result) (value :message))))))
