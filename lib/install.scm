;; -*- mode: scheme; coding: utf-8 -*-
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

;; Copies code and notices from projects to .akku/.

(library (akku lib install)
  (export
    install
    libraries-directory file-list-filename
    make-r6rs-library-filenames)
  (import
    (rnrs (6))
    (only (srfi :13 strings) string-index)
    (only (rnrs r5rs) quotient remainder)
    (only (xitomatl common) pretty-print)
    (xitomatl alists)
    (xitomatl AS-match)
    (only (akku format manifest) manifest-filename)
    (only (akku lib compat) mkdir chmod file-directory?
          file-symbolic-link? file-exists/no-follow? symlink)
    (akku lib file-parser)
    (akku lib git)
    (akku lib init)
    (akku lib lock)
    (akku lib library-name)
    (akku lib repo-scanner)
    (akku lib utils))

(define (support-windows?)
  #f)

(define (akku-directory)
  ".akku")

(define (sources-directory*) "src")

(define (sources-directory)
  (path-join (akku-directory) (sources-directory*)))

(define (project-sanitized-name project)
  ;; Turns a project name into that works as a directory name.
  (define hex "0123456789abcdefgh")
  (let ((dirname (if (string? (project-name project))
                     (project-name project)
                     (call-with-string-output-port
                       (lambda (p)
                         (display (project-name project) p))))))
    (call-with-string-output-port
      (lambda (p)
        (do ((bv (string->utf8 (string-normalize-nfc dirname)))
             (i 0 (fx+ i 1)))
            ((fx=? i (bytevector-length bv)))
          (let* ((b (bytevector-u8-ref bv i))
                 (c (integer->char b)))
            (cond ((and (char>=? c #\space) (char<? c #\delete)
                        (not (string-index "<>:\"/\\|?*~" c)))
                   (put-char p c))
                  (else
                   (let-values (((n0 n1) (fxdiv-and-mod b 16)))
                     (put-char p #\%)
                     (put-char p (string-ref hex n0))
                     (put-char p (string-ref hex n1)))))))))))

(define (project-source-directory project)
  (match (project-source project)
    (('directory dir)
     ;; For sources in directories, refer directly to that directory.
     dir)
    (else
     ;; Otherwise a local src directory must be created.
     (path-join (sources-directory) (project-sanitized-name project)))))

(define (binaries-directory)
  (path-join (akku-directory) "bin"))

(define (libraries-directory)
  (path-join (akku-directory) "lib"))

(define (notices-directory project)
  (path-join (path-join (akku-directory) "notices")
             (project-sanitized-name project)))

(define (file-list-filename)
  (path-join (akku-directory) "list"))

(define-record-type project
  (fields name packages source
          installer                     ;for future extensions
          ;; one of these:
          tag revision)
  (sealed #t)
  (nongenerative))

(define (parse-project spec)
  (let ((name (car (assq-ref spec 'name)))
        (tag (cond ((assq 'tag spec) => cadr) (else #f)))
        (revision (car (assq-ref spec 'revision)))
        (location (assq 'location spec)))
    (assert (not (char=? (string-ref name 0) #\()))
    (match location
      (('location ('directory _))
       #f)
      (else #f))
    (make-project name
                  (cond ((assq 'install spec) => cdr) (else #f))
                  (car (assq-ref spec 'location))
                  (assq-ref spec 'installer '((r6rs)))
                  tag revision)))

;; Parse a lockfile, returning a list of project records.
(define (read-lockfile lockfile-location)
  (call-with-input-file lockfile-location
    (lambda (p)
      (unless (equal? (read p) '(import (akku format lockfile)))
        (error 'read-lockfile "Invalid lockfile (wrong import)" lockfile-location))
      ;; TODO: More sanity checking. The names need to be
      ;; case-insensitively unique.
      (let lp ((project* '()))
        (match (read p)
          ((? eof-object?)
           project*)
          (('projects . prj*)
           (lp (append (map parse-project prj*) project*)))
          (_ (lp project*)))))))

;; Fetch a project so that it's available locally.
(define (fetch-project project)
  (let ((srcdir (project-source-directory project)))
    ;; Get the code.
    (print ";; INFO: Fetching " (project-name project) " ...")
    (match (project-source project)
      (('git repository)
       (cond ((file-directory? srcdir)
              (git-remote-set-url srcdir "origin" repository))
             (else
              (if (project-tag project)
                  (git-shallow-clone srcdir repository)
                  (git-clone srcdir repository))))
       (let ((current-revision (git-rev-parse srcdir "HEAD")))
         (cond ((equal? current-revision (project-revision project)))
               ((project-tag project)
                (git-fetch-tag srcdir (project-tag project))
                (git-checkout-tag srcdir (project-tag project)))
               ((project-revision project)
                (git-fetch srcdir)
                (git-checkout-commit srcdir (project-revision project)))
               (else
                (error 'install "No revision" project))))
       (let ((current-revision (git-rev-parse srcdir "HEAD")))
         (print ";; INFO: Fetched revision " current-revision)
         (unless (or (not (project-revision project))
                     (equal? current-revision (project-revision project)))
           (error 'install "Tag does not match revision" (project-tag project)
                  (project-revision project)))))
      (('directory dir)
       (unless (file-directory? dir)
         (error 'install "Directory does not exist" project)))
      (else
       (error 'install "Unsupported project source: upgrade Akku.scm"
              (project-source project) (project-name project))))))

(define (check-filename filename windows?)
  ;; Protection against path traversal attacks and other types of
  ;; names that would break on some systems. For one particularly
  ;; difficult system, see:
  ;; https://msdn.microsoft.com/en-us/library/windows/desktop/aa365247(v=vs.85).aspx
  ;; TODO: Check for unicode names that break under Windows.
  (define reserved-names
    '("CON" "PRN" "AUX" "NUL" "COM1" "COM2" "COM3" "COM4" "COM5" "COM6" "COM7" "COM8"
      "COM9" "LPT1" "LPT2" "LPT3" "LPT4" "LPT5" "LPT6" "LPT7" "LPT8" "LPT9"))
  (define reserved-chars
    "<>:\"/\\|?*")
  (for-each
   (lambda (component)
     (cond ((string=? component "") ;// does nothing
            (error 'check-filename "Empty path component" filename))
           ((member component '("." ".."))
            (error 'check-filename "Path component is . or .." filename))
           ((string-index component #\nul)
            (error 'check-filename "Path component contains NUL" filename))
           ((and windows?
                 (exists (lambda (part)
                           (exists (lambda (reserved) (string-ci=? part reserved))
                                   reserved-names))
                         (string-split component #\.)))
            (error 'check-filename "Path contains component reserved on MS Windows"
                   filename))
           ((and windows?
                 (exists (lambda (c) (string-index reserved-chars c))
                         (string->list component)))
            (error 'check-filename "Path contains character reserved on MS Windows"
                   filename))
           ((and windows?
                 (exists (lambda (c) (<= 1 (char->integer c) 31))
                         (string->list component)))
            (error 'check-filename "Path contains character disallowed on MS Windows"
                   filename))))
   (string-split filename #\/)))

;; Makes all known variants of the path for the library.
(define (make-r6rs-library-filenames name implementation)
  (delete-duplicates
   (filter-map
    (lambda (library-name->file-name)
      (guard (exn
              ((serious-condition? exn)
               (when (and (message-condition? exn)
                          (irritants-condition? exn))
                 (print "ERROR: " (condition-message exn) ": "
                        (condition-irritants exn)))
               #f))
        (let* ((filename (library-name->file-name name))
               (filename (substring filename 1 (string-length filename)))
               (filename (if implementation
                             (string-append filename "."
                                            (symbol->string implementation))
                             filename))
               (filename (string-append filename ".sls")))
          (check-filename filename (support-windows?))
          (split-path filename))))
    (library-name->file-name-variants implementation))
   equal?))

;; Copies a single R6RS library form from one file to another.
(define (copy-r6rs-library target-directory target-filename source-pathname form-index)
  (let ((target-pathname (path-join target-directory target-filename)))
    (print ";; DEBUG: Copying R6RS library " source-pathname (if (zero? form-index) "" " ")
           (if (zero? form-index) "" (list 'form form-index))
           " to " target-pathname)
    (check-filename target-pathname (support-windows?))
    (call-with-port (open-input-file source-pathname)
      (lambda (inp)
        (read-shebang inp)
        (let* ((start (port-position inp))
               (f0 (read inp))
               (f1 (read inp))
               (target-pathname (path-join target-directory target-filename)))
          (mkdir/recursive target-directory)
          (when (file-symbolic-link? target-pathname)
            (delete-file target-pathname))
          (call-with-port (open-file-output-port target-pathname
                                                 (file-options no-fail)
                                                 (buffer-mode block)
                                                 (native-transcoder))
            (lambda (outp)
              ;; TODO: Only add #!r6rs if it's not in the original source.
              (display "#!r6rs " outp) ;XXX: required for Racket
              (cond ((and (= form-index 0) (eof-object? f1))
                     ;; The source has a single form, so it's safe to
                     ;; copy the text. TODO: Hardlink in this case. If
                     ;; hardlinks are used then file-symbolic-links?
                     ;; needs to be file-exists/no-follow? everywhere.
                     (set-port-position! inp start)
                     (pipe-ports outp inp))
                    (else
                     ;; TODO: Include comments and original formatting
                     ;; for this case. This will be a problem for
                     ;; license compliance if form 0 is not used in a
                     ;; compiled program, but form 1 is.
                     (print ";; DEBUG: Reformatting " target-pathname)
                     (let ((form (case form-index
                                   ((0) f0)
                                   ((1) f1)
                                   (else
                                    (let lp ((form-index (- form-index 2)))
                                      (let ((form (read inp)))
                                        (if (zero? form-index)
                                            form
                                            (lp (- form-index 1)))))))))
                       (display ";; Copyright notices may be found in " outp)
                       (write source-pathname outp)
                       (display "\n;; This file was copied by Akku.scm\n" outp)
                       (pretty-print form outp)))))))))
    target-pathname))

;; Copies an R6RS program from one file to another.
(define (copy-r6rs-program target-directory target-filename source-pathname form-index)
  (let ((target-pathname (path-join target-directory target-filename)))
    (print ";; DEBUG: Copying R6RS program " source-pathname (if (zero? form-index) "" " ")
           (if (zero? form-index) "" (list 'form form-index))
           " to " target-pathname)
    (check-filename target-pathname (support-windows?))
    (call-with-port (open-input-file source-pathname)
      (lambda (inp)
        (read-shebang inp)
        (mkdir/recursive target-directory)
        (when (file-symbolic-link? target-pathname)
          (delete-file target-pathname))
        (call-with-port (open-file-output-port target-pathname
                                               (file-options no-fail)
                                               (buffer-mode block)
                                               (native-transcoder))
          (lambda (outp)
            ;; Skip forms before the program start.
            (let lp ((form-index form-index))
              (unless (zero? form-index)
                (read inp)
                (lp (- form-index 1))))
            (display "#!/usr/bin/env scheme-script\n" outp)
            (display ";; Copied by Akku from " outp)
            (write source-pathname outp)
            (display " !#" outp) ;XXX: required for GNU Guile
            (display " #!r6rs " outp) ;XXX: required for Racket
            (pipe-ports outp inp)))
        (chmod target-pathname #o755)))
    target-pathname))

;; Copy a regular file.
(define (copy-file target-directory target-filename source-pathname)
  (let ((target-pathname (path-join target-directory target-filename)))
    (print ";; DEBUG: Copying file " source-pathname " to " target-pathname)
    (check-filename target-pathname (support-windows?))
    (call-with-port (open-file-input-port source-pathname)
      (lambda (inp)
        (mkdir/recursive target-directory)
        (when (file-symbolic-link? target-pathname)
          (delete-file target-pathname))
        (call-with-port (open-file-output-port target-pathname
                                               (file-options no-fail))
          (lambda (outp)
            (pipe-ports outp inp)))))
    target-pathname))

(define (symlink-file target-directory target-filename source-pathname)
  (cond
    ((support-windows?)
     (copy-file target-directory target-filename source-pathname))
    (else
     (let ((target-pathname (path-join target-directory target-filename)))
       (print ";; DEBUG: Symlinking file " source-pathname " to " target-pathname)
       (check-filename target-pathname (support-windows?))
       (mkdir/recursive target-directory)
       (when (file-exists/no-follow? target-pathname)
         (delete-file target-pathname))
       (symlink source-pathname target-pathname)
       target-pathname))))

;; Install an artifact.
(define (install-artifact project artifact srcdir always-symlink?)
  (cond
    ((r6rs-library? artifact)
     (let ((library-locations
            (make-r6rs-library-filenames (r6rs-library-name artifact)
                                         (artifact-implementation artifact))))
       (cond
         ((null? library-locations)
          (print ";; WARNING: could not construct a filename for "
                 (r6rs-library-name artifact))
          '())
         (else
          ;; Create each of the locations for the library. The first
          ;; is a regular file and the rest are symlinks.
          (let ((target (car library-locations))
                (aliases (cdr library-locations)))
            (let ((target-pathname
                   (cond ((and always-symlink? (zero? (artifact-form-index artifact))
                               (artifact-last-form? artifact))
                          ;; It's safe to symlink iff the file has a
                          ;; single form.
                          (symlink-file (path-join (libraries-directory) (car target))
                                        (cdr target)
                                        (path-join srcdir (artifact-path artifact))))
                         (else
                          (when always-symlink?
                            (print ";; WARNING: refusing to symlink multi-form file "
                                   (artifact-path artifact)))
                          (copy-r6rs-library (path-join (libraries-directory) (car target))
                                             (cdr target)
                                             (path-join srcdir (artifact-path artifact))
                                             (artifact-form-index artifact))))))
              (cons target-pathname
                    (map-in-order
                     (lambda (alias)
                       (symlink-file (path-join (libraries-directory) (car alias))
                                     (cdr alias)
                                     target-pathname))
                     aliases))))))))
    ((r6rs-program? artifact)
     (if (or (artifact-internal? artifact) (not (artifact-for-bin? artifact)))
         '()
         (let ((target (split-path (artifact-path artifact))))
           (if always-symlink?
               (list (symlink-file (binaries-directory)
                                   (cdr target)
                                   (path-join srcdir (artifact-path artifact))))
               (list (copy-r6rs-program (binaries-directory)
                                        (cdr target)
                                        (path-join srcdir (artifact-path artifact))
                                        (artifact-form-index artifact)))))))
    ((legal-notice-file? artifact)
     (list (copy-file (path-join (notices-directory project) (artifact-directory artifact))
                      (artifact-filename artifact)
                      (path-join srcdir (artifact-path artifact)))))
    (else '())))

;; Installs an asset, which can be any regular file.
(define (install-asset asset always-symlink?)
  (let ((target (split-path (include-reference-path asset))))
    (list ((if always-symlink? symlink-file copy-file)
           (path-join (libraries-directory) (car target))
           (cdr target)
           (include-reference-realpath asset)))))

;; Install a project and return a alist of artifact/asset => filename.
(define (install-project project always-symlink?)
  (let ((srcdir (project-source-directory project)))
    ;; Copy libraries, programs and assets to the file system. These
    ;; operations are ordered.
    (print ";; INFO: Installing " (project-name project) " ...")
    (cond
      ((equal? (project-installer project) '((r6rs)))
       (let* ((artifact* (filter (lambda (artifact)
                                   (not (artifact-for-test? artifact)))
                                 (find-artifacts srcdir #f)))
              (asset* (append-map artifact-assets artifact*))) ;XXX: may have duplicates
         (let ((artifact-filename*
                (map-in-order (lambda (artifact)
                                (map (lambda (fn) (cons artifact fn))
                                     (install-artifact project artifact srcdir always-symlink?)))
                              artifact*))
               (asset-filename*
                (map-in-order (lambda (asset)
                                (map (lambda (fn) (cons asset fn))
                                     (install-asset asset always-symlink?)))
                              asset*)))
           (append (apply append artifact-filename*) (apply append asset-filename*)))))
      (else
       (print ";; ERROR: Installation of " (project-name project) " requires a newer Akku.scm")
       (print ";; ERROR: No support for the installer " (map car (project-installer project)))
       '()))))

;; Installs an activation script, like Python's virtualenv.
(define (install-activate-script)
  ;; TODO: Setup routines for more Schemes, perhaps take the wrappers
  ;; from scheme-ci. Larceny is missing.
  (let ((filename (path-join (binaries-directory) "activate")))
    (print ";; INFO: Installing " filename)
    (mkdir/recursive (binaries-directory))
    (call-with-port (open-file-output-port filename
                                           (file-options no-fail)
                                           (buffer-mode block)
                                           (native-transcoder))
      (lambda (p)
        (display "# Load this with \"source .akku/bin/activate\" in bash\n" p)
        (display "export CHEZSCHEMELIBDIRS=\"$PWD/.akku/lib\"\n" p)
        (display "unset CHEZSCHEMELIBEXTS\n" p)
        (display "export GUILE_LOAD_PATH=\"$PWD/.akku/lib\"\n" p)
        (display "export IKARUS_LIBRARY_PATH=\"$PWD/.akku/lib\"\n" p)
        (display "export MOSH_LOADPATH=\"$PWD/.akku/lib\"\n" p)
        (display "export PLTCOLLECTS=\":$PWD/.akku/lib\"\n" p)
        (display "export SAGITTARIUS_LOADPATH=\"$PWD/.akku/lib\"\n" p)
        (display "export VICARE_SOURCE_PATH=\"$PWD/.akku/lib\"\n" p)
        (display "export YPSILON_SITELIB=\"$PWD/.akku/lib\"\n" p)
        (display "export PATH=$PWD/.akku/bin:$PATH\n" p)))))

(define (install-file-list installed-files)
  (define printed-files (make-hashtable string-hash string=?))
  (define (installed-type a)
    (cond ((r6rs-library? a) 'r6rs-library)
          ((r6rs-program? a) 'r6rs-program)
          ((module? a) 'module)
          ((legal-notice-file? a) 'legal-notice-file)
          ((include-reference? a) 'included-file)
          ((generic-file? a) 'generic-file)
          ((artifact? a) 'artifact)
          (else 'unknown)))
  (let ((filename (file-list-filename)))
    (print ";; INFO: Writing " filename)
    (mkdir/recursive (akku-directory))
    (call-with-port (open-file-output-port filename
                                           (file-options no-fail)
                                           (buffer-mode block)
                                           (native-transcoder))
      (lambda (p)
        (for-each
         (match-lambda
          (#(project filename*)
           (for-each
            (match-lambda
             ((artifact . filename)
              (cond ((hashtable-ref printed-files filename #f)
                     => (match-lambda
                         ((other-project . other-artifact)
                          (print ";; INFO: File " filename  " in "
                                 (project-name other-project)
                                 " shadows that from " (project-name project)))))
                    (else
                     (hashtable-set! printed-files filename (cons project artifact))
                     (display filename p)
                     (display #\tab p)
                     (display (if (equal? (project-name project) "")
                                  "-"
                                  (project-name project))
                              p)
                     (display #\tab p)
                     (display (installed-type artifact) p)
                     (display #\tab p)
                     (newline p)))))
            (reverse filename*))))
         (reverse installed-files))))))

(define (install lockfile-location)
  (let ((project-list (read-lockfile lockfile-location))
        (current-project (make-project "" #f '(directory ".") '((r6rs)) #f #f)))
    (mkdir/recursive (akku-directory))
    (let ((gitignore (path-join (akku-directory) ".gitignore")))
      (unless (file-exists? gitignore)
        (call-with-output-file gitignore
          (lambda (p)
            (display (sources-directory*) p)))))
    (for-each fetch-project project-list)
    (let* ((installed-files
           (map-in-order (lambda (project)
                           (vector project (install-project project #f)))
                         project-list))
           (installed-files
            (append installed-files
                    (list (vector current-project
                                  (install-project current-project 'symlink))))))
      (install-file-list installed-files))
    (install-activate-script))))
