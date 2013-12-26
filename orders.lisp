;;;; orders.lisp

(defpackage #:glock.orders
  (:use #:cl #:glock.utils #:glock.requests))

(in-package #:glock.orders)

(defclass order ()
  (actions priority date status price effective-amount amount type item oid currency))


