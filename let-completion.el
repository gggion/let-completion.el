;;; let-completion.el --- Show let-binding values in Elisp completion -*- lexical-binding: t -*-

;; Author: Gino Cornejo <gggion123@gmail.com>
;; Maintainer: Gino Cornejo <gggion123@gmail.com>
;; URL: https://github.com/gggion/let-completion.el
;; Keywords: lisp, completion

;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `let-completion-mode' makes Emacs Lisp in-buffer completion aware of
;; lexically enclosing binding forms.  Local variables from `let',
;; `let*', `when-let*', `if-let*', `and-let*', `dolist', and `dotimes'
;; are promoted to the top of the candidate list, annotated with their
;; binding values when short enough or a [local] tag otherwise, and
;; shown in full via pretty-printed fontified expressions in
;; corfu-popupinfo or any completion UI that reads `:company-doc-buffer'.
;;
;; Names that the built-in `elisp--local-variables' misses (untrusted
;; buffers, macroexpansion failure) are injected into the completion
;; table directly so they always appear as candidates.  For `if-let'
;; and `if-let*', bindings are suppressed in the else branch where
;; they are not in scope.
;;
;; The package installs a single around-advice on
;; `elisp-completion-at-point' when enabled and removes it when
;; disabled.  Loading the file produces no side effects.
;;
;; Usage:
;;
;;     (add-hook 'emacs-lisp-mode-hook #'let-completion-mode)
;;
;; Customize `let-completion-inline-max-width' to control the maximum
;; printed width for inline value annotations, or set it to nil to
;; always show [local] instead.

;;; Code:

