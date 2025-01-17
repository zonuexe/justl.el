;;; justl.el --- Major mode for driving just files -*- lexical-binding: t; -*-

;; Copyright (C) 2021, Sibi Prabakaran

;; This file is NOT part of Emacs.

;; This  program is  free  software; you  can  redistribute it  and/or
;; modify it  under the  terms of  the GNU  General Public  License as
;; published by the Free Software  Foundation; either version 2 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT  ANY  WARRANTY;  without   even  the  implied  warranty  of
;; MERCHANTABILITY or FITNESS  FOR A PARTICULAR PURPOSE.   See the GNU
;; General Public License for more details.

;; You should have  received a copy of the GNU  General Public License
;; along  with  this program;  if  not,  write  to the  Free  Software
;; Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
;; USA

;; Version: 0.2
;; Author: Sibi Prabakaran
;; Keywords: just justfile tools processes
;; URL: https://github.com/psibi/justl
;; License: GNU General Public License >= 3
;; Package-Requires: ((transient "0.1.0") (emacs "25.3") (xterm-color "2.0") (s "1.2.0") (f "0.20.0"))

;;; Commentary:

;; Emacs extension for driving just files
;;
;; To list all the recipes present in your justfile, call
;;
;; M-x justl
;;
;; You don't have to call it from the actual justfile.  Calling it from
;; the directory where the justfile is present should be enough.
;;
;; Alternatively, if you want to just execute a recipe, call
;;
;; M-x justl-execute-recipe-in-dir
;;
;;; Shortcuts:

;; On the just screen, place your cursor on a recipe
;;
;; h => help popup
;; ? => help popup
;; g => refresh
;; e => execute recipe

;;; Customize:

;; By default, justl searches the executable named `just`, you can
;; change the `justl-executable` variable to set any explicit path.
;;
;; You can also control the width of the RECIPE column in the justl
;; buffer via `justl-recipe width`. By default it has a value of 20.

;;; Code:

