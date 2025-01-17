
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%                                                                             %
% This file is part of ScholarLY,                                             %
%                      =========                                              %
% a toolkit library for scholarly work with GNU LilyPond and LaTeX,           %
% belonging to openLilyLib (https://github.com/openlilylib/openlilylib        %
%              -----------                                                    %
%                                                                             %
% ScholarLY is free software: you can redistribute it and/or modify           %
% it under the terms of the GNU General Public License as published by        %
% the Free Software Foundation, either version 3 of the License, or           %
% (at your option) any later version.                                         %
%                                                                             %
% ScholarLY is distributed in the hope that it will be useful,                %
% but WITHOUT ANY WARRANTY; without even the implied warranty of              %
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the               %
% GNU Lesser General Public License for more details.                         %
%                                                                             %
% You should have received a copy of the GNU General Public License           %
% along with ScholarLY.  If not, see <http://www.gnu.org/licenses/>.          %
%                                                                             %
% ScholarLY is maintained by Urs Liska, ul@openlilylib.org                    %
% Copyright Urs Liska, 2015                                                   %
%                                                                             %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%{
  \annotate - main file
  This file contains the "collector" and "processor" engravers for annotations
  and the interface music functions to enter annotations in LilyPond input files.
  TODO:
  - generate clickable links when writing to file
  - enable the music function to apply editorial functions
    to the affected grob (e.g. dashing slurs, parenthesizing etc.).
    This has to be controlled by extra annotation properties
    and be configurable to a high degree (this is a major task).
  - provide an infrastructure for custom annotation types
%}

\version "2.19.22"

\loadModule scholarly.annotate.common

% Include `editorial-functions` module
%\include "../editorial-functions/__main__.ily"
\loadModule scholarly.editorial-functions

#(define annotate
   (define-music-function (name properties type item mus)
     ((symbol-list?) ly:context-mod? symbol? symbol-list-or-music? (ly:music?))
     ;; generic (internal only) function to annotate a score item
     (let*
      ( ;; process context-mod with footnote settings
        (props (context-mod->props properties))
        ;; retrieve a pair with containing directory and input file
        (input-file (string-split (car (ly:input-file-line-char-column (*location*))) #\/ ))
        (ctx
         (if (= 1 (length input-file))
             ;; relative path to current directory => no parent available
             ;; solution: take the last element of the current working directory
             (cons (last (os-path-cwd-list)) (last input-file))
             ;; absolute path, take second-to-last element
             (list-tail input-file (- (length input-file) 2))))
        ;; extract directory name (-> part/voice name)
        (input-directory (car ctx))
        ;; extract segment name
        ; currently this is still *with* the extension
        (input-file-name (cdr ctx)))
      ;; The "type" is passed as an argument from the wrapper functions
      ;; The symbol 'none refers to the generic \annotation function. In this case
      ;; we don't set a type at all to ensure proper predicate checking
      ;; (the annotation must then have an explicit 'type' property passed in
      ;; the properties argument)
      (if (not (eq? type 'none))
          (begin
           (set! props (assq-set! props 'type type))
           ;
           ; NOTE: This is temporary, to accomodate changes in the
           ; editorial-markup module
           ;
           (set! props (assq-set! props 'ann-type type))))
      ;; pass along the input location to the engraver
      (set! props (assq-set! props 'location (*location*)))
      ;; 'Context-id' property is the name of the musical context the annotation
      ;; references; initially set to name of enclosing directory.
      (set! props (assq-set! props 'context-id input-directory))
      ; Input file name is not used so far (was a remnant of the Oskar Fried
      ; project). As this may become useful one day we'll keep it here.
      (set! props (assq-set! props 'input-file-name input-file-name))
      ;; Check if valid annotation, then process
      (if (alist? props)
          ;; Apply annotation object as override, depending on input syntax
          (let*
           ((col (getChildOption '(scholarly annotate colors) type))
            (tweak-command
             (cond
              ((and (ly:music? item) (symbol-list? name))
               ;; item is music, name specifies grob: annotate the grob
               #{
                 \tweak #`(,name input-annotation) #props #item
                 \tweak #`(name color) #col #item
               #})
              ((ly:music? item)
               ;; item is music: annotate the music (usually the NoteHead)
               #{
                 \tweak #'input-annotation #props #item
                 \tweak  #'color #col #item
               #})
              (else
               ;; item is symbol list: annotate the next item of the given grob name
               #{
                 \once \override #item . input-annotation = #props
                 \once \override #item . color = #col
               #}))))
           #{
             #tweak-command
             #(if (assq-ref props 'footnote-offset)
                  ;; we want a footnote:
                  (begin
                   (if (not (assq-ref props 'footnote-text))
                       (set! props (assoc-set! props 'footnote-text
                                     (assq-ref props 'message))))
                   (let ((offset (assq-ref props 'footnote-offset))
                         (text (assq-ref props 'footnote-text)))
                     #{ \footnote #offset #text #item #})))
             #(if (assq-ref props 'balloon-offset)
                  ;; we want balloon text:
                  (let* ((grob (list-ref item 0))
                         (description (assoc-get grob all-grob-descriptions)))
                    (if (member 'spanner-interface
                          (assoc-get 'interfaces (assoc-get 'meta description)))
                        ;; the grob is a spanner, so cancel the balloon
                        (oll:warn "We can't give engrave balloon text to spanners yet. Balloon ignored for ~a" grob)
                        (begin
                         (if (not (assq-ref props 'balloon-text))
                             (set! props (assoc-set! props 'balloon-text
                                           (assq-ref props 'message))))
                         (let ((offset (assq-ref props 'balloon-offset))
                               (text (assq-ref props 'balloon-text)))
                           #{ \balloonGrobText #grob #offset \markup { #text } #})))))
             #(if
               ;; `apply` property is set; apply editorial function
               (assq-ref props 'apply)
               (let ((edition (string->symbol (assoc-ref props 'apply))))
                 (editorialFunction edition item mus))
               mus) #})
          (begin
           (ly:input-warning (*location*) "Improper annotation. Maybe there are mandatory properties missing?")
           #{ #})))))


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%% Public interface
%%%% Define one generic command \annotation
%%%% and a number of wrapper functions for different annotation types
%
% Annotations may have an arbitrary number of key=value properties,
% some of them being recognized by the system.
% A 'message' property is mandatory for all annotation types.

annotation =
% Generic annotation, can be used to "create" custom annotation types
% Note: a 'type' property is mandatory for this command
#(define-music-function (name properties item mus)
   ((symbol-list?) ly:context-mod? symbol-list-or-music? (ly:music?))
   (if (symbol? name)
       (annotate name properties 'none item mus)
       (annotate properties 'none item mus)))

criticalRemark =
% Final annotation about an editorial decision
#(define-music-function (name properties item mus)
   ((symbol-list?) ly:context-mod? symbol-list-or-music? (ly:music?))
   (if (symbol? name)
       (annotate name properties 'critical-remark item mus)
       (annotate properties 'critical-remark item mus)))

lilypondIssue =
% Annotate a LilyPond issue that hasn't been resolved yet
#(define-music-function (name properties item mus)
   ((symbol-list?) ly:context-mod? symbol-list-or-music? (ly:music?))
   (if (symbol? name)
       (annotate name properties 'lilypond-issue item mus)
       (annotate properties 'lilypond-issue item mus)))

musicalIssue =
% Annotate a musical issue that hasn't been resolved yet
#(define-music-function (name properties item mus)
   ((symbol-list?) ly:context-mod? symbol-list-or-music? (ly:music?))
   (if (symbol? name)
       (annotate name properties 'musical-issue item mus)
       (annotate properties 'musical-issue item mus)))

question =
% Annotation about a general question
#(define-music-function (name properties item mus)
   ((symbol-list?) ly:context-mod? symbol-list-or-music? (ly:music?))
   (if (symbol? name)
       (annotate name properties 'question item mus)
       (annotate properties 'question item mus)))

todo =
% Annotate a task that *has* to be finished
#(define-music-function (name properties item mus)
   ((symbol-list?) ly:context-mod? symbol-list-or-music? (ly:music?))
   (if (symbol? name)
       (annotate name properties 'todo item mus)
       (annotate properties 'todo item mus)))

