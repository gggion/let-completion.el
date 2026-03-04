;;; let-completion.el --- Show let-binding values in Elisp completion -*- lexical-binding: t -*-

;; Author: Gino Cornejo <gggion123@gmail.com>
;; Maintainer: Gino Cornejo <gggion123@gmail.com>
;; Homepage: https://github.com/gggion/let-completion
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

(defgroup let-completion nil
  "Show let-binding values in Elisp completion."
  :group 'lisp
  :prefix "let-completion-")

(defcustom let-completion-annotation-format " [%s]"
  "The format string for inline annotation."
  :type 'string
  :group 'let-completion)

(defcustom let-completion-inline-max-width 5
  "Max printed width for inline value annotation, or nil to disable.
Only binding values whose `prin1-to-string' form fits within this
many characters appear inline next to the candidate as \" [VALUE]\".
Longer values show \" [local]\" instead.  The popupinfo buffer
always shows the full value regardless of this setting.

Also see `let-completion-mode'."
  :type '(choice natnum (const :tag "Disable" nil)))

(defvar let-completion--doc-buffer nil
  "Reusable buffer for pretty-printed binding values.
Created on first use by `let-completion--doc-buffer'.
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

(defun let-completion--extract-let-bindings (pos)
  "Extract bindings from a let-like form starting at POS.
POS is the opening paren.  Return alist of (NAME-STRING . RAW-SEXP),
or nil if POS does not start a recognized form.

Recognize `let', `let*', `when-let', `when-let*', `if-let',
`if-let*', and `and-let*'.  For `if-let' and `if-let*', return
nil when point is in the else branch, where bindings are not in
scope.

Called by `let-completion--binding-values'."
  (save-excursion
    (let ((completion-pos (point)))
      (goto-char (1+ pos))
      (when (looking-at
             "\\_<\\(?:and-let\\*\\|\\(if-let\\*?\\)\\|let\\*?\\|when-let\\*?\\)\\_>")
        (let ((is-if-let (match-beginning 1)))
          (let ((end (save-excursion
                       (forward-sexp 1)
                       (forward-sexp 1)
                       (point))))
            (forward-sexp 1)
            (when (and is-if-let
                       (ignore-errors
                         (save-excursion
                           (goto-char end)
                           (forward-sexp 1)
                           (< (point) completion-pos))))
              (setq end nil))
            (when end
              (ignore-errors
                (let (result)
                  (dolist (b (read (buffer-substring-no-properties
                                    (point) end)))
                    (cond
                     ((consp b)
                      (push (cons (symbol-name (car b))
                                  (if (cdr b) (cadr b) nil))
                            result))
                     ((symbolp b)
                      (push (cons (symbol-name b) nil) result))))
                  result)))))))))

(defun let-completion--extract-single-binding (pos keyword)
  "Extract a single binding from form at POS starting with KEYWORD.
KEYWORD is a string like \"dolist\" or \"dotimes\".  The binding
form is (VAR EXPR).  Return one-element alist or nil.

Called by `let-completion--binding-values'."
  (save-excursion
    (goto-char (1+ pos))
    (when (looking-at (concat "\\_<" (regexp-quote keyword) "\\_>"))
      (forward-sexp 1)
      (ignore-errors
        (let ((binding (read (buffer-substring-no-properties
                              (point)
                              (save-excursion (forward-sexp 1) (point))))))
          (when (and (consp binding) (symbolp (car binding)))
            (list (cons (symbol-name (car binding))
                        (cadr binding)))))))))

(defun let-completion--binding-values ()
  "Return alist of (NAME-STRING . RAW-SEXP) for enclosing bindings.
Walk paren positions from `syntax-ppss' (element 9), detect
`let', `let*', `when-let*', `if-let*', `and-let*', `dolist', and
`dotimes' forms, read each binding list with `read', and collect
name-value pairs.  Silently skip unreadable or malformed forms.

The innermost binding for a given name appears first in the result,
so `assoc' finds the correct shadowing.

Called by `let-completion--advice'."
  (let (result)
    (dolist (pos (nth 9 (syntax-ppss)))
      (let ((bindings
             (or (let-completion--extract-let-bindings pos)
                 (let-completion--extract-single-binding pos "dolist")
                 (let-completion--extract-single-binding pos "dotimes"))))
        (dolist (b bindings)
          (push b result))))
    result))

(defun let-completion--make-table (table sort-fn local-names)
  "Wrap TABLE to inject LOCAL-NAMES and SORT-FN into completion.
Merge LOCAL-NAMES into all completion actions so candidates
found by our parser but missed by `elisp--local-variables' appear
in results.  Inject `display-sort-function' into the metadata
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
                                       (insert (pp-to-string (cdr cell)))
                                       (font-lock-ensure)))
                                   buf)
                               (when orig-doc (funcall orig-doc c))))))
                   (cl-loop for (k v) on plist by #'cddr
                            unless (memq k '( :annotation-function
                                              :company-doc-buffer
                                              :display-sort-function))
                            nconc (list k v))))))))
    result))

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
