;;; refs.el --- find callers of elisp functions or macros

;; Copyright (C) 2016  

;; Author: Wilfred Hughes <me@wilfred.me.uk>
;; Version: 0.1
;; Keywords: lisp
;; Package-Requires: ((dash "2.12.0") (f "0.18.2") (list-utils "0.4.4") (loop "2.1") (shut-up "0.3.2"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A package for finding callers of elisp functions or macros. Really
;; useful for finding examples.

;;; Code:

(require 'list-utils)
(require 'dash)
(require 'f)
(require 'loop)
(require 'shut-up)
(eval-when-compile (require 'cl-lib))

(defun refs--format-int (integer)
  "Format INTEGER as a string, with , separating thousands."
  (let* ((number (abs integer))
         (parts nil))
    (while (> number 999)
      (push (format "%03d" (mod number 1000))
            parts)
      (setq number (/ number 1000)))
    (push (format "%d" number) parts)
    (concat
     (if (< integer 0) "-" "")
     (s-join "," parts))))

(defsubst refs--start-pos (end-pos)
  "Find the start position of form ending at END-FORM
in the current buffer."
  (scan-sexps end-pos -1))

(defun refs--sexp-positions (buffer start-pos end-pos)
  "Return a list of start and end positions of all the sexps
between START-POS and END-POS (excluding ends) in BUFFER.

Not recursive, so we don't consider subelements of nested sexps."
  (let ((positions nil)
        (current-pos (1+ start-pos)))
    (with-current-buffer buffer
      (condition-case _err
          ;; Loop until we can't read any more.
          (loop-while t
            (let* ((sexp-end-pos (let ((parse-sexp-ignore-comments t))
                                   (scan-sexps current-pos 1)))
                   (sexp-start-pos (refs--start-pos sexp-end-pos)))
              (if (< sexp-end-pos end-pos)
                  ;; This sexp is inside the range requested.
                  (progn
                    (push (list sexp-start-pos sexp-end-pos) positions)
                    (setq current-pos sexp-end-pos))
                ;; Otherwise, we've reached end the of range.
                (loop-break))))
        ;; Terminate when we see "Containing expression ends prematurely"
        (scan-error (nreverse positions))))))

(defun refs--read-buffer-form ()
  "Read a form from the current buffer, starting at point.
Returns a list:
\(form form-start-pos form-end-pos symbol-positions read-start-pos)

SYMBOL-POSITIONS are 0-indexed, relative to READ-START-POS."
  (let* ((read-with-symbol-positions t)
         (read-start-pos (point))
         (form (read (current-buffer)))
         (end-pos (point))
         (start-pos (refs--start-pos end-pos)))
    (list form start-pos end-pos read-symbol-positions-list read-start-pos)))

(defvar refs--path nil
  "A buffer-local variable used by `refs--contents-buffer'.
Internal implementation detail.")

(defun refs--read-all-buffer-forms (buffer)
  "Read all the forms in BUFFER, along with their positions."
  (with-current-buffer buffer
    (goto-char (point-min))
    (let ((forms nil))
      (condition-case err
          (while t
            (push (refs--read-buffer-form) forms))
        (error
         (if (or (equal (car err) 'end-of-file)
                 ;; TODO: this shouldn't occur in valid elisp files,
                 ;; but it's happening in helm-utils.el.
                 (equal (car err) 'scan-error))
             ;; Reached end of file, we're done.
             (nreverse forms)
           ;; Some unexpected error, propagate.
           (error "Unexpected error whilst reading %s position %s: %s"
                  (f-abbrev refs--path) (point) err)))))))

(defun refs--walk (buffer form start-pos end-pos symbol match-p &optional path)
  "Walk FORM, a nested list, and return a list of sublists (with
their positions) where MATCH-P returns t. FORM is traversed
depth-first, left-to-right.

MATCH-P is called with three arguments:
\(SYMBOL CURRENT-FORM PATH).

PATH is the first element of all the enclosing forms of
CURRENT-FORM, innermost first, along with the index of the
current form.

For example if we are looking at h in (e f (g h)), PATH takes the
value ((g . 1) (e . 2)).

START-POS and END-POS should be the position of FORM within BUFFER."
  (if (funcall match-p symbol form path)
      ;; If this form matches, just return it, along with the position.
      (list (list form start-pos end-pos))
    ;; Otherwise, recurse on the subforms.
    (let ((matches nil)
          ;; Find the positions of the subforms.
          (subforms-positions (refs--sexp-positions buffer start-pos end-pos)))
      ;; For each subform, if it's a list, recurse.
      (--each (-zip form subforms-positions)
        (-let [(subform subform-start subform-end) it]
          ;; TODO: add tests for improper lists
          (when (or
                 (and (consp subform) (not (list-utils-improper-p subform)))
                 (and (symbolp subform) (eq subform symbol)))
            (-when-let (subform-matches
                        (refs--walk
                         buffer subform
                         subform-start subform-end
                         symbol match-p
                         (cons (cons (car-safe form) it-index) path)))
              (push subform-matches matches)))))

      ;; Concat the results from all the subforms.
      (apply #'append (nreverse matches)))))

;; TODO: Handle sharp-quoted function references.
(defun refs--function-p (symbol form path)
  "Return t if FORM looks like a function call to SYMBOL."
  (cond
   ((not (consp form))
    nil)
   ;; Ignore (defun _ (SYMBOL ...) ...)
   ((or (equal (car path) '(defun . 2))
        (equal (car path) '(defsubst . 2))
        (equal (car path) '(defmacro . 2)))
    nil)
   ;; Ignore (let (SYMBOL ...) ...)
   ;; and (let* (SYMBOL ...) ...)
   ((or
     (equal (car path) '(let . 1))
     (equal (car path) '(let* . 1)))
    nil)
   ;; Ignore (let ((SYMBOL ...)) ...)
   ((or
     (equal (cl-second path) '(let . 1))
     (equal (cl-second path) '(let* . 1)))
    nil)
   ;; (SYMBOL ...)
   ((eq (car form) symbol)
    t)
   ;; (funcall 'SYMBOL ...)
   ((and (eq (car form) 'funcall)
         (equal `',symbol (cl-second form)))
    t)
   ;; (apply 'SYMBOL ...)
   ((and (eq (car form) 'apply)
         (equal `',symbol (cl-second form)))
    t)))

(defun refs--macro-p (symbol form path)
  "Return t if FORM looks like a macro call to SYMBOL."
  (cond
   ((not (consp form))
    nil)
   ;; Ignore (defun _ (SYMBOL ...) ...)
   ((or (equal (car path) '(defun . 2))
        (equal (car path) '(defsubst . 2))
        (equal (car path) '(defmacro . 2)))
    nil)
   ;; Ignore (let (SYMBOL ...) ...)
   ;; and (let* (SYMBOL ...) ...)
   ((or
     (equal (car path) '(let . 1))
     (equal (car path) '(let* . 1)))
    nil)
   ;; Ignore (let ((SYMBOL ...)) ...)
   ((or
     (equal (cl-second path) '(let . 1))
     (equal (cl-second path) '(let* . 1)))
    nil)
   ;; (SYMBOL ...)
   ((eq (car form) symbol)
    t)))

;; Looking for a special form is exactly the same as looking for a
;; macro.
(defalias 'refs--special-p 'refs--macro-p)

(defun refs--variable-p (symbol form path)
  "Return t if this looks like a variable reference to SYMBOL."
  (cond
   ((consp form)
    nil)
   ;; (let (SYMBOL ...) ...) is a variable, not a function call.
   ((or
     (equal (cl-second path) '(let . 1))
     (equal (cl-second path) '(let* . 1)))
    t)
   ;; (let ((SYMBOL ...)) ...) is also a variable.
   ((or
     (equal (cl-third path) '(let . 1))
     (equal (cl-third path) '(let* . 1)))
    t)
   ;; Ignore (SYMBOL ...) otherwise, we assume it's a function/macro
   ;; call.
   ((equal (car path) (cons symbol 0))
    nil)
   ((eq form symbol)
    t)))

;; TODO: benchmark building a list with `push' rather than using
;; mapcat.
(defun refs--read-and-find (buffer symbol match-p)
  "Read all the forms in BUFFER, and return a list of all forms that
contain SYMBOL where MATCH-P returns t.

For every matching form found, we return the form itself along
with its start and end position."
  (-non-nil
   (--mapcat
    (-let [(form start-pos end-pos symbol-positions read-start-pos) it]
      ;; Optimisation: don't bother walking a form if contains no
      ;; references to the symbol we're looking for.
      (when (assq symbol symbol-positions)
        (refs--walk buffer form start-pos end-pos symbol match-p)))
    (refs--read-all-buffer-forms buffer))))

(defun refs--read-and-find-symbol (buffer symbol)
  "Read all the forms in BUFFER, and return a list of all
positions of SYMBOL."
  (-non-nil
   (--mapcat
    (-let [(_ _ _ symbol-positions read-start-pos) it]
      (--map
       (-let [(sym . offset) it]
         (when (eq sym symbol)
           (-let* ((start-pos (+ read-start-pos offset))
                   (end-pos (+ start-pos (length (symbol-name sym)))))
             (list sym start-pos end-pos))))
       symbol-positions))

    (refs--read-all-buffer-forms buffer))))

(defun refs--filter-obarray (pred)
  "Return a list of all the items in `obarray' where PRED returns t."
  (let (symbols)
    (mapatoms (lambda (symbol)
                (when (and (funcall pred symbol)
                           (not (equal (symbol-name symbol) "")))
                  (push symbol symbols))))
    symbols))

(defun refs--macros ()
  "Return a list of all symbols that are macros."
  (let (symbols)
    (mapatoms (lambda (symbol)
                (when (macrop symbol)
                  (push symbol symbols))))
    symbols))

(defun refs--loaded-files ()
  "Return a list of all files that have been loaded in Emacs.
Where the file was a .elc, return the path to the .el file instead."
  (let ((elc-paths (mapcar #'-first-item load-history)))
    (-non-nil
     (--map
      (let ((el-name (format "%s.el" (f-no-ext it)))
            (el-gz-name (format "%s.el.gz" (f-no-ext it))))
        (cond ((f-exists? el-name) el-name)
              ((f-exists? el-gz-name) el-gz-name)
              ;; Ignore files where we can't find a .el file.
              (t nil)))
      elc-paths))))

(defun refs--contents-buffer (path)
  "Read PATH into a disposable buffer, and return it.
Works around the fact that Emacs won't allow multiple buffers
visiting the same file."
  (let ((fresh-buffer (generate-new-buffer (format "refs-%s" path))))
    (with-current-buffer fresh-buffer
      (setq-local refs--path path)
      (shut-up (insert-file-contents path))
      ;; We don't enable emacs-lisp-mode because it slows down this
      ;; function significantly. We just need the syntax table for
      ;; scan-sexps to do the right thing with comments.
      (set-syntax-table emacs-lisp-mode-syntax-table))
    fresh-buffer))

(defvar refs--highlighting-buffer
  nil
  "A temporary buffer used for highlighting.
Since `refs--syntax-highlight' is a hot function, we
don't want to create lots of temporary buffers.")

(defun refs--syntax-highlight (str)
  "Apply font-lock properties to a string STR of Emacs lisp code."
  ;; Ensure we have a highlighting buffer to work with.
  (unless refs--highlighting-buffer
    (setq refs--highlighting-buffer
          (generate-new-buffer " *refs-highlighting*"))
    (with-current-buffer refs--highlighting-buffer
      (delay-mode-hooks (emacs-lisp-mode))))
  
  (with-current-buffer refs--highlighting-buffer
    (erase-buffer)
    (insert str)
    (if (fboundp 'font-lock-ensure)
        (font-lock-ensure)
      (with-no-warnings
        (font-lock-fontify-buffer)))
    (buffer-string)))

(defun refs--replace-tabs (string)
  "Replace tabs in STRING with spaces."
  ;; This is important for unindenting, as we may unindent by less
  ;; than one whole tab.
  (s-replace "\t" (s-repeat tab-width " ") string))

(defun refs--lines (string)
  "Return a list of all the lines in STRING.
'a\nb' -> ('a\n' 'b')"
  (let ((lines nil))
    (while (> (length string) 0)
      (let ((index (s-index-of "\n" string)))
        (if index
            (progn
              (push (substring string 0 (1+ index)) lines)
              (setq string (substring string (1+ index))))
          (push string lines)
          (setq string ""))))
    (nreverse lines)))

(defun refs--map-lines (string fn)
  "Execute FN for each line in string, and join the result together."
  (let ((result nil))
    (dolist (line (refs--lines string))
      (push (funcall fn line) result))
    (apply #'concat (nreverse result))))

(defun refs--unindent-rigidly (string)
  "Given an indented STRING, unindent rigidly until
at least one line has no indent.

STRING should have a 'refs-start-pos property. The returned
string will have this property updated to reflect the unindent."
  (let* ((lines (s-lines string))
         ;; Get the leading whitespace for each line.
         (indents (--map (car (s-match (rx bos (+ whitespace)) it))
                         lines))
         (min-indent (-min (--map (length it) indents))))
    (propertize
     (refs--map-lines
      string
      (lambda (line) (substring line min-indent)))
     'refs-unindented min-indent)))

(defun refs--containing-lines (buffer start-pos end-pos)
  "Return a string, all the lines in BUFFER that are between
START-POS and END-POS (inclusive).

For the characters that are between START-POS and END-POS,
propertize them."
  (let (expanded-start-pos expanded-end-pos)
    (with-current-buffer buffer
      ;; Expand START-POS and END-POS to line boundaries.
      (goto-char start-pos)
      (beginning-of-line)
      (setq expanded-start-pos (point))
      (goto-char end-pos)
      (end-of-line)
      (setq expanded-end-pos (point))

      ;; Extract the rest of the line before and after the section we're interested in.
      (let* ((before-match (buffer-substring expanded-start-pos start-pos))
             (after-match (buffer-substring end-pos expanded-end-pos))
             ;; Concat the extra text with the actual match, ensuring we
             ;; highlight the match as code, but highlight the rest as as
             ;; comments.
             (text (concat
                    (propertize before-match
                                'face 'font-lock-comment-face)
                    (refs--syntax-highlight (buffer-substring start-pos end-pos))
                    (propertize after-match
                                'face 'font-lock-comment-face))))
        (-> text
            (refs--replace-tabs)
            (refs--unindent-rigidly)
            (propertize 'refs-start-pos expanded-start-pos
                        'refs-path refs--path))))))

(defun refs--find-file (button)
  "Open the file referenced by BUTTON."
  (find-file (button-get button 'path))
  (goto-char (point-min)))

(define-button-type 'refs-path-button
  'action 'refs--find-file
  'follow-link t
  'help-echo "Open file")

(defun refs--path-button (path)
  "Return a button that navigates to PATH."
  (with-temp-buffer
    (insert-text-button
     (f-abbrev path)
     :type 'refs-path-button
     'path path)
    (buffer-string)))

(defun refs--format-count (symbol ref-count file-count)
  (format "Found %s references to %s%s."
          (refs--format-int ref-count)
          symbol
          (if (zerop ref-count) ""
            (format " in %s files"
                    (refs--format-int file-count)))))

;; TODO: if we have multiple matches on one line, we repeatedly show
;; that line. That's slighly confusing.
(defun refs--show-results (symbol description results)
  "Given a list where each element takes the form \(forms . buffer\),
render a friendly results buffer."
  (let ((buf (get-buffer-create (format "*refs: %s*" symbol))))
    (switch-to-buffer buf)
    (setq buffer-read-only nil)
    (erase-buffer)
    (insert
     (refs--format-count
      description
      (-sum (--map (length (car it)) results))
      (length results))
     "\n\n")
    (--each results
      (-let* (((forms . buf) it)
              (path (with-current-buffer buf refs--path)))
        (insert
         (propertize "File: " 'face 'bold)
         (refs--path-button path) "\n")
        (--each forms
          (-let [(_ start-pos end-pos) it]
            (insert (format "%s\n" (refs--containing-lines buf start-pos end-pos)))))
        (insert "\n")))
    (goto-char (point-min))
    (refs-mode)
    (setq buffer-read-only t)))

(defun refs--search (symbol description match-fn)
  "Search for references to SYMBOL in all loaded files, by calling MATCH-FN on each buffer.
Display the results in a hyperlinked buffer.

MATCH-FN should return a list where each element takes the form:
\(form start-pos end-pos)."
  (let* (;; Our benchmark suggests we spend a lot of time in GC, and
         ;; performance improves if we GC less frequently.
         (gc-cons-percentage 0.8)
         (loaded-paths (refs--loaded-files))
         (total-paths (length loaded-paths))
         (loaded-src-bufs (mapcar #'refs--contents-buffer loaded-paths)))
    ;; Use unwind-protect to ensure we always cleanup temporary
    ;; buffers, even if the user hits C-g.
    (unwind-protect
        (let ((searched 0)
              (forms-and-bufs nil))
          (dolist (buf loaded-src-bufs)
            (let* ((matching-forms (funcall match-fn buf)))
              ;; If there were any matches in this buffer, push the
              ;; matches along with the buffer into our results
              ;; list.
              (when matching-forms
                (push (cons matching-forms buf) forms-and-bufs))
              ;; Give feedback to the user on our progress, because
              ;; searching takes several seconds.
              (when (zerop (mod searched 10))
                (message "Searched %s/%s files" searched total-paths))
              (cl-incf searched)))
          (message "Searched %s/%s files" total-paths total-paths)
          (refs--show-results symbol description forms-and-bufs))
      ;; Clean up temporary buffers.
      (--each loaded-src-bufs (kill-buffer it)))))

(defun refs-function (symbol)
  "Display all the references to SYMBOL, a function."
  (interactive
   ;; TODO: default to function at point.
   (list (read (completing-read
                "Function: "
                (refs--filter-obarray #'functionp)))))
  (refs--search symbol
                (format "function %s"
                        (propertize
                         (symbol-name symbol)
                         'face 'font-lock-function-name-face))
                (lambda (buf)
                  (refs--read-and-find buf symbol #'refs--function-p))))

(defun refs-macro (symbol)
  "Display all the references to SYMBOL, a macro."
  (interactive
   (list (read (completing-read
                "Macro: "
                (refs--filter-obarray #'macrop)))))
  (refs--search symbol
                (format "macro %s"
                        (propertize
                         (symbol-name symbol)
                         'face 'font-lock-function-name-face))
                (lambda (buf)
                  (refs--read-and-find buf symbol #'refs--macro-p))))

(defun refs-special (symbol)
  "Display all the references to SYMBOL, a special form."
  (interactive
   (list (read (completing-read
                "Macro: "
                (refs--filter-obarray #'special-form-p)))))
  (refs--search symbol
                (format "special form %s"
                        (propertize
                         (symbol-name symbol)
                         'face 'font-lock-keyword-face))
                (lambda (buf)
                  (refs--read-and-find buf symbol #'refs--special-p))))

;; TODO: these docstring are poor and don't say where we search.

(defun refs-variable (symbol)
  "Display all the references to SYMBOL, a variable."
  (interactive
   (list (read
          (completing-read
           "Variable: "
           (refs--filter-obarray
            ;; This is awkward. We don't want to just offer defvar
            ;; variables, because then we can't such for users who
            ;; have used `let' to bind other symbols. There doesn't
            ;; seem to be good way to only offer variables that have
            ;; been bound at some point.
            (lambda (_) t))))))
  (refs--search symbol
                (format "variable %s"
                        (propertize
                         (symbol-name symbol)
                         'face 'font-lock-variable-name-face))
                (lambda (buf)
                  (refs--read-and-find buf symbol #'refs--variable-p))))

(defun refs-symbol (symbol)
  "Display all the references to SYMBOL."
  (interactive
   (list (read (completing-read
                "Symbol: "
                (refs--filter-obarray (lambda (_) t))))))
  (refs--search symbol
                (format "symbol %s"
                        (symbol-name symbol))
                (lambda (buf)
                  (refs--read-and-find-symbol buf symbol))))

(define-derived-mode refs-mode special-mode "Refs"
  "Major mode for results buffers when using refs commands.")

(defun refs-visit-match ()
  "Go to the search result at point."
  (interactive)
  (let* ((path (get-text-property (point) 'refs-path))
         (pos (get-text-property (point) 'refs-start-pos))
         (unindent (get-text-property (point) 'refs-unindented))
         (column-offset (current-column))
         (target-offset (+ column-offset unindent))
         (line-offset -1))
    (when (null path)
      (user-error "No match here"))

    ;; If point is not on the first line of the match, work out how
    ;; far away the first line is.
    (save-excursion
      (while (equal pos (get-text-property (point) 'refs-start-pos))
        (forward-line -1)
        (cl-incf line-offset)))

    (find-file path)
    (goto-char pos)
    ;; Move point so we're on the same char in the buffer that we were
    ;; on in the results buffer.
    (forward-line line-offset)
    (beginning-of-line)
    (let ((i 0))
      (while (< i target-offset)
        (if (looking-at "\t")
            (cl-incf i tab-width)
          (cl-incf i))
        (forward-char 1)))))

;; TODO: it would be nice for TAB to navigate to buffers too.
(defun refs-next-match ()
  "Move to the next search result in the Refs buffer."
  (interactive)
  (let* ((start-pos (point))
         (match-pos (get-text-property start-pos 'refs-start-pos))
         current-match-pos)
    (condition-case err
        (progn
          ;; Move forward until point is on the line of the next match.
          (loop-while t
            (setq current-match-pos
                  (get-text-property (point) 'refs-start-pos))
            (when (and current-match-pos
                       (not (equal match-pos current-match-pos)))
              (loop-break))
            (forward-char 1))
          ;; Move forward until we're on the first char of match within that
          ;; line.
          (while (or
                  (looking-at " ")
                  (eq (get-text-property (point) 'face)
                      'font-lock-comment-face))
            (forward-char 1)))
      ;; If we're at the last result, don't move point.
      (end-of-buffer
       (progn
         (goto-char start-pos)
         (signal 'end-of-buffer nil))))))

(define-key refs-mode-map (kbd "n") #'refs-next-match)
(define-key refs-mode-map (kbd "q") #'kill-this-buffer)
(define-key refs-mode-map (kbd "RET") #'refs-visit-match)

(provide 'refs)
;;; refs.el ends here
