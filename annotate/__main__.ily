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

\version "2.17.18"

% Global object storing all annotations
#(define annotations '())

% Include factored out functionality
\include "config.ily"
%TODO: This seems problematic:
\include "utility/rhythmic-location.ily"

\include "sort.ily"
\include "format.ily"
\include "export.ily"
\include "export-latex.ily"
\include "export-plaintext.ily"

% Define a lookup list for existing export procedures.
% While this might be expected to be defined in the configuration
% file it has to be inserted *after* the procedures have been defined
#(define export-routines
   `(("latex" . ,export-annotations-latex)
     ("plaintext" . ,export-annotations-plaintext)))


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%% Helper functions to manage the annotation objects

% Predicate: an annotation is an alist that at least contains a number of
% default keys (which should usually be generated by the \annotate music function)
#(define (input-annotation? obj)
   (and
    (list? obj)
    (every pair? obj)
    (assoc-ref obj "message")
    (assoc-ref obj "type")
    (assoc-ref obj "location")))

% Retrieve the grob name from the annotation (provided by Harm)
% From LilyPond 2.19.16 onwards one can use (grob::name grob) instead
#(define grob-name
   (lambda (x)
     (if (ly:grob? x)
         (assq-ref (ly:grob-property x 'meta) 'name)
         (ly:error "~a is not a grob" x))))

% Create custom property 'annotation
% to pass information from the music function to the engraver
#(set-object-property! 'input-annotation 'backend-type? input-annotation?)
#(set-object-property! 'input-annotation 'backend-doc "custom grob property")


%%%%%%%%%%%%%%%%%%%%%
% Annotation engraver
% - Originally provided by David Nalesnik
% - Adapted to the existing \annotation function by Urs Liska

% Collector acknowledges annotations and appends them
% to the global annotations object
annotationCollector =
#(lambda (context)
   (let* ((grobs '()))
     (make-engraver
      ;; receive grobs with annotations, set a few more properties
      ;; and append annotation objects to the global annotations list
      (acknowledgers
       ((grob-interface engraver grob source-engraver)
        (let ((annotation (ly:grob-property grob 'input-annotation)))
          ;; A grob is to be accepted when 'annotation *does* have some content
          (if (and (not (null-list? annotation))
                   ;; filter annotations the user has excluded
                   (not (member
                         (assoc-ref annotation "type")
                         #{ \getOption scholarly.annotate.ignored-types #})))
              ;; add more properties that are only now available
              (begin
               (if #{ \getOption scholarly.colorize #}
                   ;; colorize grob, retrieving color from sub-option
                   (set! (ly:grob-property grob 'color)
                         #{ \getChildOption
                            scholarly.annotate.colors
                            #(assoc-ref annotation "type") #}))
               (if (or
                    #{ \getOption scholarly.annotate.print #}
                    (not (null? #{ \getOption scholarly.annotate.export-targets #} )))
                   ;; only add to the list of grobs in the engraver
                   ;; when we actually process them afterwards
                   (let ((ctx-id
                          ;; Set ctx-id to
                          ;; a) an explicit context name defined or
                          ;; b) an implicit context name through the named Staff context or
                          ;; c) the directory name (as determined in the \annotate function)
                          (or (assoc-ref annotation "context")
                              (let ((actual-context-id (ly:context-id context)))
                                (if (not (string=? actual-context-id "\\new"))
                                    actual-context-id
                                    #f))
                              (assoc-ref annotation "context-id"))))
                     ;; Look up a context-name label from the options if one is set,
                     ;; otherwise use the retrieved context-name.
                     (set! annotation
                           (assoc-set! annotation
                             "context-id"
                             #{ \getChildOptionWithFallback
                                scholarly.annotate.context-names
                                #(string->symbol ctx-id)
                                #ctx-id #}))
                     ;; Get the name of the annotated grob type
                     (set! annotation
                           (assoc-set! annotation "grob-type"
                             (if (lilypond-greater-than-or-equal? "2.19.16")
                                 ;; use built-in function
                                 (grob::name grob)
                                 ;; use custom function from above
                                 (grob-name grob))))
                     ;; Initialize a 'grob-location' property as a sub-alist,
                     ;; for now with a 'meter' property. This will be populated in 'finalize'.
                     (set! annotation
                           (assoc-set! annotation "grob-location"
                             (assoc-set! '() "meter"
                               (ly:context-property context 'timeSignatureFraction))))
                     (set! grobs (cons (list grob annotation) grobs)))))))))

      ;; Iterate over collected grobs and produce a list of annotations
      ;; (when annotations are neither printed nor logged the list is empty).
      ((finalize trans)
       (begin
        (for-each
         (lambda (g)
           (let* ((annotation (last g)))
             ;; Add location info, which seems only possible here
             (set! annotation (assoc-set! annotation "grob" (first g)))

             ;; retrieve rhythmical properties of the grob and
             ;; store them in 'grob-location' alist
             (set! annotation
                   (assoc-set! annotation "grob-location"
                     (grob-location-properties
                      (first g)
                      (assoc-ref annotation "grob-location"))))

             ;; add current annotation to the list of annotations
             (set! annotations (append annotations (list annotation)))))
         (reverse grobs)))))))


% When the score is finalized this engraver
% processes the list of annotations and produces
% appropriate output.
annotationProcessor =
#(lambda (context)
   (make-engraver
    ((finalize trans)
     ;; Sort annotations by the given criteria
     (for-each
      (lambda (s)
        (set! annotations
              (sort-annotations annotations
                (assoc-ref annotation-comparison-predicates s))))
      (reverse #{ \getOption scholarly.annotate.sort-criteria #}))

     ;; Optionally print annotations
     (if #{ \getOption scholarly.annotate.print #}
         (do-print-annotations))
     ;; Export iterating over all entries in the
     ;; annotation-export-targets configuration list
     (for-each
      (lambda (t)
        (let
         ((er (assoc-ref export-routines t)))
         ;; skip invalid entries
         (if er
             (er)
             (ly:warning (format "Invalid annotation export target: ~a" t)))))
      #{ \getOption scholarly.annotate.export-targets #}))))

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

#(define (list-or-symbol? obj)
   (or (list? obj)
       (symbol? obj)))


annotate =
#(define-music-function (parser location name properties type item)
   ((symbol?) ly:context-mod? list-or-symbol? symbol-list-or-music?)
   ;; annotates a musical object for use with lilypond-doc

   (let*
    ( ;; create empty alist to hold the annotation
      (props '())
      ;; retrieve a pair with containing directory and input file
      (input-file (string-split (car (ly:input-file-line-char-column location)) #\/ ))
      (ctx (list-tail input-file (- (length input-file) 2)))
      ;; extract directory name (-> part/voice name)
      (input-directory (car ctx))
      ;; extract segment name
      ; currently this is still *with* the extension
      (input-file-name (cdr ctx)))

    ;; The "type" is passed as an argument from the wrapper functions
    ;; An empty string refers to the generic \annotation function. In this case
    ;; we don't set a type at all to ensure proper predicate checking
    ;; (the annotation must then have an explicit 'type' property)
    (if (symbol? type)
        (set! props (assoc-set! props "type" type)))

    ;; Add or replace props entries taken from the properties argument
    (for-each
     (lambda (mod)
       (set! props
             (assoc-set! props
               (symbol->string (cadr mod)) (caddr mod))))
     (ly:get-context-mods properties))

    ;; pass along the input location to the engraver
    (set! props (assoc-set! props "location" location))

    ;; The 'context-id' property is the name of the musical context
    ;; the annotation refers to. As our fallthrough solution we
    ;; initially set this to the name of the enclosing directory
    (set! props (assoc-set! props "context-id" input-directory))

    ; The input file name is not used so far (as it was a remnant of
    ; the Oskar Fried project). As this may become useful for somebody
    ; one day we'll keep it here.
    (set! props (assoc-set! props "input-file-name" input-file-name))

    ;; Check if we do have a valid annotation,
    ;; then process it.
    (if (input-annotation? props)
        ;; Apply the annotation object as an override, depending on the input syntax
        (cond
         ((and (ly:music? item) (symbol? name))
          ;; item is music and name directs to a specific grob
          ;; annotate the named grob
          #{
            \tweak #`(,name input-annotation) #props #item
          #})
         ((ly:music? item)
          ;; item is music
          ;; -> annotate the music item (usually the NoteHead)
          #{
            \tweak #'input-annotation #props #item
          #})
         (else
          ;; item is a symbol list (i.e. grob name)
          ;; -> annotate the next item of the given grob name
          #{
            \once \override #item #'input-annotation = #props
          #}))
        (begin
         (ly:input-warning location "Improper annotation. Maybe there are mandatory properties missing?")
         #{ #}))))



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
#(define-music-function (parser location name properties item)
   ((symbol?) ly:context-mod? symbol-list-or-music?)
   (if (symbol? name)
       #{ \annotate
          #name
          #properties
          #'()
          #item #}
       #{ \annotate
          #properties
          #'()
          #item #}))

criticalRemark =
% Final annotation about an editorial decision
#(define-music-function (parser location name properties item)
   ((symbol?) ly:context-mod? symbol-list-or-music?)
   (if (symbol? name)
       #{ \annotate
          #name
          #properties
          #'critical-remark
          #item #}
       #{ \annotate
          #properties
          #'critical-remark
          #item #}))

lilypondIssue =
% Annotate a LilyPond issue that hasn't been resolved yet
#(define-music-function (parser location name properties item)
   ((symbol?) ly:context-mod? symbol-list-or-music?)
   (if (symbol? name)
       #{ \annotate
          #name
          #properties
          #'lilypond-issue
          #item #}
       #{ \annotate
          #properties
          #'lilypond-issue
          #item #}))

musicalIssue =
% Annotate a musical issue that hasn't been resolved yet
#(define-music-function (parser location name properties item)
   ((symbol?) ly:context-mod? symbol-list-or-music?)
   (if (symbol? name)
       #{ \annotate
          #name
          #properties
          #'musical-issue
          #item #}
       #{ \annotate
          #properties
          #'musical-issue
          #item #}))

question =
% Annotation about a general question
#(define-music-function (parser location name properties item)
   ((symbol?) ly:context-mod? symbol-list-or-music?)
   (if (symbol? name)
       #{ \annotate
          #name
          #properties
          #'question
          #item #}
       #{ \annotate
          #properties
          #'question
          #item #}))

todo =
% Annotate a task that *has* to be finished
#(define-music-function (parser location name properties item)
   ((symbol?) ly:context-mod? symbol-list-or-music?)
   (if (symbol? name)
       #{ \annotate
          #name
          #properties
          #'todo
          #item #}
       #{ \annotate
          #properties
          #'todo
          #item #}))



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%% Set default integration in the layout contexts.
%%%% All settings can be overridden in individual scores.

\layout {
  % In each Staff-like context an annotation collector
  % parses annotations and appends them to the global
  % annotations object.
  \context {
    \Staff
    \consists \annotationCollector
  }
  \context {
    \DrumStaff
    \consists \annotationCollector
  }
  \context {
    \RhythmicStaff
    \consists \annotationCollector
  }
  \context {
    \TabStaff
    \consists \annotationCollector
  }
  \context {
    \GregorianTranscriptionStaff
    \consists \annotationCollector
  }
  \context {
    \MensuralStaff
    \consists \annotationCollector
  }
  \context {
    \VaticanaStaff
    \consists \annotationCollector
  }
  \context {
    \Dynamics
    \consists \annotationCollector
  }
  \context {
    \Lyrics
    \consists \annotationCollector
  }
  \context {
    \Score
    % The annotation processor living in the Score context
    % processes the annotations and outputs them to different
    % targets.
    \consists \annotationProcessor
  }
}