(require 'cl-lib)

;;;; Customization

(defgroup let-completion nil
  "Show let-binding values in Elisp completion."
  :group 'lisp
  :prefix "let-completion-")

(defcustom let-completion-annotation-format " [%s]"
  "The format string for inline annotation.
Receives one string argument: either the printed value or \"local\"."
  :type 'string)

(defcustom let-completion-inline-max-width 5
  "Max printed width for inline value annotation, or nil to disable.
Only binding values whose `prin1-to-string' form fits within this
many characters appear inline next to the candidate.  Longer values
show \" [local]\" instead.  The popupinfo buffer always shows the
full value regardless of this setting.

Also see `let-completion-mode'."
  :type '(choice natnum (const :tag "Disable" nil)))

;;;; Binding Form Registry

(defvar-local let-completion-binding-forms nil
  "Buffer-local alist overriding binding form descriptors.
Each entry is (SYMBOL . SPEC) where SPEC is a plist or function.
Takes priority over symbol properties at lookup time.

Set by major mode hooks for non-Elisp Lisp dialects.")

(defun let-completion-register-binding-form (symbol spec)
  "Register SYMBOL as a binding form with descriptor SPEC.
SPEC is either a plist with keys `:bindings-index', `:binding-shape',
and `:scope', or a function receiving (POS COMPLETION-POS) and
returning an alist of (NAME-STRING . VALUE-OR-NIL).

`:bindings-index' is the 1-based position of the binding sexp
after the head symbol.  `:binding-shape' is one of `list',
`arglist', `single', `error-var'.  `:scope' is one of `body',
`then', `handlers'.

Store SPEC as symbol property `let-completion--binding-form'.
Buffer-local overrides via `let-completion-binding-forms' take
priority at lookup time.

Called at load time for built-in forms.  Third-party macros call
this to opt in."
  (put symbol 'let-completion--binding-form spec))

(defun let-completion--lookup-spec (symbol)
  "Look up binding form descriptor for SYMBOL.
Check buffer-local `let-completion-binding-forms' first, then
symbol property `let-completion--binding-form'.

Return SPEC or nil."
  (or (alist-get symbol let-completion-binding-forms)
      (get symbol 'let-completion--binding-form)))

;;;;; Built-in Registrations

;; let-family: binding list at index 1, list shape.
(let-completion-register-binding-form 'let
  '(:bindings-index 1 :binding-shape list :scope body))
(let-completion-register-binding-form 'let*
  '(:bindings-index 1 :binding-shape list :scope body))
(let-completion-register-binding-form 'when-let*
  '(:bindings-index 1 :binding-shape list :scope body))
(let-completion-register-binding-form 'if-let
  '(:bindings-index 1 :binding-shape list :scope then))
(let-completion-register-binding-form 'if-let*
  '(:bindings-index 1 :binding-shape list :scope then))
(let-completion-register-binding-form 'and-let*
  '(:bindings-index 1 :binding-shape list :scope body))

;; Definitions: arglist at index 2.
(let-completion-register-binding-form 'defun
  '(:bindings-index 2 :binding-shape arglist :scope body))
(let-completion-register-binding-form 'defmacro
  '(:bindings-index 2 :binding-shape arglist :scope body))
(let-completion-register-binding-form 'defsubst
  '(:bindings-index 2 :binding-shape arglist :scope body))
(let-completion-register-binding-form 'cl-defun
  '(:bindings-index 2 :binding-shape arglist :scope body))

;; Lambda: arglist at index 1.
(let-completion-register-binding-form 'lambda
  '(:bindings-index 1 :binding-shape arglist :scope body))

;; Iteration: single binding at index 1.
(let-completion-register-binding-form 'dolist
  '(:bindings-index 1 :binding-shape single :scope body))
(let-completion-register-binding-form 'dotimes
  '(:bindings-index 1 :binding-shape single :scope body))

;; Error handling: bare symbol at index 1, visible in handlers only.
(let-completion-register-binding-form 'condition-case
  '(:bindings-index 1 :binding-shape error-var :scope handlers))

;;;; Scope Checking

(defun let-completion--scope-visible-p
    (form-start bindings-end completion-pos scope)
  "Return non-nil if COMPLETION-POS is in scope per SCOPE.
FORM-START is the opening paren of the entire form.
BINDINGS-END is the position after the binding sexp.

`body'     -- visible in all forms after the binding list.
`then'     -- visible only in the first form after the binding list.
`handlers' -- visible in all forms after the second element
              (the protected expression in `condition-case').

Called by `let-completion--extract-by-spec'."
  (ignore form-start)
  (pcase scope
    ('body
     (> completion-pos bindings-end))
    ('then
     (and (> completion-pos bindings-end)
          (save-excursion
            (goto-char bindings-end)
            (skip-chars-forward " \t\n")
            (let ((then-end (ignore-errors (scan-sexps (point) 1))))
              (or (null then-end)
                  (<= completion-pos then-end))))))
    ('handlers
     (save-excursion
       (goto-char bindings-end)
       (skip-chars-forward " \t\n")
       ;; Skip the protected expression.
       (let ((protected-end (ignore-errors (scan-sexps (point) 1))))
         (and protected-end
              (> completion-pos protected-end)))))
    (_ t)))

;;;; Shape Extractors

(defun let-completion--extract-shape (shape start end completion-pos)
  "Dispatch extraction on SHAPE between START and END.
COMPLETION-POS is used to skip bindings that contain point.
SHAPE is one of `list', `arglist', `single', `error-var'.

Return alist of (NAME-STRING . VALUE-OR-NIL).

Called by `let-completion--extract-by-spec'."
  (pcase shape
    ('list     (let-completion--extract-shape-list start end completion-pos))
    ('arglist  (let-completion--extract-shape-arglist start end completion-pos))
    ('single   (let-completion--extract-shape-single start end completion-pos))
    ('error-var (let-completion--extract-shape-error-var start end completion-pos))))

(defun let-completion--extract-shape-list (start end completion-pos)
  "Extract bindings from a list-shaped form between START and END.
Handle ((VAR EXPR) ...) and bare (VAR ...) entries.
Skip any binding whose span contains COMPLETION-POS.

Return alist of (NAME-STRING . VALUE-OR-NIL).

Used for `let', `let*', `when-let*', `if-let*', `and-let*'."
  (save-excursion
    (goto-char (1+ start))
    (let (result)
      (while (progn (skip-chars-forward " \t\n")
                    (< (point) (1- end)))
        (let ((b-start (point)))
          (condition-case nil
              (let ((b-end (scan-sexps (point) 1)))
                (if (<= b-start completion-pos b-end)
                    (goto-char b-end)
                  (let ((text (buffer-substring-no-properties
                               b-start b-end)))
                    (condition-case nil
                        (let ((sexp (car (read-from-string text))))
                          (cond
                           ((consp sexp)
                            (push (cons (symbol-name (car sexp))
                                        (cadr sexp))
                                  result))
                           ((symbolp sexp)
                            (push (cons (symbol-name sexp) nil) result))))
                      ;; `read' failed — extract name only via scan-sexps.
                      (error
                       (save-excursion
                         (goto-char b-start)
                         (when (eq (char-after) ?\()
                           (forward-char 1))
                         (skip-chars-forward " \t\n")
                         (let ((name-end (ignore-errors
                                           (scan-sexps (point) 1))))
                           (when name-end
                             (push (cons (buffer-substring-no-properties
                                          (point) name-end)
                                         nil)
                                   result)))))))
                  (goto-char b-end)))
            ;; scan-sexps failed — bail out of the loop.
            (error (goto-char end)))))
      result)))

(defun let-completion--extract-shape-arglist (start end completion-pos)
  "Extract parameter names from an arglist between START and END.
Skip lambda-list keywords (&optional, &rest, &key, etc.) and
destructuring sublists.  All values are nil.
Skip any name whose span contains COMPLETION-POS.

Return alist of (NAME-STRING . nil).

Used for `defun', `defmacro', `defsubst', `cl-defun', `lambda'."
  (save-excursion
    (goto-char (1+ start))
    (let (result)
      (while (progn (skip-chars-forward " \t\n")
                    (< (point) (1- end)))
        (let ((sym-start (point)))
          (condition-case nil
              (let ((sym-end (scan-sexps (point) 1)))
                (if (<= sym-start completion-pos sym-end)
                    (goto-char sym-end)
                  (let ((name (buffer-substring-no-properties
                               sym-start sym-end)))
                    (unless (or (string-prefix-p "&" name)
                                (eq (char-after sym-start) ?\())
                      (push (cons name nil) result)))
                  (goto-char sym-end)))
            (error (goto-char end)))))
      result)))

(defun let-completion--extract-shape-single (start end completion-pos)
  "Extract one binding from a (VAR EXPR) form between START and END.
Skip if span contains COMPLETION-POS.

Return one-element alist or nil.

Used for `dolist', `dotimes'."
  (if (<= start completion-pos end)
      nil
    (save-excursion
      (let ((text (buffer-substring-no-properties start end)))
        (condition-case nil
            (let ((sexp (car (read-from-string text))))
              (when (and (consp sexp) (symbolp (car sexp)))
                (list (cons (symbol-name (car sexp))
                            (cadr sexp)))))
          ;; `read' failed — extract name only.
          (error
           (goto-char (1+ start))
           (skip-chars-forward " \t\n")
           (let ((name-end (ignore-errors (scan-sexps (point) 1))))
             (when name-end
               (list (cons (buffer-substring-no-properties
                            (point) name-end)
                           nil))))))))))

(defun let-completion--extract-shape-error-var (start end completion-pos)
  "Extract one name from a bare symbol between START and END.
Skip if span contains COMPLETION-POS.

Return one-element alist or nil.

Used for `condition-case'."
  (if (<= start completion-pos end)
      nil
    (let ((name (string-trim
                 (buffer-substring-no-properties start end))))
      (unless (or (string-empty-p name) (string= name "nil"))
        (list (cons name nil))))))

;;;; Dispatcher

(defun let-completion--extract-bindings-at (pos completion-pos)
  "Extract bindings from form at POS using registry descriptor.
POS is the opening paren of the form.  COMPLETION-POS is point.
Look up the head symbol in the registry, then dispatch to the
appropriate shape extractor.

Return alist of (NAME-STRING . VALUE-OR-NIL) or nil.

Called by `let-completion--binding-values'."
  (save-excursion
    (goto-char (1+ pos))
    (skip-chars-forward " \t\n")
    (let* ((head-start (point))
           (head-end (ignore-errors (scan-sexps (point) 1))))
      (when head-end
        (let* ((head-str (buffer-substring-no-properties
                          head-start head-end))
               (head-sym (intern-soft head-str))
               (spec (when head-sym
                       (let-completion--lookup-spec head-sym))))
          (when spec
            (if (functionp spec)
                ;; Custom extractor function.
                (funcall spec pos completion-pos)
              (let-completion--extract-by-spec
               pos completion-pos head-end spec))))))))

(defun let-completion--extract-by-spec (pos completion-pos head-end spec)
  "Extract bindings from form at POS according to SPEC.
HEAD-END is position after the head symbol.
COMPLETION-POS is where point is.
SPEC is the registry descriptor plist.

Navigate to the sexp at `:bindings-index', check `:scope' against
COMPLETION-POS, dispatch on `:binding-shape'.

Return alist of (NAME-STRING . VALUE-OR-NIL) or nil.

Called by `let-completion--extract-bindings-at'."
  (save-excursion
    (goto-char head-end)
    (let ((idx (plist-get spec :bindings-index))
          (shape (plist-get spec :binding-shape))
          (scope (plist-get spec :scope)))
      ;; Navigate forward to the binding sexp.
      ;; idx 1 means the next sexp after head, idx 2 means skip one more.
      (condition-case nil
          (dotimes (_ (1- idx))
            (skip-chars-forward " \t\n")
            (forward-sexp 1))
        (scan-error nil))
      (skip-chars-forward " \t\n")
      (let ((bindings-start (point))
            (bindings-end (ignore-errors (scan-sexps (point) 1))))
        (when (and bindings-end
                   (let-completion--scope-visible-p
                    pos bindings-end completion-pos scope))
          (let-completion--extract-shape
           shape bindings-start bindings-end completion-pos))))))

;;;; Top-Level Binding Walker

(defun let-completion--binding-values ()
  "Return alist of (NAME-STRING . RAW-SEXP) for enclosing bindings.
Walk enclosing paren positions from `syntax-ppss', look up each
form's head symbol in the binding form registry, and extract
bindings via the registered descriptor.

Innermost binding for a given name appears first so `assoc'
finds the correct shadowing.

Called by `let-completion--advice'."
  (let ((completion-pos (point))
        result)
    (dolist (pos (nth 9 (syntax-ppss)))
      (let ((bindings
             (let-completion--extract-bindings-at pos completion-pos)))
        (dolist (b bindings)
          (push b result))))
    result))

;;;; Doc Buffer

(defvar let-completion--doc-buffer nil
  "Reusable buffer for pretty-printed binding values.
Created on first use by the function `let-completion--doc-buffer'.
Consumed by corfu-popupinfo via `:company-doc-buffer'.")

(defun let-completion--doc-buffer ()
  "Return reusable doc buffer with `emacs-lisp-mode' initialized.
The buffer is created once and reused across calls.  Mode setup
runs via function `delay-mode-hooks' to avoid triggering user hooks.

Called by `let-completion--advice' for `:company-doc-buffer'."
  (or (and (buffer-live-p let-completion--doc-buffer)
           let-completion--doc-buffer)
      (setq let-completion--doc-buffer
            (with-current-buffer (get-buffer-create " *let-completion-doc*")
              (delay-mode-hooks (emacs-lisp-mode))
              (current-buffer)))))

;;;; Completion Table Wrapper

(defun let-completion--make-table (table sort-fn local-names)
  "Wrap TABLE to inject LOCAL-NAMES and SORT-FN into completion.
Merge LOCAL-NAMES into all completion actions so candidates found
by the parser but missed by `elisp--local-variables' appear in
results.  Inject `display-sort-function' into the metadata
response via SORT-FN.  Pass `boundaries' actions through unchanged.

Called by `let-completion--advice'."
  (lambda (string pred action)
    (cond
     ((eq action 'metadata)
      (let ((md (if (functionp table)
                    (funcall table string pred 'metadata)
                  '(metadata))))
        `(metadata (display-sort-function . ,sort-fn)
          ,@(assq-delete-all
             'display-sort-function
             (cdr md)))))
     ((eq (car-safe action) 'boundaries)
      (complete-with-action action table string pred))
     (t
      (let ((local-table (lambda (str _pred _flag)
                           (all-completions str local-names))))
        (complete-with-action action
                              (completion-table-merge table local-table)
                              string pred))))))

(defun let-completion--advice (orig-fn)
  "Enrich the capf result from ORIG-FN with let-binding metadata.
Wrap the completion table via `let-completion--make-table' to
merge extracted local names into the candidate pool and inject
`display-sort-function' into the table's metadata response,
promoting locals to the top.  Inject `:annotation-function' to
show values or \"[local]\" tags, and `:company-doc-buffer' to
provide full pretty-printed values.  All three fall back to the
original plist functions for non-local candidates.

Unbind `print-level' and `print-length' inside the doc-buffer
function to defeat truncation imposed by `corfu-popupinfo'.

Installed as `:around' advice on `elisp-completion-at-point' by
`let-completion-mode'.  Removed by disabling the mode."
  (let ((result (funcall orig-fn)))
    (when (and result (listp result) (>= (length result) 3))
      (let* ((vals (let-completion--binding-values))
             (local-names (mapcar #'car vals)))
        (when vals
          (let* ((plist (nthcdr 3 result))
                 (orig-ann (plist-get plist :annotation-function))
                 (orig-doc (plist-get plist :company-doc-buffer))
                 (sort-fn (lambda (cands)
                            (let ((seen (make-hash-table :test #'equal))
                                  local other)
                              (dolist (c cands)
                                (unless (gethash c seen)
                                  (puthash c t seen)
                                  (if (member c local-names)
                                      (push c local)
                                    (push c other))))
                              (nconc (nreverse local) (nreverse other))))))
            (setq result
                  (append
                   (list (nth 0 result) (nth 1 result)
                         (let-completion--make-table (nth 2 result) sort-fn local-names)
                         :annotation-function
                         (lambda (c)
                           (let ((cell (assoc c vals)))
                             (if cell
                                 (let* ((short (and let-completion-inline-max-width
                                                    (prin1-to-string (cdr cell))))
                                        (short (if (and short
                                                        (<= (length short)
                                                            let-completion-inline-max-width))
                                                   short
                                                 "local")))
                                   (format let-completion-annotation-format short))
                               (when orig-ann (funcall orig-ann c)))))
                         :company-doc-buffer
                         (lambda (c)
                           (let ((cell (assoc c vals)))
                             (if cell
                                 (let ((buf (let-completion--doc-buffer)))
                                   (with-current-buffer buf
                                     (let ((inhibit-read-only t)
                                           (print-level nil)
                                           (print-length nil))
                                       (erase-buffer)
                                       (let* ((value (cdr cell))
                                              (oneline (prin1-to-string value))
                                              (text (if (> (length oneline) fill-column)
                                                        (pp-to-string value)
                                                      oneline)))
                                         (insert text))
                                       (font-lock-ensure)))
                                   buf)
                               (when orig-doc (funcall orig-doc c))))))
                   (cl-loop for (k v) on plist by #'cddr
                            unless (memq k '(:annotation-function
                                             :company-doc-buffer
                                             :display-sort-function))
                            nconc (list k v))))))))
    result))

;;;; Minor Mode

;;;###autoload
(define-minor-mode let-completion-mode
  "Enrich Elisp completion with let-binding values.
When enabled, install `let-completion--advice' around
`elisp-completion-at-point'.  When disabled, remove it.

Also see `let-completion-inline-max-width'."
  :lighter nil
  :group 'let-completion
  (if let-completion-mode
      (advice-add 'elisp-completion-at-point :around
                  #'let-completion--advice)
    (advice-remove 'elisp-completion-at-point #'let-completion--advice)))

(provide 'let-completion)
;;; let-completion.el ends here
