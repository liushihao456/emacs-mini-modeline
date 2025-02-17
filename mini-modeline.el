;;; mini-modeline.el --- Display modeline in minibuffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2019

;; Author:  Kien Nguyen <kien.n.quang@gmail.com>
;; URL: https://github.com/kiennq/emacs-mini-modeline
;; Version: 0.1
;; Keywords: convenience, tools
;; Package-Requires: ((emacs "25.1") (dash "2.12.0"))

;; This program is free software; you can redistribute it and/or modify
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

;; Display modeline in minibuffer.
;; With this we save one display line and also don't have to see redundant information.

;;; Code:

(require 'minibuffer)
(require 'dash)
(require 'frame)
(require 'timer)

(eval-when-compile
  (require 'subr-x)
  (require 'cl-lib))

(defgroup mini-modeline nil
  "Customizations for `mini-modeline'."
  :group 'minibuffer
  :prefix "mini-modeline-")

;; Forward declaration
(defvar evil-mode-line-tag)
(defvar treemacs-user-mode-line-format)

(defcustom mini-modeline-l-format nil
  "Left part of mini-modeline, same format with `mode-line-format'."
  :type `(repeat symbol)
  :group 'mini-modeline)

(defcustom mini-modeline-r-format '("%e" mode-line-front-space
                                    mode-line-mule-info
                                    mode-line-client
                                    mode-line-modified
                                    mode-line-remote
                                    mode-line-frame-identification
                                    mode-line-buffer-identification
                                    " " mode-line-position " "
                                    evil-mode-line-tag
                                    (:eval (string-trim (format-mode-line mode-line-modes)))
                                    mode-line-misc-info)
  "Right part of mini-modeline, same format with `mode-line-format'."
  :type `(repeat symbol)
  :group 'mini-modeline)

(defcustom mini-modeline-truncate-p t
  "Truncates mini-modeline or not."
  :type 'boolean
  :group 'mini-modeline)

(defface mini-modeline-mode-line
  '((((background light))
     :background "#55ced1" :height 0.1 :box nil)
    (t
     :background "#008b8b" :height 0.1 :box nil))
  "Modeline face for active window."
  :group 'mini-modeline)

(defface mini-modeline-mode-line-inactive
  '((((background light))
     :background "#dddddd" :height 0.1 :box nil)
    (t
     :background "#333333" :height 0.1 :box nil))
  "Modeline face for inactive window."
  :group 'mini-modeline)

(defface mini-modeline-mode-line-tui
  '((((background light))
     :foreground "#55ced1" :underline "#55ced1")
    (t
     :foreground "#008b8b" :underline "#008b8b"))
  "Modeline face for active window in TUI mode."
  :group 'mini-modeline)

(defface mini-modeline-mode-line-inactive-tui
  '((((background light))
     :foreground "#dddddd" :underline "#dddddd")
    (t
     :foreground "#444444" :underline "#444444"))
  "Modeline face for inactive window in TUI mode."
  :group 'mini-modeline)

(defface mini-modeline--orig-mode-line-face
  '((t))
  "Original mode line face."
  :group 'mini-modeline)

(defface mini-modeline--orig-mode-line-inactive-face
  '((t))
  "Original mode line inactive face."
  :group 'mini-modeline)

(defface mini-modeline--orig-header-line-face
  '((t))
  "Original header line face."
  :group 'mini-modeline)

(defvar mini-modeline--orig-mode-line mode-line-format)
(defvar mini-modeline--echo-keystrokes echo-keystrokes)

(defcustom mini-modeline-echo-duration 2
  "Duration to keep display echo."
  :type 'number
  :group 'mini-modeline)

(defcustom mini-modeline-frame nil
  "Frame to display mini-modeline on.
Nil means current selected frame."
  :type 'sexp
  :group 'mini-modeline)

(defcustom mini-modeline-right-padding 3
  "Padding to use in the right side.
Set this to the minimal value that doesn't cause truncation."
  :type 'integer
  :group 'mini-modeline)

(defvar mini-modeline--last-echoed nil)

(defvar mini-modeline--msg nil)
(defvar mini-modeline--msg-message nil
  "Store the string from `message'.")

;; perf
(defcustom mini-modeline-update-interval 0.1
  "The minimum interval to update mini-modeline."
  :type 'number
  :group 'mini-modeline)

(defcustom mini-modeline-truncate-first-line-mesasge t
  "If t, only renders the first line of messages."
  :type 'boolean
  :group 'mini-modeline)

(defvar mini-modeline--last-update (current-time))
(defvar mini-modeline--last-change-size (current-time))
(defvar mini-modeline--cache nil)
(defvar mini-modeline--command-state 'begin
  "The state of current executed command begin -> [exec exec-read] -> end.")

(defun mini-modeline--set-face (to from)
  "Set face from FROM to TO."
  (set-face-attribute to nil
                      :family (face-attribute from :family)
                      :foundry (face-attribute from :foundry)
                      :width (face-attribute from :width)
                      :height (face-attribute from :height)
                      :weight (face-attribute from :weight)
                      :slant (face-attribute from :slant)
                      :foreground (face-attribute from :foreground)
                      :background (face-attribute from :background)
                      :underline (face-attribute from :underline)
                      :overline (face-attribute from :overline)
                      :strike-through (face-attribute from :strike-through)
                      :box (face-attribute from :box)
                      :inverse-video (face-attribute from :inverse-video)
                      :stipple (face-attribute from :stipple)
                      :extend (face-attribute from :extend)
                      :font (face-attribute from :font)
                      :inherit (face-attribute from :inherit)))

(defun mini-modeline--log (&rest args)
  "Log message into message buffer with ARGS as same parameters in `message'."
  (save-excursion
    (with-current-buffer "*Messages*"
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (apply #'format args))))))

(defsubst mini-modeline--overduep (since duration)
  "Check if time already pass DURATION from SINCE."
  (>= (float-time (time-since since)) duration))

(defvar mini-modeline--minibuffer nil)
(defun mini-modeline-display (&optional arg)
  "Update mini-modeline.
When ARG is:
- `force', force update the minibuffer.
- `clear', clear the minibuffer.  This implies `force'."
  (save-match-data
    (condition-case err
        (cl-letf (((symbol-function 'completion-all-completions) #'ignore)
                  (l-fmt mini-modeline-l-format)
                  (r-fmt mini-modeline-r-format))
          (unless (or (active-minibuffer-window)
                      (input-pending-p))
            (setq mini-modeline--minibuffer
                  (window-buffer (minibuffer-window mini-modeline-frame)))
            (with-current-buffer mini-modeline--minibuffer
              (let ((truncate-lines mini-modeline-truncate-p)
                    (inhibit-read-only t)
                    (inhibit-redisplay t)
                    (buffer-undo-list t)
                    modeline-content)
                (when (or (memq arg '(force clear))
                          (mini-modeline--overduep mini-modeline--last-update
                                                   mini-modeline-update-interval))
                  (when-let ((msg (or mini-modeline--msg-message (current-message))))
                    ;; Clear echo area and start new timer for echo message
                    (message nil)
                    (setq msg (car (split-string msg "\n")))
                    (setq mini-modeline--last-echoed (current-time))
                    ;; we proritize the message from `message'
                    ;; or the message when we're not in middle of a command running.
                    (when (or mini-modeline--msg-message
                              (eq mini-modeline--command-state 'begin))
                      (setq mini-modeline--command-state 'exec)
                      ;; Don't echo keystrokes when in middle of command
                      (setq echo-keystrokes 0))
                    (setq mini-modeline--msg msg))
                  ;; Reset echo message when timeout and not in middle of command
                  (when (and mini-modeline--msg
                             (not (memq mini-modeline--command-state '(exec exec-read)))
                             (mini-modeline--overduep mini-modeline--last-echoed
                                                      mini-modeline-echo-duration))
                    (setq mini-modeline--msg nil))
                  ;; Showing mini-modeline
                  (if (eq arg 'clear)
                      (setq modeline-content nil)
                    (let ((l-fmted (format-mode-line l-fmt))
                          (r-fmted (format-mode-line r-fmt)))
                      (setq modeline-content
                            (mini-modeline--multi-lr-render
                             (if mini-modeline--msg
                                 (let* ((truncated-msg (mini-modeline-truncate-str
                                                        mini-modeline--msg
                                                        ;; Here 10 means to keep " * [10%]"
                                                        (- (frame-width) 2 10
                                                           (length r-fmted))))
                                        (truncated-l-fmt (mini-modeline-truncate-str
                                                          l-fmted
                                                          (- (frame-width) 2
                                                             (length truncated-msg)
                                                             (length r-fmted))
                                                          ".."))
                                        (default-fg (face-attribute 'default :foreground)))
                                   (add-face-text-property
                                    0 (length truncated-msg) `(:underline ,default-fg) nil
                                    truncated-msg)
                                   (concat truncated-l-fmt " " truncated-msg))
                               l-fmted)
                             r-fmted)))

                    (setq mini-modeline--last-update (current-time)))

                  ;; write to minibuffer
                  (unless (equal modeline-content
                                 mini-modeline--cache)
                    (setq mini-modeline--cache modeline-content)
                    (erase-buffer)
                    (when mini-modeline--cache
                      (let ((height-delta (- (cdr mini-modeline--cache)
                                             (window-height (minibuffer-window mini-modeline-frame))))
                            ;; ; let mini-modeline take control of mini-buffer size
                            (resize-mini-windows t))
                        (when (or (> height-delta 0)
                                  ;; this is to prevent window flashing for consecutive multi-line message
                                  (mini-modeline--overduep mini-modeline--last-change-size
                                                           mini-modeline-echo-duration))
                          (window-resize (minibuffer-window mini-modeline-frame) height-delta)
                          (setq mini-modeline--last-change-size (current-time)))
                        (insert (car mini-modeline--cache))))))))))
      ((error debug)
       (mini-modeline--log "mini-modeline: %s\n" err)))))

(defun mini-modeline--escape-for-format-mode-line (str)
  "Escape STR for passing it to `format-mode-line'.

In details, the percent sign '%' is replaced with '%%'."
  (replace-regexp-in-string "%" "%%" str))

(defun mini-modeline-truncate-str (str width &optional ellipsis)
  "Truncate STR to WIDTH, ending with ELLIPSIS."
  (unless ellipsis
    (setq ellipsis "..."))
  (if (> (length str) width)
      (format "%s%s" (substring str 0 (- width (length ellipsis))) ellipsis)
    str))

(defun mini-modeline-msg ()
  "Place holder to display echo area message."
  (when mini-modeline--msg
    (replace-regexp-in-string "%" "%%" mini-modeline--msg)))

(defsubst mini-modeline--lr-render (left right)
  "Render the LEFT and RIGHT part of mini-modeline."
  (let* ((left (or left ""))
         (right (or right ""))
         (available-width (max (- (frame-width mini-modeline-frame)
                                  (string-width left)
                                  mini-modeline-right-padding)
                               0))
         (required-width (string-width right)))
    ;; (mini-modeline--log "a:%s r:%s\n" available-width required-width)
    (if (< available-width required-width)
        (if mini-modeline-truncate-p
            (cons
             ;; Emacs 25 cannot use position format
             (format (format "%%s %%%d.%ds" available-width available-width) left right)
             0)
          (cons
           (let ((available-width (+ available-width (string-width left))))
             (format (format "%%0.%ds\n%%s" available-width) right left))
           (ceiling (string-width left) (frame-width mini-modeline-frame))))
      (cons (format (format "%%s %%%ds" available-width) left right) 0))))

(defun mini-modeline--multi-lr-render (left right)
  "Render the LEFT and RIGHT part of mini-modeline with multiline supported.
Return value is (STRING . LINES)."
  (let* ((l (split-string left "\n"))
         (r (split-string right "\n"))
         (lines (max (length l) (length r)))
         (extra-lines 0)
         re)
    (--dotimes lines
      (let ((lr (mini-modeline--lr-render (elt l it) (elt r it))))
        (setq re (nconc re `(,(car lr))))
        (setq extra-lines (+ extra-lines (cdr lr)))))
    (cons (string-join re "\n") (+ lines extra-lines))))

(defun mini-modeline--reroute-msg (func &rest args)
  "Reroute FUNC with ARGS that echo to echo area to place hodler."
  (if inhibit-message
      (apply func args)
    (let* ((inhibit-message t)
           (mini-modeline--msg-message (apply func args)))
      (mini-modeline-display 'force)
      mini-modeline--msg-message)))

(defmacro mini-modeline--wrap (func &rest body)
  "Add an advice around FUNC with name mini-modeline--%s.
BODY will be supplied with orig-func and args."
  (let ((name (intern (format "mini-modeline--%s" func))))
    `(advice-add #',func :around
      (lambda (orig-func &rest args)
        ,@body)
      '((name . ,name)))))

(defsubst mini-modeline--pre-cmd ()
  "Pre command hook of mini-modeline."
  (setq mini-modeline--command-state 'begin))

(defsubst mini-modeline--post-cmd ()
  "Post command hook of mini-modeline."
  (setq mini-modeline--command-state 'end
        echo-keystrokes mini-modeline--echo-keystrokes))

(declare-function anzu--cons-mode-line "ext:anzu")
(declare-function anzu--reset-mode-line "ext:anzu")
(declare-function meow/search-setup-mode-line-indicator nil)
(declare-function meow/search-reset-mode-line-indicator nil)

(defvar mini-modeline--timer nil)

(defun mini-modeline--enable ()
  "Enable `mini-modeline'."
  ;; Hide modeline for terminal, or use empty modeline for GUI.
  (setq mini-modeline--orig-mode-line mode-line-format)
  (setq-default mode-line-format '(" "))

  (mini-modeline--set-face 'mini-modeline--orig-mode-line-face 'mode-line)
  (mini-modeline--set-face 'mini-modeline--orig-mode-line-inactive-face 'mode-line-inactive)
  (when (eq (face-attribute 'header-line :inherit) 'mode-line)
    (mini-modeline--set-face 'mini-modeline--orig-header-line-face 'header-line)
    (mini-modeline--set-face 'header-line 'mode-line))
  (if (display-graphic-p)
      (progn
        (mini-modeline--set-face 'mode-line 'mini-modeline-mode-line)
        (mini-modeline--set-face 'mode-line-inactive 'mini-modeline-mode-line-inactive))
    (mini-modeline--set-face 'mode-line 'mini-modeline-mode-line-tui)
    (mini-modeline--set-face 'mode-line-inactive 'mini-modeline-mode-line-inactive-tui))

  (add-hook 'pre-redisplay-functions #'mini-modeline-display)
  ;; (add-hook 'post-command-hook #'mini-modeline-display)
  (redisplay)
  ;; (setq mini-modeline--timer (run-with-idle-timer 0.1 t #'mini-modeline-display))
  (advice-add #'message :around #'mini-modeline--reroute-msg)

  (add-hook 'pre-command-hook #'mini-modeline--pre-cmd)
  (add-hook 'post-command-hook #'mini-modeline--post-cmd)

  ;; compatibility
  ;; treemacs
  (setq treemacs-user-mode-line-format mode-line-format)

  ;; anzu
  (mini-modeline--wrap
   anzu--cons-mode-line
   (let ((mode-line-format mini-modeline-l-format))
     (apply orig-func args)
     (setq mini-modeline-l-format mode-line-format)))
  (mini-modeline--wrap
   anzu--reset-mode-line
   (let ((mode-line-format mini-modeline-l-format))
     (apply orig-func args)
     (setq mini-modeline-l-format mode-line-format)))
  ;; meow search
  (mini-modeline--wrap
   meow/search-setup-mode-line-indicator
   (let ((mode-line-format mini-modeline-l-format))
     (apply orig-func args)
     (setq mini-modeline-l-format mode-line-format)))
  (mini-modeline--wrap
   meow/search-reset-mode-line-indicator
   (let ((mode-line-format mini-modeline-l-format))
     (apply orig-func args)
     (setq mini-modeline-l-format mode-line-format)))

  ;; read-key-sequence
  (mini-modeline--wrap
   read-key-sequence
   (progn
     (setq mini-modeline--command-state 'exec-read)
     (apply orig-func args)))
  (mini-modeline--wrap
   read-key-sequence-vector
   (progn
     (setq mini-modeline--command-state 'exec-read)
     (apply orig-func args))))

(defun mini-modeline--disable ()
  "Disable `mini-modeline'."
  ;; (setq-default mode-line-format (default-value 'mini-modeline--orig-mode-line))
  (setq-default mode-line-format 'mini-modeline--orig-mode-line)

  (mini-modeline--set-face 'mode-line 'mini-modeline--orig-mode-line-face)
  (mini-modeline--set-face 'mode-line-inactive 'mini-modeline--orig-mode-line-inactive-face)
  (unless (internal-lisp-face-empty-p 'mini-modeline--orig-header-line-face)
    (mini-modeline--set-face 'header-line 'mini-modeline--orig-header-line-face))

  (redisplay)
  ;; (remove-hook 'post-command-hook #'mini-modeline-display)
  (remove-hook 'pre-redisplay-functions #'mini-modeline-display)
  (when (timerp mini-modeline--timer) (cancel-timer mini-modeline--timer))
  (mini-modeline-display 'clear)
  (advice-remove #'message #'mini-modeline--reroute-msg)

  (remove-hook 'pre-command-hook #'mini-modeline--pre-cmd)
  (remove-hook 'post-command-hook #'mini-modeline--post-cmd)

  ;; compatibility
  (setq treemacs-user-mode-line-format nil)

  (advice-remove #'anzu--cons-mode-line 'mini-modeline--anzu--cons-mode-line)
  (advice-remove #'anzu--reset-mode-line 'mini-modeline--anzu--reset-mode-line)

  (advice-remove #'read-key-sequence 'mini-modeline--read-key-sequence)
  (advice-remove #'read-key-sequence-vector 'mini-modeline--read-key-sequence-vector))


;;;###autoload
(define-minor-mode mini-modeline-mode
  "Enable modeline in minibuffer."
  :init-value nil
  :global t
  :group 'mini-modeline
  :lighter " Minimode"
  (if mini-modeline-mode
      (mini-modeline--enable)
    (mini-modeline--disable)))

(provide 'mini-modeline)
;;; mini-modeline.el ends here
