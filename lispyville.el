;;; lispyville.el --- A minor mode for integrating evil with lispy.

;; Author: Fox Kiester <noct@openmailbox.org>
;; URL: https://github.com/noctuid/lispyville
;; Created: March 03, 2016
;; Keywords: vim, evil, lispy, lisp, parentheses
;; Package-Requires: ((lispy "0") (evil "0") (cl-lib "0.5"))
;; Version: 0.1

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; For more information see the README in the online repository.

;;; Code:
(require 'evil)
(require 'lispy)
(require 'cl-lib)

(defgroup lispyville nil
  "Provides a minor mode to integrate evil with lispy."
  :group 'lispy
  :prefix 'lispyville)

(defcustom lispyville-key-theme '(operators)
  "Determines the key theme initially set by lispyville.
Changing this variable will only have an effect by itself when done prior to
lispyville being loaded. Otherwise, `lispyville-set-key-theme' should be
called afterwards with no arguments. The user can also not set this variable
at all and simply use `lispyville-set-key-theme' with an argument after
lispyville has been loaded."
  :group 'lispyville
  :type '(repeat :tag "Key Themes"
          (choice
           (const :tag "Remap the operator keys to their safe versions."
            operators)
           (const :tag "Remap the s and S operator keys to their safe version."
            s-operators)
           (const
            :tag "Extra motions similar to those given by evil-cleverparens."
            additional-movement))))

(defcustom lispyville-dd-stay-with-closing-delimiters nil
  "When non-nil, dd (`lispyville-delete') will move the point up a line.
The point will be placed just before the unmatched delimiters that were not
deleted."
  :group 'lispyville
  :type 'boolean)

(defcustom lispyville-motions-put-into-special nil
  "Applicable motions will enter insert or emacs state.
This will only happen when they are not called with an operator or in visual
mode."
  :group 'lispyville
  :type '(choice
          (const :tag "Enter emacs state to get into special." emacs)
          (const :tag "Enter insert state to get into special." insert)
          (const :tag "Same as 'insert." t)
          (const :tag "Don't enter special after motions." nil)))

;;;###autoload
(define-minor-mode lispyville-mode
    "A minor mode for integrating evil with lispy."
  :lighter " LYVLE"
  :keymap (make-sparse-keymap)
  (evil-normalize-keymaps))

;;; * Helpers
(defun lispyville--in-string-p ()
  "Return whether the point is in a string.
Unlike `lispy--in-string-p', |\"\" is not considered to be inside the string."
  (let ((str (lispy--bounds-string)))
    (and str
         (not (= (car str) (point))))))

(defun lispyville--at-left-p ()
  "Return whether the point is before an opening delimiter.
Opening delimiters inside strings and comments are ignored."
  (and (not (lispy--in-comment-p))
       (not (lispyville--in-string-p))
       (or (looking-at lispy-left)
           (looking-at "\""))
       (not (looking-back "\\\\" (- (point) 2)))))

(defun lispyville--at-right-p ()
  "Return whether the point is before a closing delimiter.
Closing delimiters inside strings and comments are ignored."
  (and (not (lispy--in-comment-p))
       (or (and (looking-at lispy-right)
                (not (lispyville--in-string-p)))
           (and (looking-at "\"")
                (lispyville--in-string-p)))
       (not (looking-back "\\\\" (- (point) 2)))))

(defun lispyville--yank-text (text &optional register yank-handler)
  "Like `evil-yank-characters' but takes TEXT directly instead of a region.
REGISTER and YANK-HANDLER have the same effect."
  (when yank-handler
    (setq text (propertize text 'yank-handler (list yank-handler))))
  (when register
    (evil-set-register register text))
  (when evil-was-yanked-without-register
    (evil-set-register ?0 text))
  (unless (eq register ?_)
    (kill-new text)))

;; TODO: behavior in comment and strings; make pull request to lispy
(defun lispyville--safe-manipulate
    (beg end &optional delete yank register yank-handler)
  "Return the text from BEG to END excluding unmatched delimiters.
When DELETE is non-nil, delete the safe part of the region. When YANK is
non-nil, also copy the safe text to the kill ring. REGISTER and YANK-HANDLER
should also be supplied if YANK is non-nil."
  (let ((safe-regions (if (lispy--in-comment-p)
                          (list (cons beg end))
                        (lispy--find-safe-regions beg end)))
        safe-strings
        safe-string)
    (dolist (safe-region safe-regions)
      ;; TODO should properties be preserved?
      (push (lispy--string-dwim safe-region) safe-strings)
      (when delete
        (delete-region (car safe-region) (cdr safe-region))))
    (setq safe-string (apply #'concat safe-strings))
    (when yank
      (lispyville--yank-text safe-string register yank-handler))
    safe-string))

(defvar lispyville--safe-strings-holder nil)
(defun lispyville--safe-manipulate-rectangle
    (beg end &optional delete yank register yank-handler)
  "Like `lispyville--safe-manipulate' but operate on a rectangle/block.
BEG AND END mark the start and beginning of the rectangle. DELETE, YANK,
REGISTER, and YANK-HANDLER all have the same effect as in
`lispyville--safe-manipulate'."
  (let (safe-string)
    (apply-on-rectangle
     (lambda (beg end delete)
       (setq beg (save-excursion (move-to-column beg) (point)))
       (setq end (save-excursion (move-to-column end) (point)))
       (push
        (lispyville--safe-manipulate beg end delete)
        lispyville--safe-strings-holder))
     beg end delete)
    (setq safe-string (apply #'concat
                             (lispy-interleave
                              "\n"
                              (nreverse lispyville--safe-strings-holder))))
    (setq lispyville--safe-strings-holder nil)
    (when yank
      (lispyville--yank-text safe-string register yank-handler))
    safe-string))

(defun lispyville--splice ()
  "Like `lispy-splice' but will also splice strings."
  (save-excursion
    (if (looking-at "\"")
        (cond ((save-excursion
                 (backward-char)
                 (lispy--in-string-p))
               (let ((right-quote (point)))
                 (lispy--exit-string)
                 (save-excursion
                   (goto-char right-quote)
                   (delete-char 1))
                 (delete-char 1)))
              (t
               (delete-char 1)
               (while (progn (re-search-forward "\"" nil t)
                             (looking-back "\\\\\"" (- (point) 2))))
               (delete-char -1)))
      (lispy-splice 1))))

;; TODO get rid of redundancy for these 2 and previous 2
(defun lispyville--safe-delete-by-splice
    (beg end &optional yank register yank-handler)
  "Like `lispyville--safe-manipulate' except always deletes.
Instead of ignoring unmatched delimiters between BEG and END, this will splice
them. YANK, REGISTER, and YANK-HANDLER all have the same effect."
  (let ((unmatched-positions (lispy--find-unmatched-delimiters beg end)))
    (evil-exit-visual-state)
    (save-excursion
      (dolist (pos unmatched-positions)
        (goto-char pos)
        (lispyville--splice))

      (setq end (- end (length unmatched-positions)))
      (let ((safe-text (lispy--string-dwim (cons beg end))))
        (when yank
          (lispyville--yank-text safe-text register yank-handler))
        (delete-region beg end)
        safe-text))))

(defun lispyville--rectangle-safe-delete-by-splice
    (beg end &optional yank register yank-handler)
  "Like `lispyville--safe-manipulate' but operate on a rectangle/block.
BEG, END, YANK, REGISTER, and YANK-HANDLER all have the same effect."
  (let (safe-string)
    (apply-on-rectangle
     (lambda (beg end)
       (setq beg (save-excursion (move-to-column beg) (point)))
       (setq end (save-excursion (move-to-column end) (point)))
       (push
        (lispyville--safe-delete-by-splice beg end)
        lispyville--safe-strings-holder))
     beg end)
    (setq safe-string (apply #'concat
                             (lispy-interleave
                              "\n"
                              (nreverse lispyville--safe-strings-holder))))
    (setq lispyville--safe-strings-holder nil)
    (when yank
      (lispyville--yank-text safe-string register yank-handler))
    safe-string))

(defun lispyville--yank-line-handler (text)
  "Modified version of `evil-yank-line-handler' to handle lack of newlines.
The differences are commented on. This is the same yank handler used in
evil-cleverparens."
  (let ((text (apply #'concat (make-list (or evil-paste-count 1) text)))
        (opoint (point)))
    (remove-list-of-text-properties
     0 (length text) yank-excluded-properties text)
    (cond
      ((eq this-command 'evil-paste-before)
       (evil-move-beginning-of-line)
       (evil-move-mark (point))
       ;; insert a newline afterwards
       (insert text "\n")
       (setq evil-last-paste
             (list 'evil-paste-before
                   evil-paste-count
                   opoint
                   (mark t)
                   (point)))
       (evil-set-marker ?\[ (mark))
       (evil-set-marker ?\] (1- (point)))
       (evil-exchange-point-and-mark)
       (back-to-indentation))
      ((eq this-command 'evil-paste-after)
       (evil-move-end-of-line)
       (evil-move-mark (point))
       (insert "\n")
       (insert text)
       (evil-set-marker ?\[ (1+ (mark)))
       (evil-set-marker ?\] (1- (point)))
       ;; don't delete last character
       ;; (delete-char -1)
       (setq evil-last-paste
             (list 'evil-paste-after
                   evil-paste-count
                   opoint
                   (mark t)
                   (point)))
       (evil-move-mark (1+ (mark t)))
       (evil-exchange-point-and-mark)
       (back-to-indentation))
      (t
       (insert text)))))

;;; * Commands
;; TODO make motion
(defun lispyville-first-non-blank ()
  "Like `evil-first-non-blank' but skips opening delimiters.
This is lispyville equivalent of `evil-cp-first-non-blank-non-opening'."
  (interactive)
  (evil-first-non-blank)
  (while (and (<= (point) (point-at-eol))
              (lispyville--at-left-p))
    (forward-char)))

;;; * Operators
(evil-define-operator lispyville-yank (beg end type register yank-handler)
  "Like `evil-yank' but will not copy unmatched delimiters."
  :move-point nil
  :repeat nil
  (interactive "<R><x><y>")
  (let ((evil-was-yanked-without-register
         (and evil-was-yanked-without-register (not register))))
    (cond ((eq type 'block)
           (lispyville--safe-manipulate-rectangle beg end nil t
                                                  register yank-handler))
          ((eq type 'line)
           ;; don't include the newline at the end
           (setq end (1- end))
           (lispyville--safe-manipulate beg end nil t
                                        register 'lispyville--yank-line-handler))
          (t
           (lispyville--safe-manipulate beg end nil t
                                        register yank-handler)))))

;; NOTE: Y, D, and C don't work with counts in evil by default already
(evil-define-operator lispyville-yank-line (beg end type register yank-handler)
  "Copy to the end of the line ignoring unmatched delimiters.
This is not like the default `evil-yank-line'."
  :motion nil
  :keep-visual t
  (interactive "<R><x>")
  (let ((beg (or beg (point)))
        (end (or end beg)))
    ;; act linewise in Visual state
    (when (evil-visual-state-p)
      (unless (memq type '(line block))
        (let ((range (evil-expand beg end 'line)))
          (setq beg (evil-range-beginning range)
                end (evil-range-end range)
                type (evil-type range))))
      (evil-exit-visual-state))
    (cond ((eq type 'block)
           (let ((temporary-goal-column most-positive-fixnum)
                 (last-command 'next-line))
             (lispyville-yank beg end 'block register yank-handler)))
          ((eq type 'line)
           (lispyville-yank beg end type register yank-handler))
          (t
           (lispyville-yank beg (line-end-position)
                            type register yank-handler)))))

(evil-define-operator lispyville-delete (beg end type register yank-handler)
  "Like `evil-delete' but will not delete/copy unmatched delimiters."
  (interactive "<R><x><y>")
  (unless register
    (let ((text (filter-buffer-substring beg end)))
      (unless (string-match-p "\n" text)
        ;; set the small delete register
        (evil-set-register ?- (lispyville--safe-manipulate beg end)))))
  (let ((evil-was-yanked-without-register nil))
    (cond ((eq type 'block)
           (lispyville--safe-manipulate-rectangle beg end t t
                                                  register yank-handler))
          ((eq type 'line)
           ;; don't include the newline at the end
           (setq end (1- end))
           (lispyville--safe-manipulate beg end t t
                                        register 'lispyville--yank-line-handler)
           (lispyville-first-non-blank)
           (cond ((lispyville--at-right-p)
                  ;; (lispy--reindent 1)
                  (when (save-excursion
                          (forward-line -1)
                          (not (lispy--in-comment-p)))
                    (forward-line -1)
                    (join-line 1)
                    (save-excursion
                      (goto-char (line-end-position))
                      (when (looking-back "\"")
                        (backward-char)
                        (delete-char -1)))
                    (unless lispyville-dd-stay-with-closing-delimiters
                      (forward-line 1))))
                 (t
                  (join-line 1)))
           (indent-for-tab-command))
          (t
           (lispyville--safe-manipulate beg end t t register yank-handler)))))

(evil-define-operator lispyville-delete-line
    (beg end type register yank-handler)
  "Like `evil-delete-line' but will not delete/copy unmatched delimiters."
  :motion nil
  :keep-visual t
  (interactive "<R><x>")
  (let* ((beg (or beg (point)))
         (end (or end beg)))
    ;; act linewise in Visual state
    (when (evil-visual-state-p)
      (unless (memq type '(line block))
        (let ((range (evil-expand beg end 'line)))
          (setq beg (evil-range-beginning range)
                end (evil-range-end range)
                type (evil-type range))))
      (evil-exit-visual-state))
    (cond ((eq type 'block)
           (let ((temporary-goal-column most-positive-fixnum)
                 (last-command 'next-line))
             (lispyville-delete beg end 'block register yank-handler)))
          ((eq type 'line)
           (lispyville-delete beg end type register yank-handler))
          (t
           (lispyville-delete beg (line-end-position)
                              type register yank-handler)))))

(evil-define-operator lispyville-change
    (beg end type register yank-handler delete-func)
  "Like `evil-change' but will not delete/copy unmatched delimiters."
  (interactive "<R><x><y>")
  (let ((delete-func (or delete-func #'lispyville-delete))
        (nlines (1+ (evil-count-lines beg end)))
        (opoint (save-excursion
                  (goto-char beg)
                  (line-beginning-position))))
    (unless (eq type 'line)
      (funcall delete-func beg end type register yank-handler))
    (cond
      ((eq type 'line)
       (setq end (1- end))
       (lispyville--safe-manipulate beg end t t
                                    register 'lispyville--yank-line-handler)
       (lispyville-first-non-blank)
       (evil-insert 1)
       (indent-for-tab-command))
      ((eq type 'block)
       (evil-insert 1 nlines))
      (t
       (evil-insert 1)))))

(evil-define-operator lispyville-change-line
    (beg end type register yank-handler)
  "Like `evil-change-line' but will not delete/copy unmatched delimiters."
  :motion evil-end-of-line
  (interactive "<R><x><y>")
  (lispyville-change beg end type register yank-handler
                     #'lispyville-delete-line))

(evil-define-operator evil-delete-whole-line
    (beg end type register yank-handler)
  "Delete whole line."
  :motion evil-line
  (interactive "<R><x>")
  (lispyville-delete beg end type register yank-handler))

(evil-define-operator lispyville-change-whole-line
    (beg end type register yank-handler)
  "Change whole line while respecting parentheses."
  :motion evil-line
  (interactive "<R><x>")
  (lispyville-change beg end type register yank-handler
                     #'lispyville-delete-whole-line))

(evil-define-operator lispyville-delete-char-or-splice
    (beg end type register yank-handler)
  "Deletes and copies the region by splicing unmatched delimiters."
  :motion evil-forward-char
  (interactive "<R><x>")
  (cond ((eq type 'block)
         (lispyville--rectangle-safe-delete-by-splice beg end t
                                                      register yank-handler))
        (t
         (lispyville--safe-delete-by-splice beg end t register yank-handler))))

(evil-define-operator lispyville-delete-char-or-splice-backwards
    (beg end type register yank-handler)
  "Like `lispyville-delete-char-or-splice' but acts on the preceding character."
  :motion evil-backward-char
  (interactive "<R><x>")
  (lispyville-delete-char-or-splice beg end type register yank-handler))

(evil-define-operator lispyville-substitute (beg end type register)
  "Acts like `lispyville-change' (cl when not in visual mode)."
  :motion evil-forward-char
  (interactive "<R><x>")
  (lispyville-change beg end type register))

;;; * Motions
;; ** Additional Movement Key Theme
(evil-define-motion lispyville-forward-sexp (count)
  "This is an evil motion equivalent of `forward-sexp'."
  ;; TODO maybe forward-sexp-or-comment would be more useful
  ;; TODO also consider having it jump to the next level for failure
  ;; like evil-cp motion does
  (forward-sexp (or count 1)))

(evil-define-motion lispyville-backward-sexp (count)
  "This is an evil motion equivalent of `backward-sexp'."
  (backward-sexp (or count 1)))

(defun lispyville--maybe-insert (&optional move-right)
  "Potentially enter insert or emacs state.
The behavior depends on the value of `lispyville-motions-put-into-special'.
If MOVE-RIGHT is non-nil, move right before changing state."
  (when (and lispyville-motions-put-into-special
             (not (or (evil-operator-state-p)
                      (evil-visual-state-p))))
    (when move-right
      (forward-char))
    (if (eq lispyville-motions-put-into-special 'emacs)
        (evil-emacs-state)
      (evil-insert-state))))

(evil-define-motion lispyville-beginning-of-defun (count)
  "This is the evil motion equivalent of `beginning-of-defun'.
This won't jump to the beginning of the buffer if there is no paren there."
  (beginning-of-defun (or count 1))
  (lispyville--maybe-insert))

(evil-define-motion lispyville-end-of-defun (count)
  "This is the evil motion equivalent of `end-of-defun'.
This won't jump to the end of the buffer if there is no paren there."
  (end-of-defun (or count 1))
  (re-search-backward lispy-right nil t)
  (lispyville--maybe-insert t))

;; lispy-flow like (and reverse)
(defun lispyville--move-to-delimiter (count &optional type)
  "Move COUNT times to the next TYPE delimiter.
Move backwards when COUNT is negative. Unlike `evil-cp-next-closing', this won't
 jump into comments or strings."
  (setq type (or type 'right))
  (let ((positive (> count 0))
        (regex (concat (if (eq type 'left)
                           (substring lispy-left 0 -1)
                         (substring  lispy-right 0 -1))
                       "\"]"))
        (initial-pos (point))
        success)
    (dotimes (_ (abs count))
      (when positive
        (forward-char))
      (while
          (and (if positive
                   (re-search-forward regex nil t)
                 (re-search-backward regex nil t))
               (setq success t)
               (save-excursion
                 (goto-char (match-beginning 0))
                 (or
                  (lispy--in-comment-p)
                  (not (if (eq type 'left)
                           (lispyville--at-left-p)
                         (lispyville--at-right-p))))))
        (setq success nil))
      (if success
          (goto-char (match-beginning 0))
        (goto-char initial-pos)))))

(evil-define-motion lispyville-next-opening (count)
  "Move to the next opening delimiter COUNT times."
  (lispyville--move-to-delimiter (or count 1) 'left)
  (unless (looking-at "\"")
    (lispyville--maybe-insert)))

(evil-define-motion lispyville-previous-opening (count)
  "Move to the previous opening delimiter COUNT times."
  (lispyville--move-to-delimiter (- (or count 1)) 'left)
  (unless (looking-at "\"")
    (lispyville--maybe-insert)))

(evil-define-motion lispyville-next-closing (count)
  "Move to the next closing delimiter COUNT times."
  (lispyville--move-to-delimiter (or count 1))
  (unless (looking-at "\"")
    (lispyville--maybe-insert t)))

(evil-define-motion lispyville-previous-closing (count)
  "Move to the previous closing delimiter COUNT times."
  (lispyville--move-to-delimiter (- (or count 1)))
  (unless (looking-at "\"")
    (lispyville--maybe-insert t)))

(evil-define-motion lispyville-backward-up-list (count)
  "This is the evil motion equivalent of `lispy-left' (or `backward-up-list').
This is comparable to `evil-cp-backward-up-sexp'. It does not have lispy's
behavior on outlines."
  (lispy-left (or count 1)))

(defalias 'lispyville-left 'lispyville-backward-up-list)

(evil-define-motion lispyville-up-list (count)
  "This is the evil motion equivalent of `lispy-right' (or `up-list').
This is comparable to `evil-cp-up-sexp'. It does not have lispy's behavior
on outlines."
  (lispy-right (or count 1)))

(defalias 'lispyville-right 'lispyville-up-list)

;;; * Keybindings
(defmacro lispyville--define-key (states &rest maps)
  "Helper function for defining keys in multiple STATES at once.
MAPS are the keys and commands to define in lispyville-mode-map."
  (declare (indent 1))
  (let ((state (cl-gensym "state")))
    `(if (listp ,states)
         (dolist (,state ,states)
           (evil-define-key ,state lispyville-mode-map ,@maps))
       (evil-define-key ,states lispyville-mode-map ,@maps))))

;;;###autoload
(defun lispyville-set-key-theme (&optional theme)
  "Binds keys in lispyville-mode-map according to THEME.
When THEME is not given, `lispville-key-theme' will be used instead."
  (unless theme (setq theme lispyville-key-theme))
  (dolist (item theme)
    (let ((type (if (listp item)
                    (car item)
                  item))
          (states (if (listp item)
                      (cdr item)
                    '(normal visual))))
      (cond ((eq type 'operators)
             (lispyville--define-key states
               "y" #'lispyville-yank
               "d" #'lispyville-delete
               "c" #'lispyville-change
               "Y" #'lispyville-yank-line
               "D" #'lispyville-delete-line
               "C" #'lispyville-change-line
               "x" #'lispyville-delete-char-or-splice
               "X" #'lispyville-delete-char-or-splice-backwards))
            ((eq type 's-operators)
             (lispyville--define-key states
               "s" #'lispyville-substitute))
            ((eq type 'additional-movement)
             (lispyville--define-key states
               "H" #'lispyville-backward-sexp
               "L" #'lispyville-forward-sexp
               (kbd "M-h") #'lispyville-beginning-of-defun
               (kbd "M-l") #'lispyville-end-of-defun
               ;; reverse of lispy-flow
               "[" #'lispyville-previous-opening
               "]" #'lispyville-next-closing
               ;; like lispy-flow
               "{" #'lispyville-next-opening
               "}" #'lispyville-previous-closing
               ;; like lispy-left and lispy-right
               "(" #'lispyville-backward-up-list
               ")" #'lispyville-up-list))))))

(lispyville-set-key-theme)

(provide 'lispyville)
;;; lispyville.el ends here
