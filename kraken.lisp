(defpackage #:scalpl.kraken
  (:use #:cl #:anaphora #:st-json #:scalpl.util #:scalpl.exchange)
  (:export #:get-request
           #:post-request
           #:find-market #:*kraken* #:kraken-gate
           #:make-key #:make-signer))

(in-package #:scalpl.kraken)

;;; General Parameters
(defparameter +base-path+ "https://api.kraken.com/0/")

(defun hmac-sha512 (message secret)
  (let ((hmac (ironclad:make-hmac secret 'ironclad:sha512)))
    (ironclad:update-hmac hmac message)
    (base64:usb8-array-to-base64-string (ironclad:hmac-digest hmac))))

(defun hash-sha256 (message)
  (ironclad:digest-sequence :sha256 message))

;;; API-Key = API key
;;; API-Sign = Message signature using HMAC-SHA512 of (URI path + SHA256(nonce + POST data)) and base64 decoded secret API key

(defgeneric make-signer (secret)
  (:method ((signer function)) signer)
  (:method ((secret string))
    (lambda (path data nonce)
      (hmac-sha512 (concatenate '(simple-array (unsigned-byte 8) (*))
                                (map '(simple-array (unsigned-byte 8) (*)) 'char-code path)
                                (hash-sha256 (map '(simple-array (unsigned-byte 8) (*))
                                                  'char-code
                                                  (concatenate 'string nonce (urlencode-params data)))))
                   (base64:base64-string-to-usb8-array secret))))
  (:method ((stream stream)) (make-signer (read-line stream)))
  (:method ((path pathname)) (with-open-file (stream path) (make-signer stream))))

(defgeneric make-key (key)
  (:method ((key string)) key)
  (:method ((stream stream)) (read-line stream))
  (:method ((path pathname))
    (with-open-file (stream path)
      (make-key stream))))

(defun decode-json (arg)
  (st-json:read-json arg))

(defun raw-request (path &rest keys)
  ;; (cond
  ;;   ((or (search "AddOrder" path)
  ;;        (search "CancelOrder" path)))
  ;;   ((or (search "Trades" path)
  ;;        (search "Ledgers" path))
  ;;    (format t "~&API counter +2 from ~A" path))
  ;;   (t (format t "~&API counter +1 from ~A" path)))
  (handler-case
      (multiple-value-bind (body status)
          (apply #'drakma:http-request
                 (concatenate 'string +base-path+ path)
                 ;; Mystery crash on the morning of 2014-06-04
                 ;; entered an infinite loop of usocket:timeout-error
                 ;; lasted for hours, continued upon restart
                 ;; other programs on the same computer not affected - just sbcl
                 :connection-timeout 60
                 keys)
        (case status
          (200 (with-json-slots (result error)
                   (decode-json (map 'string 'code-char body))
                 (values result error)))
          (502 (format t "~&Retrying after 502...~%")
               (sleep 1)
               (apply #'raw-request path keys))
          (t (cerror "Retry request" "HTTP Error ~D" status)
             (apply #'raw-request path keys))))
    (drakma::drakma-simple-error ()
      (format t "~&Retrying after drakma SIMPLE crap...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (drakma::simple-error ()
      (format t "~&Retrying after drakma crap...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (cl+ssl::ssl-error-zero-return ()
      (format t "~&Retrying after cl+ssl crap...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (cl+ssl::ssl-error-syscall ()
      (format t "~&Retrying after cl+ssl crap...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (usocket:ns-host-not-found-error ()
      (format t "~&Retrying after nameserver crappage...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (usocket:deadline-timeout-error ()
      (format t "~&Retrying after deadline timeout...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (usocket:timeout-error ()
      (format t "~&Retrying after regular timeout...~%")
      (sleep 1)
      (apply #'raw-request path keys))))

(defun get-request (path &optional data)
  (raw-request (concatenate 'string "public/" path "?"
                            (urlencode-params data))
               :parameters data))

(defun nonce (&aux (now (local-time:now)))
  (princ-to-string (+ (floor (local-time:nsec-of now) 1000)
                      (* 1000000 (local-time:timestamp-to-unix now)))))

(defun post-request (method key signer &optional data &aux (nonce (nonce)))
  (let ((path (concatenate 'string "/0/private/" method)))
    (push (cons "nonce" nonce) data)
    (raw-request (concatenate 'string "private/" method)
                 :method :post
                 :parameters data
                 :additional-headers `(("API-Key"  . ,key)
                                       ("API-Sign" . ,(funcall signer path data nonce))
                                       ("Content-Type" . "application/x-www-form-urlencoded")))))

(defun get-assets ()
  (mapcar-jso (lambda (name data)
                (with-json-slots (altname decimals) data
                  (make-instance 'asset :name name :decimals decimals)))
              (get-request "Assets")))

(defclass kraken-market (market) ((altname :initarg :altname :reader altname-of)))

(defun get-markets (assets)
  (mapcar-jso (lambda (name data)
                (with-json-slots (pair_decimals quote base altname) data
                  (make-instance 'kraken-market :name name :altname altname
                                 :base (find-asset base assets)
                                 :quote (find-asset quote assets)
                                 :decimals pair_decimals)))
              (get-request "AssetPairs")))

(defvar *kraken*
  (let ((assets (get-assets)))
    (make-instance 'exchange :name "Kraken"
                   :assets assets :markets (get-markets assets))))

(defmethod find-market (designator (exchange (eql *kraken*)))
  (or (call-next-method)
      (with-slots (markets) *kraken*
        (find designator markets :key 'altname-of :test 'string-equal))))

(defclass kraken-gate (gate) ())

(defmethod gate-post ((gate kraken-gate) key secret request)
  (destructuring-bind (command . options) request
    (multiple-value-list (post-request command key secret options))))

(defmethod shared-initialize ((gate kraken-gate) names &key pubkey secret)
  (multiple-value-call #'call-next-method gate names
                       (when pubkey (values :pubkey (make-key pubkey)))
                       (when secret (values :secret (make-signer secret)))))

;;;
;;; Offer Manipulation API
;;;

(defun post-limit (gate type pair price volume decimals &optional options)
  (let ((price (/ price (expt 10d0 decimals))))
    (multiple-value-bind (info errors)
        (gate-request gate "AddOrder"
                      `(("ordertype" . "limit")
                        ("type" . ,type)
                        ("pair" . ,pair)
                        ("volume" . ,(format nil "~F" volume))
                        ("price" . ,(format nil "~F" price))
                        ,@(when options `(("oflags" . ,options)))
                        ))
      (if errors
          (dolist (message errors)
            (if (and (search "volume" message) (not (search "viqc" options)))
                (return
                  (post-limit gate type pair price (* volume price) 0
                              (apply #'concatenate 'string "viqc"
                                     (when options '("," options)))))
                (format t "~&~A~%" message)))
          (progn
            ;; theoretically, we could get several order IDs here,
            ;; but we're not using any of kraken's fancy forex nonsense
            (setf (getjso* "descr.id" info) (car (getjso* "txid" info)))
            (getjso "descr" info))))))

(defmethod post-offer ((gate kraken-gate) offer)
  ;; (format t "~&place  ~A~%" offer)
  (with-slots (market volume price) offer
    (flet ((post (type options)
             (awhen (post-limit gate type (name-of market) (abs price) volume
                                (slot-value market 'decimals)
                                options)
               (with-json-slots (id order) it
                 (change-class offer 'placed :id id :text order)))))
      (if (< price 0)
          (post "buy" "viqc")
          (post "sell" nil)))))

(defun cancel-order (gate oid)
  (gate-request gate "CancelOrder" `(("txid" . ,oid))))

(defmethod cancel-offer ((gate kraken-gate) offer)
  ;; (format t "~&cancel ~A~%" offer)
  (multiple-value-bind (ret err) (cancel-order gate (offer-id offer))
    (or ret (search "Unknown order" (car err)))))

(defun open-orders (gate)
  (mapjso* (lambda (id order) (setf (getjso "id" order) id))
           (getjso "open" (gate-request gate "OpenOrders"))))

(defmethod placed-offers (gate)
  (mapcar-jso (lambda (id data)
                (with-json-slots (descr vol oflags) data
                  (with-json-slots (pair type price order) descr
                    (let* ((market (find-market pair *kraken*))
                           (decimals (slot-value market 'decimals))
                           (price-int (parse-price price decimals))
                           (volume (read-from-string vol)))
                      (make-instance 'placed
                                     :id id :text order :market market
                                     :price (if (string= type "buy") (- price-int) price-int)
                                     :volume (if (not (search "viqc" oflags)) volume
                                                 (/ volume price-int (expt 10 decimals))))))))
              (open-orders gate)))