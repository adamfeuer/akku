#!/usr/bin/env scheme-script
;; -*- mode: scheme; coding: utf-8 -*- !#
;; Copyright © 2017-2018 Göran Weinholt <goran@weinholt.se>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
#!r6rs

;; Main command line interface to Akku.scm.

(import
  (industria strings)
  (only (spells logging) set-logger-properties! log-entry-object)
  (xitomatl AS-match)
  (akku lib bundle)
  (only (akku format lockfile) lockfile-filename)
  (only (akku format manifest) manifest-filename)
  (only (akku lib graph) print-gv-file)
  (only (akku lib init) init-manifest)
  (only (akku lib install) install)
  (only (akku lib lock) logger:akku.lock lock-dependencies
        add-dependency list-packages)
  (only (akku lib utils) path-join application-home-directory)
  (rnrs (6)))

(define (simple-log-formatter entry)
  (let ((port (current-error-port))
        (obj (log-entry-object entry)))
    (if (procedure? obj)
        (obj port)
        (display obj port))
    (newline port)))

(define (get-index-filename)
  (let ((index (path-join (application-home-directory) "share/index.db"))
        (bootstrap (path-join (application-home-directory) "share/bootstrap.db")))
    (cond ((and (file-exists? "bootstrap.db") (file-exists? "bin/akku.sps"))
           ;; Running from the Akku repository
           "bootstrap.db")
          ((file-exists? index) index)
          ((file-exists? bootstrap) bootstrap)
          (else (error 'cmd-lock "Unable to locate the package index")))))

(define (cmd-help)
  (display "akku - Scheme package manager

Simple usage:
 akku list - list all packages in the index
 akku install <pkg> - all-in-one add/lock/install a package

Basic usage:
 akku add <pkg> - add a dependency to Akku.manifest
 akku add <pkg>@<range> - add a versioned dependency
 akku add --dev <pkg> - add a development dependency
 akku init - create a draft Akku.manifest (not yet useful)
 akku lock - generate Akku.lock from Akku.manifest and the index
 akku install - install dependencies according to Akku.lock

Advanced usage:
 akku graph - print a graphviz file showing library dependencies
 akku dependency-scan <filename(s)> - print source code dependencies
 akku license-scan <filename(s)> - scan dependencies for notices

" (current-error-port))
  (exit 0))

(define (cmd-add arg*)
  (when (null? arg*)
    (cmd-help))
  (let ((dev? (member "--dev" arg*))
        (dep* (remove "--dev" arg*)))
    (for-each
     (lambda (dep)
       (let-values (((package-name range)
                     (match (string-split dep #\@)
                       [(package-name range) (values package-name range)]
                       [(package-name) (values package-name #f)])))
         (let ((package-name (if (char=? (string-ref package-name 0) #\()
                                 (read (open-string-input-port package-name))
                                 package-name)))
           (add-dependency manifest-filename (get-index-filename)
                           dev? package-name range))))
     dep*)))

(define (cmd-init arg*)
  (unless (null? arg*)
    (cmd-help))
  ;; (when (file-exists? manifest-filename)
  ;;   ;; XXX: well... it should do something useful
  ;;   (error 'install "The manifest already exists" manifest-filename))
  (init-manifest manifest-filename "."))

(define (cmd-list arg*)
  (unless (null? arg*)
    (cmd-help))
  (list-packages manifest-filename lockfile-filename (get-index-filename)))

(define (cmd-lock arg*)
  (unless (null? arg*)
    (cmd-help))
  (unless (file-exists? manifest-filename)
    (error 'install "There is no manifest: run 'akku add <pkg>' first"
           manifest-filename))
  (lock-dependencies manifest-filename
                     lockfile-filename
                     (get-index-filename)))

(define (cmd-install arg*)
  (cond ((null? arg*)
         ;; Install locked dependencies.
         (unless (file-exists? lockfile-filename)
           (cmd-lock '()))
         (install lockfile-filename))
        (else
         ;; All-in-one automatic installation of a package.
         (cmd-add arg*)
         (cmd-lock '())
         (cmd-install '()))))

(define (cmd-graph . _)
  (print-gv-file "."))

(define (cmd-dependency-scan arg*)
  (when (null? arg*)
    (display "ERROR: You must provide at least one program or library entry point\n\n"
             (current-error-port))
    (cmd-help))
  (dependency-scan arg* '(chezscheme))) ;TODO

(define (cmd-license-scan arg*)
  (when (null? arg*)
    (display "ERROR: You must provide at least one program or library entry point\n\n"
             (current-error-port))
    (cmd-help))
  (license-scan arg* '(chezscheme)))    ;TODO

(set-logger-properties! logger:akku.lock
                        `((threshold info)
                          (handlers ,simple-log-formatter)))

;; TODO: get a real command line parser.
(cond
  ((null? (cdr (command-line)))
   (cmd-help))
  ((string=? (cadr (command-line)) "add")
   (cmd-add (cddr (command-line))))
  ;; TODO: remove
  ((string=? (cadr (command-line)) "init")
   (cmd-init (cddr (command-line))))
  ((string=? (cadr (command-line)) "list")
   (cmd-list (cddr (command-line))))
  ((string=? (cadr (command-line)) "lock")
   (cmd-lock (cddr (command-line))))
  ((string=? (cadr (command-line)) "install")
   (cmd-install (cddr (command-line))))
  ((string=? (cadr (command-line)) "graph")
   (cmd-graph (cddr (command-line))))
  ((string=? (cadr (command-line)) "dependency-scan")
   (cmd-dependency-scan (cddr (command-line))))
  ((string=? (cadr (command-line)) "license-scan")
   (cmd-license-scan (cddr (command-line))))
  (else
   (cmd-help)))