(require 'transient)
(require 'cl-lib)
(require 'xterm-color)
(require 's)
(require 'f)

(defgroup justl nil
  "Justfile customization group"
  :group 'languages
  :prefix "justl-"
  :link '(url-link :tag "Site" "https://github.com/psibi/justl.el")
  :link '(url-link :tag "Repository" "https://github.com/psibi/justl.el"))

(defcustom justl-executable "just"
  "Location of just executable."
  :type 'file
  :group 'justl
  :safe 'stringp)

(defcustom justl-recipe-width 20
  "Width of the recipe column."
  :type 'integer
  :group 'justl)

(cl-defstruct justl-jrecipe name args)
(cl-defstruct justl-jarg arg default)

(defun justl--jrecipe-has-args-p (jrecipe)
  "Check if JRECIPE has any arguments."
  (justl-jrecipe-args jrecipe))

(defun justl--util-maybe (maybe default)
  "Return the DEFAULT value if MAYBE is null.

Similar to the fromMaybe function in the Haskell land."
  (if (null maybe)
  default
  maybe))

(defun justl--arg-to-str (jarg)
  "Convert JARG to just's positional argument."
  (format "%s=%s"
          (justl-jarg-arg jarg)
          (justl--util-maybe (justl-jarg-default jarg) "")))

(defun justl--jrecipe-get-args (jrecipe)
  "Convert JRECIPE arguments to list of positional arguments."
  (let* ((recipe-args (justl-jrecipe-args jrecipe))
         (args (justl--util-maybe recipe-args (list))))
    (mapcar #'justl--arg-to-str args)))

(defun justl--process-error-buffer (process-name)
  "Return the error buffer name for the PROCESS-NAME."
  (format "*%s:err*" process-name))

(defun justl--pop-to-buffer (name)
  "Utility function to pop to buffer or create it.

NAME is the buffer name."
  (unless (get-buffer name)
    (get-buffer-create name))
  (pop-to-buffer-same-window name))

(defvar justl--last-command nil)

(defconst justl--process-buffer "*just-process*"
  "Just process buffer name.")

(defun justl--is-variable-p (str)
  "Check if string STR is a just variable."
  (s-contains? ":=" str))

(defun justl--is-recipe-line-p (str)
  "Check if string STR is a recipe line."
  (let* ((string (justl--util-maybe str "")))
    (if (string-match "\\`[ \t\n\r]+" string)
        nil
      (and (not (justl--is-variable-p string))
           (s-contains? ":" string)))))

(defun justl--append-to-process-buffer (str)
  "Append string STR to the process buffer."
  (with-current-buffer (get-buffer-create justl--process-buffer)
    (read-only-mode -1)
    (goto-char (point-max))
    (insert (format "%s\n" str))))

(defun justl--find-justfiles (dir)
  "Find all the justfiles inside a directory.

DIR represents the directory where search will be carried
out.  The search will be performed recursively."
  (f-files dir (lambda (file)
                 (or
                  (cl-equalp "justfile" (f-filename file))
                  (cl-equalp ".justfile" (f-filename file))))
           t))

(defun justl--get-recipe-name (str)
  "Compute the recipe name from the string STR."
  (let ((trim-str (s-trim str)))
    (if (s-contains? " " trim-str)
        (car (split-string trim-str " "))
      trim-str)))

(defun justl--arg-to-jarg (str)
  "Convert single positional argument string STR to JARG."
  (let* ((arg (s-split "=" str)))
    (make-justl-jarg :arg (nth 0 arg) :default (nth 1 arg))))

(defun justl--str-to-jarg (str)
  "Convert string STR to liat of JARG.

The string after the recipe name and before the build constraints
is expected."
  (if (and (not (s-blank? str)) str)
      (let* ((args (s-split " " str)))
        (mapcar #'justl--arg-to-jarg args))
      nil))


(defun justl--parse-recipe (str)
  "Parse a entire recipe line.

STR represents the full recipe line.  Retuns JRECIPE."
  (let*
      ((recipe-list (s-split ":" str))
       (recipe-command (justl--get-recipe-name (nth 0 recipe-list)))
       (args-str (string-join (cdr (s-split " " (nth 0 recipe-list))) " "))
       (recipe-jargs (justl--str-to-jarg args-str)))
    (make-justl-jrecipe :name recipe-command :args recipe-jargs)))

(defun justl--log-command (process-name cmd)
  "Log the just command to the process buffer.

PROCESS-NAME is the name of the process.
CMD is the just command as a list."
  (let ((str-cmd (if (equal 'string (type-of cmd)) cmd (mapconcat #'identity cmd " "))))
    (setq justl--last-command str-cmd)
    (justl--append-to-process-buffer
     (format "[%s]\ncommand: %s" process-name str-cmd))))

(defun justl--sentinel (process _)
  "Sentinel function for PROCESS."
  (let ((process-name (process-name process))
        (exit-status (process-exit-status process)))
    (justl--append-to-process-buffer (format "[%s]\nexit-code: %s" process-name exit-status))
    (unless (eq 0 exit-status)
       (let ((err (with-current-buffer (justl--process-error-buffer process-name)
                 (buffer-string))))
      (justl--append-to-process-buffer (format "error: %s" err))
      (error "Just process %s error: %s" process-name err)))))

(defun justl--xterm-color-filter (proc string)
  "Filter function for PROC handling colors.

STRING is the data returned by the PROC"
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((moving (= (point) (process-mark proc))))
        (save-excursion
          ;; Insert the text, advancing the process marker.
          (goto-char (process-mark proc))
          (insert (xterm-color-filter string))
          (set-marker (process-mark proc) (point)))
        (if moving (goto-char (process-mark proc)))))))

(defun justl--exec (process-name args)
  "Utility function to run commands in the proper context and namespace.

PROCESS-NAME is an identifier for the process.  Default to \"just\".
ARGS is a ist of arguments."
  (when (equal process-name "")
    (setq process-name "just"))
  (let ((buffer-name (format "*%s*" process-name))
        (error-buffer (justl--process-error-buffer process-name))
        (cmd (append (list justl-executable) args)))
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (when (get-buffer error-buffer)
      (kill-buffer error-buffer))
    (justl--log-command process-name cmd)
    (make-process :name process-name
                  :buffer buffer-name
                  :filter 'justl--xterm-color-filter
                  :sentinel #'justl--sentinel
                  :file-handler t
                  :stderr nil
                  :command cmd)
    (pop-to-buffer buffer-name)))

(defun justl--exec-to-string (cmd)
  "Replace \"shell-command-to-string\" to log to process buffer.

CMD is the command string to run."
  (justl--log-command "just-command" cmd)
  (shell-command-to-string cmd))

(defun justl--get-recipies ()
  "Return all the recipies."
  (let ((recipies (split-string (justl--exec-to-string
                                 (format "%s --summary --unsorted"
                                         justl-executable)))))
    (mapcar #'string-trim-right recipies)))

(defun justl--get-recipies-with-desc ()
  "Return all the recipies with description."
  (let* ((recipe-lines (split-string
                        (justl--exec-to-string
                         (format "%s --list --unsorted"
                                 justl-executable))
                        "\n"))
         (recipes (mapcar (lambda (x) (split-string x "# "))
                       (cdr (seq-filter (lambda (x) (s-present? x)) recipe-lines)))))
    (mapcar (lambda (x) (list (justl--get-recipe-name (nth 0 x)) (nth 1 x))) recipes)))

(defun justl--get-jrecipies ()
  "Return list of JRECIPE."
  (let ((recipies (justl--get-recipies)))
    (mapcar #'make-justl-jrecipe recipies)))

(defun justl--list-to-jrecipe (list)
  "Convert a single LIST of two elements to list of JRECIPE."
  (make-justl-jrecipe :name (nth 0 list) :args (nth 1 list)))

(defun justl-exec-recipe-in-dir ()
  "Populate and execute the selected recipe."
  (interactive)
  (let* ((recipies (completing-read "Recipies: " (justl--get-recipies)
                                     nil nil nil nil "default")))
    (justl--exec "just" (list recipies))))

(defvar justl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "l") 'justl-list-recipies)
    (define-key map (kbd "g") 'justl)
    (define-key map (kbd "e") 'justl-exec-recipe)
    (define-key map (kbd "?") 'justl-help-popup)
    (define-key map (kbd "h") 'justl-help-popup)
    map)
  "Keymap for `justl-mode'.")

(defun justl--buffer-name ()
  "Return justl buffer name."
  (format "*just [%s]"
          default-directory))

(defvar justl--line-number nil
  "Store the current line number to jump back after a refresh.")

(defun justl--save-line ()
  "Save the current line number if the view is unchanged."
  (if (equal (buffer-name (current-buffer))
             (justl--buffer-name))
      (setq justl--line-number (+ 1 (count-lines 1 (point))))
    (setq justl--line-number nil)))

(defun justl--tabulated-entries (recipies)
  "Turn RECIPIES to tabulated entries."
  (mapcar (lambda (x)
               (list nil (vector (nth 0 x) (justl--util-maybe (nth 1 x) ""))))
       recipies))

(define-transient-command justl-help-popup ()
  "Justl Menu"
  [["Arguments"
    ("-c" "Clear shell arguments" "--clear-shell-args")
    ("-d" "Dry run" "--dry-run")
    ("-e" "Disable .env file" "--no-dotenv")
    ("-h" "Highlight" "--highlight")
    ("-n" "Disable Highlight" "--no-highlight")
    ("-q" "Quiet" "--quiet")
    ("-v" "Verbose output" "--verbose")
    ]
   ["Actions"
    ;; global
    ("g" "Refresh" justl)
    ("e" "Exec" justl-exec-recipe)]
   ])

(defun justl--get-recipe-from-file (filename recipe)
  "Get specific RECIPE from the FILENAME."
  (let* ((jcontent (f-read-text filename))
         (recipe-lines (split-string jcontent "\n"))
         (all-recipe (seq-filter #'justl--is-recipe-line-p recipe-lines))
         (current-recipe (seq-filter (lambda (x) (s-contains? recipe x)) all-recipe)))
    (justl--parse-recipe (car current-recipe))))

(defun justl-exec-recipe ()
  "Execute just recipe."
  (interactive)
  (let* ((recipe (justl--get-word-under-cursor))
         (justfile (justl--find-justfiles default-directory))
         (justl-recipe (justl--get-recipe-from-file (car justfile) recipe))
         (t-args (transient-args 'justl-help-popup))
         (recipe-has-args (justl--jrecipe-has-args-p justl-recipe)))
    (if recipe-has-args
        (let* ((cmd-args (justl--jrecipe-get-args justl-recipe))
               (user-args (read-from-minibuffer "Just args: " (string-join cmd-args " "))))
          (justl--exec "just"
                       (append t-args
                               (cons (justl-jrecipe-name justl-recipe)
                                     (split-string user-args " ")))))
      (justl--exec "just" (append t-args (list recipe))))))

(defun justl--get-word-under-cursor ()
  "Utility function to get the name of the recipe under the cursor."
  (replace-regexp-in-string
   "^" "" (aref (tabulated-list-get-entry) 0)))

(defun justl--jump-back-to-line ()
  "Jump back to the last cached line number."
  (when justl--line-number
    (goto-char (point-min))
    (forward-line (1- justl--line-number))))

;;;###autoload
(defun justl ()
  "Invoke the justl buffer."
  (interactive)
  (justl--save-line)
  (justl--pop-to-buffer (justl--buffer-name))
  (justl-mode))

(define-derived-mode justl-mode tabulated-list-mode  "Justl"
  "Special mode for justl buffers."
  (buffer-disable-undo)
  (setq truncate-lines t)
  (let ((justfiles (justl--find-justfiles default-directory))
        (entries (justl--get-recipies-with-desc)))
    (if (null justfiles)
        (message "No justfiles found")
      (setq tabulated-list-format
            (vector (list "RECIPIES" justl-recipe-width t)
                    (list "DESCRIPTION" 20 t)))
      (setq tabulated-list-entries (justl--tabulated-entries entries))
      (setq tabulated-list-sort-key nil)
      (tabulated-list-init-header)
      (tabulated-list-print t)
      (hl-line-mode 1)
      (message (concat "Just: " default-directory))
      (justl--jump-back-to-line))))

(provide 'justl)
;;; justl.el ends here
