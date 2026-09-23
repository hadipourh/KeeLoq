\def\fileversion{0.78}
\def\filedate{2025/12/29}

\NeedsTeXFormat{LaTeX2e}[1995/12/01]
\typeout{^^J  ***  LaTeX class for IACR Communications in Cryptology v\fileversion\space ***^^J}
\ProvidesClass{iacrcc}[\filedate]

% IACR Communications in Cryptology DOCUMENT CLASS
% Authoritative source is github.com/IACR/latex/iacrcc
%
% To the extent possible under law, the author(s) have dedicated all
% copyright and related and neighboring rights to this software to the
% public domain worldwide. This software is distributed without any
% warranty.
%
% You should have received a copy of the CC0 Public Domain Dedication
% along with this software. If not, see
% <http://creativecommons.org/publicdomain/zero/1.0/>.
%
% Common definitions

% This is used to make the latex log easier to parse and keep track of
% the current file for error reporting.
\RequirePackage[abspath=true]{currfile}
% \currfileabspath is sometimes empty when \RequirePackage is called
% from inside a package included with \RequirePackage under lualatex,
% but currfilepath is always present (but may not be unique).
\AtBeginOfFiles{\ifx\currfileabspath\empty%
  \wlog{iacrcc:opened as \currfilepath}%
  \else%
  \wlog{iacrcc:opened with \currfileabspath}%
  \fi}
\AtEndOfFiles{\ifx\currfileabspath\empty%
  \wlog{iacrcc:closed as \currfilepath}
  \else%
  \wlog{iacrcc:closed with \currfileabspath}%
  \fi}

% expl3: wrapper package for experimental LaTeX3
\RequirePackage{expl3} % used for text_purify on metadata.

% xkeyval: extension of the keyval package
%          This offers additional macros for setting keys and
%          declaring and setting class or package options.
\RequirePackage{xkeyval}

\def\publname{IACR Communications in Cryptology}
\def\IACR@vol{0}
\def\IACR@no{0}
\def\IACR@fp{1}
\def\IACR@EISSN{}
\def\IACR@DOI{}
\def\IACR@CROSSMARKURL{}
\global\let\IACR@Received\@empty
\global\let\IACR@Accepted\@empty

% etoolbox: is a toolbox of programming facilities geared primarily
%           towards LaTeX class and package authors.
\RequirePackage{etoolbox}

% See https://www.latex-project.org/news/latex2e-news/ltnews34.pdf
\tracinglostchars=3

% Options
% The jobname.iacrmetadata file will contain
% \IACR@Received, \IACR@Accepted, and \IACR@DOI.
\InputIfFileExists{\jobname.iacrmetadata}{
  \typeout{Inserted DOI into PDF}%
}{}
\newif\if@optbiblatex
\@optbiblatexfalse
\DeclareOptionX<IACR>{biblatex}{\@optbiblatextrue}
\newif\if@floatrow
\@floatrowfalse
\DeclareOptionX<IACR>{floatrow}{\@floatrowtrue}
% version=submission will set anonymous to true, but it can be
% overridden with the notanonymous option for the class.
\newif\if@anonymous
\@anonymousfalse
% This maybe be used to override \@anonymous
\newif\if@notanonymous
\@notanonymousfalse
\DeclareOptionX<IACR>{notanonymous}{\@notanonymoustrue}
\newcommand{\@IACRversion}{preprint}
\define@choicekey{IACR}{version}[\@IACRversion]{preprint,submission,final}[preprint]{}
\DeclareOptionX*{}
\ProcessOptionsX<IACR>\relax
\typeout{Compiling version=\@IACRversion}
\ifcsstring{@IACRversion}{submission}{
  \if@notanonymous\@anonymousfalse
    \typeout{Disabling anonymity}
  \else
    \@anonymoustrue
    \typeout{Setting to anonymous}
  \fi
}{}
\ifcsstring{@IACRversion}{final}{
  % This disabled boxes for overfull hboxes.
  \PassOptionsToClass{final}{article}
}{}

% xstring: provides macros for manipulating strings - testing a string’s
%          contents, extracting substrings, substitution of substrings and
%          providing numbers such as string length, position of, or number
%          of recurrences of, a substring.
\RequirePackage{xstring} % Required for IfSubStr

% Options containing an equality sign are deleted from the original list by
% the xkeyval package from the \@classoptionslist macro.
% Remove allowed options and check if this macro is empty.
\ifx\@classoptionslist\@empty\else
  \edef\store@classoptionslist{\@classoptionslist}%
  \StrDel{\store@classoptionslist}{floatrow}[\store@classoptionslist]%
  \StrDel{\store@classoptionslist}{biblatex}[\store@classoptionslist]%
  \StrDel{\store@classoptionslist}{notanonymous}[\store@classoptionslist]%
  \StrDel{\store@classoptionslist}{,}[\store@classoptionslist]%
  \StrDel{\store@classoptionslist}{ }[\store@classoptionslist]%
  \ifx\store@classoptionslist\@empty\else
    \ClassError{iacrcc}{Invalid options passed to iacrcc: \store@classoptionslist}{}%
  \fi
\fi

% article class
\LoadClass[10pt,twoside]{article}[2007/10/19]

% iftex: am I running under pdfTEX, XETEX or LuaTEX?
\RequirePackage{iftex}

\ifluatex
  % Check for existence of luatex85.sty and load it if available.
  % This should ensure that it work also with newer versions of luatex.
  % luatex85: The package provides emulation of pdfTEX primitives for LuaTEX v0.85+.
  \IfFileExists{luatex85.sty}{\RequirePackage{luatex85}}{}
\fi

\setcounter{tocdepth}{2}

\@ifpackageloaded{biblatex}{}{%
  \bibliographystyle{alphaurl}%
  \def\bibliographystyle#1{%
    \ClassError{iacrcc}{The bibliography style is set by iacrcc.cls and may not be changed by the author}{}%
  }}

\AtEndPreamble{%
  \@ifpackageloaded{natbib}{%
    \ClassError{iacrcc}{The natbib package is not supported}{}}{}
  \ifpdftex
    % TU encoding is only available with XeTeX and LuaTeX.
    % Defaulting to T1 encoding.
    % fontenc: Standard package for selecting font encodings
    \RequirePackage[T1]{fontenc}
  \fi
  % hyperref: Extensive support for hypertext in LaTeX
  % bookmarksopen: If Acrobat bookmarks are requested,
  %                show them with all the subtrees expanded
  % bookmarksopenlevel: parameter level to which bookmarks are open
  \RequirePackage[bookmarksopen=true,bookmarksopenlevel=2]{hyperref}
  %
  \if@anonymous
    \hypersetup{pdfauthor={hidden for submission}}
  \else
    \hypersetup{pdfauthor={\IACR@listofauthors}}
  \fi
  \hypersetup{pdflang=en,%
              urlcolor=blue,%
              colorlinks=true,%
              citecolor=black!70!green,%
              linkcolor=black!70!red%
             }
  \ifcsstring{@IACRversion}{final}{%
    \ifx\IACR@DOI\@empty%
      \hypersetup{pdfsubject={\publname}}%
    \else%
      \hypersetup{pdfsubject={\publname{}, DOI:\IACR@DOI}}%
    \fi%
  }{}% final
  % Disable latexdiff commands in PDF links
  \pdfstringdefDisableCommands{%
    \def\DIFadd#1{#1}%
    \def\DIFdel#1{}%
  }
  % When the ulem package is loaded make sure to enable \normalem:
  % this makes sure ulem does not replace italics with underlining
  % in text emphasized by \emph, and to some extent by \em
  \@ifpackageloaded{ulem}{\normalem}{}%
  % The hyperref package is used to handle cross-referencing commands in
  % LaTeX to produce hypertext links in the document. hyperref is fussy about
  % the order in which it is loaded, and the official documentation recommends
  % loading last. In spite of this, there are some packages that must be
  % loaded after hyperref. (e.g., cleveref). In order to support this, the
  % author should create a file called after-hyperref.sty with
  % \RequirePackage{cleveref} in it.
  \IfFileExists{after-hyperref.sty}{%
    \RequirePackage{after-hyperref}
  }{}
  \ifcsstring{@IACRversion}{final}{%
    % When compiling the final version we need the last page number
    % totpages: count pages in a document, and report last page number
    % The documentation recommends to load this package last.
    \RequirePackage{totpages}
  }{}% final
}

% The TotPages label is not defined until after the \begin{document}.
\AtBeginDocument{%
  \ifcsstring{@IACRversion}{final}{%
    \gdef\IACR@lp{\ref*{TotPages}}
  }{}% final
}

% Geometry: flexible and complete interface to document dimensions.
\RequirePackage[a4paper,hscale=0.65,vscale=0.75,marginratio=1:1,marginparwidth=2.7cm]{geometry}

% afterpage: execute command after the next page break
\RequirePackage{afterpage}

% Make some counters robust that are made fragile by `calc` needed for orcidlink
\robustify\setcounter
\robustify\addtocounter
\robustify\setlength
\robustify\addtolength

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% This provides a command to insert the ORCiD logo, which is hyperlinked to
% the URL of the researcher whose iD was specified.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% This copies over definition of the orcidlink from the orcidlink style file
% by by Leo C. Stein which in turn is a package around Milo's code on TeX.SE,
% see https://tex.stackexchange.com/a/445583/34063

% tikz: create PostScript and PDF graphics in TEX
\RequirePackage{tikz}
\ProcessOptions\relax
\usetikzlibrary{svg.path}

\definecolor{orcidlogocol}{HTML}{A6CE39}
\tikzset{%
  orcidlogo/.pic={%
    \fill[orcidlogocol] svg{M256,128c0,70.7-57.3,128-128,128C57.3,256,0,198.7,0,128C0,57.3,57.3,0,128,0C198.7,0,256,57.3,256,128z};
    \fill[white] svg{M86.3,186.2H70.9V79.1h15.4v48.4V186.2z}
                 svg{M108.9,79.1h41.6c39.6,0,57,28.3,57,53.6c0,27.5-21.5,53.6-56.8,53.6h-41.8V79.1z M124.3,172.4h24.5c34.9,0,42.9-26.5,42.9-39.7c0-21.5-13.7-39.7-43.7-39.7h-23.7V172.4z}
                 svg{M88.7,56.8c0,5.5-4.5,10.1-10.1,10.1c-5.6,0-10.1-4.6-10.1-10.1c0-5.6,4.5-10.1,10.1-10.1C84.2,46.7,88.7,51.3,88.7,56.8z};
  }%
}

% Reciprocal of the height of the svg for the ORCID icon above.  The
% original generates a 256pt high graphic; this macro holds 1/256.
\newcommand{\@OrigHeightRecip}{0.00390625}

% We will compute the current X height to make the logo the right height
\newlength{\@curXheight}

\DeclareRobustCommand\orcidlink[1]{%
  \texorpdfstring{%
    \setlength{\@curXheight}{\fontcharht\font`X}%
    \href{https://orcid.org/#1}{\XeTeXLinkBox{\mbox{%
    \begin{tikzpicture}[yscale=-\@OrigHeightRecip*\@curXheight,%
      xscale=\@OrigHeightRecip*\@curXheight,transform shape]%
      \pic{orcidlogo};
    \end{tikzpicture}%
}}}}{}}
% End of macros for orcidlink
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Macro for crossmark image.
\definecolor{c948f8f}{RGB}{148,143,143}
\definecolor{cd0d0d0}{RGB}{208,208,208}
\definecolor{ca0a0a0}{RGB}{192,192,192}
\definecolor{c535353}{RGB}{83,83,83}
\definecolor{cc72914}{RGB}{199,41,20}
\definecolor{cef3340}{RGB}{239,51,64}
\definecolor{c3eb1c8}{RGB}{62,177,200}
\definecolor{cffc72c}{RGB}{255,199,44}
\newcommand\crossmarkimage[1]{%
  \begin{tikzpicture}[scale=#1, every node/.append style={scale=#1}, inner sep=0pt, outer sep=0pt, x=1cm, y=1cm]
  \path[draw=c948f8f,shading=axis,top color=white,bottom color=ca0a0a0,fill=cd0d0d0,line width=0.0198cm,miter limit=10.0,rounded corners=0.0529cm] (0.1058, -0.1058) rectangle (7.0, -1.5875);
  \node[text=c535353,anchor=south west] (text235) at (1.8, -1.15){\fontfamily{phv}\selectfont \LARGE Check for updates};
  \path[fill=cc72914] (0.6599, -1.1044) -- (1.1393, -0.7848) -- (1.1393, -0.4011) -- (0.6599, -0.4011) -- (0.6599, -1.1044) -- (0.6599, -1.1044)-- cycle;
  \path[fill=cef3340] (1.1393, -1.1044) -- (0.6599, -0.7848) -- (0.6599, -0.4011) -- (1.1393, -0.4011) -- (1.1393, -1.1044) -- (1.1393, -1.1044)-- cycle;
  \path[fill=c3eb1c8] (0.8996, -0.3175)arc(90.0:360.0:0.5292)arc(0.0:90.0:0.5292) -- cycle(0.8996, -1.2462)arc(270.0:0.0:0.3995)arc(0.0:-90.0:0.3995) -- cycle;
  \path[fill=cffc72c] (1.193, -1.1173)arc(317.2441:158.1926:0.3993) -- (0.418, -0.6281)arc(155.807:319.67:0.5292) -- cycle;
\end{tikzpicture}}
% end of crossmark image
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% This produces an icon for an external link. We use it as the external link
% icon for onclick on authors.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\tikzset{%
  linkicon/.pic={%
    \fill[blue] svg{M36 24c-1.2 0-2 0.8-2 2v12c0 1.2-0.8 2-2 2h-22c-1.2
0-2-0.8-2-2v-22c0-1.2 0.8-2 2-2h12c1.2 0 2-0.8 2-2s-0.8-2-2-2h-12c-3.4
0-6 2.6-6 6v22c0 3.4 2.6 6 6 6h22c3.4 0 6-2.6
6-6v-12c0-1.2-0.8-2-2-2z};
    \fill[blue] svg{M43.8 5.2c-0.2-0.4-0.6-0.8-1-1-0.2-0.2-0.6-0.2-0.8-0.2h-12c-1.2
0-2 0.8-2 2s0.8 2 2 2h7.2l-18.6 18.6c-0.8 0.8-0.8 2 0 2.8 0.4 0.4 0.8
0.6 1.4 0.6s1-0.2 1.4-0.6l18.6-18.6v7.2c0 1.2 0.8 2 2 2s2-0.8
2-2v-12c0-0.2 0-0.6-0.2-0.8z};
  }%
}

% The original external link icon was 48 pt, and this is approximately the
% reciprocal of that height.
\newcommand{\@OrigIconHeightRecip}{.02}

% The macro for the link icon.
\DeclareRobustCommand\linkicon{%
  \setlength{\@curXheight}{\fontcharht\font`X}%
  \mbox{%
    \begin{tikzpicture}[yscale=-\@OrigIconHeightRecip*\@curXheight,%
      xscale=\@OrigIconHeightRecip*\@curXheight,transform shape]%
      \pic{linkicon};
    \end{tikzpicture}%
}}

\DeclareRobustCommand\authorlink[1]{%
  \texorpdfstring{%
    \href{#1}{\XeTeXLinkBox{\mbox{\linkicon}}}}{}}

% End of macros for linkicon and authorlink.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% pgfkeys: a flexible key management system
\RequirePackage{pgfkeys}

\pgfkeys{/IACR-author/entities/.cd,
  inst/.initial={},
  orcid/.initial={},
  footnote/.initial={},
  onclick/.initial={},
  email/.initial={},
  surname/.initial={},
}
\def\IACR@author@params@set@keys#1{\pgfkeys{/IACR-author/entities/.cd,#1}}
\newcommand\IACR@author@params@clearkeys{\IACR@author@params@set@keys{inst={},orcid={},footnote={},onclick={},email={},surname={}}}

\pgfkeys{/IACR-affiliation/entities/.cd,
  ror/.initial={},
  department/.initial={},
  street/.initial={},
  city/.initial={},
  state/.initial={},
  postcode/.initial={},
  country/.initial={},
}
\def\IACR@affiliation@params@set@keys#1{\pgfkeys{/IACR-affiliation/entities/.cd,#1}}
\newcommand\IACR@affiliation@params@clearkeys{\IACR@affiliation@params@set@keys{ror={},department={},street={},city={},state={},postcode={},country={}}}

\pgfkeys{/IACR-title/entities/.cd,
  running/.initial={},
  subtitle/.initial={},
  plaintext/.initial={},
}
\def\IACR@title@params@set@keys#1{\pgfkeys{/IACR-title/entities/.cd,#1}}

\pgfkeys{/IACR-funding/entities/.cd,
  country/.initial={},
  grantid/.initial={},
  fundref/.initial={},
  ror/.initial={},
}
\def\IACR@funding@params@set@keys#1{\pgfkeys{/IACR-funding/entities/.cd,#1}}
\newcommand\IACR@funding@params@clearkeys{\IACR@funding@params@set@keys{country={},grantid={},fundref={},ror={}}}

% Title/Author/affiliations
% Running author list for in the header
\global\let\IACR@runningauthors\@empty

% Full author list for the metadata in the pdf
\global\let\IACR@listofauthors\@empty

\global\let\@author\@empty
\global\let\@affiliation\@empty

% Bool to check if the user called the \authorrunning macro
\global\let\IACR@userdefinedrunningauthors\@empty%
\newcommand{\authorrunning}[1]{%
  \gdef\IACR@userdefinedrunningauthors{userdefined}%
  \gdef\IACR@runningauthors{#1}%
}

% Count the number of authors
\newcounter{IACR@author@cnt}

% Count the number of institutions
\newcounter{IACR@inst@cnt}

% Count the number of provided e-mail addresses
\newcounter{IACR@email@cnt}

% Meta information is written out in [jobname].meta
\newwrite\iacrmeta
\immediate\openout\iacrmeta=\jobname.meta

\AtEndDocument{%
  \closeout\iacrmeta%
  % Check if either \title, \addauthor or \addaffiliation macros were redefined
  % Also check if the font (\familydefault) or the margings (\paperwidth) were modified.
  % Throw an error if so, these are needed for meta-data collection
  \ifx\store@addauthor\addauthor\else
    \ClassError{iacrcc}{The \string\addauthor\space macro seems to be redefined}{}%
  \fi
  \ifx\store@title\title\else
    \ClassError{iacrcc}{The \string\title\space macro seems to be redefined}{}%
  \fi
  \ifx\store@addaffiliation\addaffiliation\else
    \ClassError{iacrcc}{The \string\addaffiliation\space macro seems to be redefined}{}%
  \fi
  \ifx\store@font\familydefault\else
    \ClassError{iacrcc}{The \string\familydefault\space macro seems to be redefined}{}%
  \fi
  \ifx\store@paperwidth\paperwidth\else
    \ClassError{iacrcc}{The \string\paperwidth\space macro seems to be redefined}{}%
  \fi
  % Final version requires textabstract.
  \IfFileExists{\jobname.abstract}{}{%
    \ifcsstring{@IACRversion}{final}{%
      \ClassError{iacrcc}{An abstract with textabstract environment is required}{}}{%
      \ClassWarningNoLine{iacrcc}{^^JYour final version will need the textabstract environment.^^J}%
    }
  }{}
  \ifcsstring{@IACRversion}{final}{%
    \ifnum\theIACR@inst@cnt<1\relax
      \ClassError{iacrcc}{Specify at least one affiliation for the final version}{}%
    \fi%
  }{}% final
}
\let\storeprotect\protect

% xpatch: Extending etoolbox patching commands
\RequirePackage{xpatch}

% We used to use an immediate version of \protected@write
\newcommand\@writemeta[1]{\protected@write\iacrmeta{}{#1}}%

% alphalph: Convert numbers to letters,
%           used for footnotes in addauthor
\RequirePackage{alphalph}

\AtBeginDocument{%
  % Use this \maketitle command to first write out
  % the necessary meta-information
  \renewcommand\maketitle{\par
    \@writemeta{version: \@IACRversion}%
    \@writemeta{title: \@plaintitle}%
    \if\relax\expandafter\detokenize\expandafter{\@IACR@title@subtitle}\relax\else
      \@writemeta{\IACRSS subtitle: \@IACR@title@subtitle}%
    \fi
    \hypersetup{pdftitle={\@plaintitle}}%
    % Generic footnote and e-mails are displayed without markers
    \ifx\@genericfootnote\@empty\else
      \begingroup
        \renewcommand\thefootnote{}\footnotetext{\@genericfootnote}%
      \endgroup
    \fi
    \ifx\IACR@displayemails\@empty\else
      \begingroup
        \renewcommand\thefootnote{}\footnotetext{\IACR@displayemails}%
      \endgroup
    \fi
    \ifcsstring{@IACRversion}{final}{%
      % When we produce the final version we need at least one e-mail address
      \ifnum\theIACR@email@cnt<1\relax
        \ClassError{iacrcc}{Provide at least one e-mail address for the final version}{}%
      \fi
    }{}%
    \begingroup
      \global\@topnum\z@   % Prevents figures from going at top of page.
      % Ensure we use alphabetical numbering for the author footnotes
      \renewcommand*{\thefootnote}{\alphalph{\value{footnote}}}%
      \@maketitle
      \thispagestyle{title}\@thanks
    \endgroup
    \def\thispagestyle##1{\ClassError{iacrcc}{The pagestyle is set by iacrcc.cls and may not be changed by the author}{}}
    \setcounter{footnote}{0}%
    \global\let\thanks\relax
    \global\let\maketitle\relax
    \global\let\@maketitle\relax
    \global\let\@thanks\@empty
    \global\let\@date\@empty
    \global\let\date\relax
    \global\let\and\relax
    % Adjust header size for title page
    \ifx\IACR@CROSSMARKURL\@empty\addtolength{\headheight}{\baselineskip}\else%
       \addtolength{\headheight}{2\baselineskip}\fi%
    \addtolength{\headsep}{-\baselineskip}%
    \afterpage{%
     \ifx\IACR@CROSSMARKURL\@empty\global\advance\headheight by -\baselineskip\else%
         \global\advance\headheight by -2\baselineskip\fi
      \global\advance\headsep by \baselineskip%
    }%
  }%
}

% Add support to display the provided e-mail addresses
% in the footnote of the front page
\global\let\IACR@displayemails\@empty

% Add support for a footnote without symbol on the front page
\global\let\@genericfootnote\@empty
\newcommand\genericfootnote[1]{%
  \gdef\@genericfootnote{#1}%
}

\def\@maketitle{%
  \newpage
  \null
  \vskip 2em%
  \begin{center}%
    % Insert the title and subtitle (if defined)
    {\def\@makefnmark{\rlap{\@textsuperscript{\normalfont\@thefnmark}}}%
      {\LARGE \bfseries\sffamily\boldmath \@title\par}%
      \ifdefined\@IACR@title@subtitle@defined\vskip .5em{\large\sffamily\bfseries\@IACR@title@subtitle\par}\fi
    }%
    \vskip 1.5em%
    {\large
      \lineskip .5em%
        \if@anonymous
          Anonymous Submission
        \else
          \setcounter{footnote}{0}%
          \newcounter{IACR@cnt}
          \setcounter{IACR@cnt}{1}%
          % Make sure authors are separated by a comma except the last one where we use " and "
          \def\and{%
            \stepcounter{IACR@cnt}%
            \ifnum\theIACR@cnt=\theIACR@author@cnt\unskip\space and \ignorespaces\else\unskip, \ignorespaces\fi%
          }%
          % Display the list of authors
          % Note that affiliations and footnotes are picked up within
          % the definition of \@author
          \@author%
          \vskip 1em\par
          \small
          \setcounter{IACR@cnt}{1}%
          % When there is only one author with one or more affiliations
          % do not display the affiliation counter
          % Redefine \and to make sure we print the affiliation numbers
          \def\and{\par\ifnum\theIACR@author@cnt=1\relax\else\stepcounter{IACR@cnt}$^{\theIACR@cnt}$~\fi}
          % The above redefinition does not work for the first institute: fix that here
          \ifnum\theIACR@author@cnt=1\relax\else
            \ifnum\theIACR@inst@cnt>1$^1$~\fi\ignorespaces%
          \fi
          \@affiliation
        \fi%!anonymous
      }%
  \end{center}%
  \par
  \vskip 1.5em%
}

% This is for indentation in meta file.
\newcommand{\IACRSS}{\space\space}

% We do not support \author, use \addauthor instead
\renewcommand\author[2][]{%
  \ClassError{iacrcc}{Do not use the \string\author\space macro: use the \string\addauthor\space macro instead}{}%
}

\ExplSyntaxOn
\prg_new_conditional:Npnn \iacr_check_orcid:n #1 { T, F, TF }
{
  \cs_generate_variant:Nn \regex_match:nnTF {nV}
  % An Orcid consists of:
  % 4 digits, "-", 4 digits, "-", 4 digits, "-", 3 digits, 1 digit or "x" or "X"
  \regex_match:nnTF {^\d{4}-\d{4}-\d{4}-\d{3}[Xx\d]$} { #1 }
  { \prg_return_true:  }
  { \prg_return_false: }
}
\cs_new_eq:NN \IfValidOrcid \iacr_check_orcid:nTF

\prg_new_conditional:Npnn \iacr_check_inst:n #1 { T, F, TF }
{
  \cs_generate_variant:Nn \regex_match:nnTF {nV}
  % An institute index should be a number, multiple institutes are separated by a comma:
  \regex_match:nnTF {^[,\d]+$} { #1 }
  { \prg_return_true:  }
  { \prg_return_false: }
}
\cs_new_eq:NN \IfValidInst \iacr_check_inst:nTF

\prg_new_conditional:Npnn \iacr_check_email:n #1 { T, F, TF }
{
  \cs_generate_variant:Nn \regex_match:nnTF {nV}
  % The format of e-mail addresses is complicated (see: https://en.wikipedia.org/wiki/Email_address)
  % We lazy match all characters until the '@' (the local part) and then we only allow dot-seperated
  % uppercase and lowercase Latin letters A to Z and a to z;
  % Digits 0 to 9;
  % Hyphen -, and brackets []
  % for the domain part
  \regex_match:nnTF {.*?@[a-zA-Z0-9\.\-\[\]]+$} { #1 }
  { \prg_return_true:  }
  { \prg_return_false: }
}
\cs_new_eq:NN \IfValidEmail \iacr_check_email:nTF
\ExplSyntaxOff

\newcommand\addauthor[2][]{%
  \MathAllowedInCheckStringfalse
  \checkstring{#2}{author names should not contain macros or math}%
  % Some additional checks on the if addauthor is used correctly
  % Check if the name contains an ","
  \saveexpandmode\noexpandarg % set \noexpandarg locally
  \IfSubStr{\detokenize{#2}}{,}{%
    \ClassError{iacrcc}{Do not put several authors in the same \string\addauthor\space macro}{}%
  }{}%
  % Affiliations should be defined *after* addauthor
  \ifnum\theIACR@inst@cnt>0\relax
    \ClassError{iacrcc}{Affiliations must follow authors}%
  \fi
  % Do not use " and " in your author name: this might indicate incorrect usage
  \IfSubStr{#2}{ and }{%
    \ClassError{iacrcc}{Do not put several authors in the same \string\addauthor\space macro}{}%
  }{}%
  % No newline is allowed in addauthor
  \IfSubStr{#2}{\\}{%
    \ClassError{iacrcc}{Do not put a newline in the \string\addauthor\space macro}{}%
  }{}%
  \restoreexpandmode % restore the previous mode
  %
  \stepcounter{IACR@author@cnt}%
  %
  % Write out the author in the meta file.
  \@writemeta{author:}%
  \IACR@author@params@set@keys{#1}%
  \pgfkeysgetvalue{/IACR-author/entities/footnote}{\@IACR@author@footnote}%
  \pgfkeysgetvalue{/IACR-author/entities/surname}{\@IACR@author@surname}%
  \pgfkeysgetvalue{/IACR-author/entities/orcid}{\@IACR@author@orcid}%
  \pgfkeysgetvalue{/IACR-author/entities/onclick}{\@IACR@author@onclick}%
  \pgfkeysgetvalue{/IACR-author/entities/inst}{\@IACR@author@inst}%
  \pgfkeysgetvalue{/IACR-author/entities/email}{\@IACR@author@email}%
  \expandafter\let\csname IACR@author@footnote\alphalph{\theIACR@author@cnt} \endcsname\@IACR@author@footnote% Copy the pgf key
  % Check the format of the Orcid
  \if\relax\expandafter\detokenize\expandafter{\@IACR@author@orcid}\relax\else
    \expandafter\IfValidOrcid\expandafter{\@IACR@author@orcid}{}{%
      \ClassErr{The provided ORCID in \string\addauthor\space does not look valid: \@IACR@author@orcid. Did you forget a comma?}%
    }{}%
  \fi
  % Check the format of the inst
  \if\relax\expandafter\detokenize\expandafter{\@IACR@author@inst}\relax\else
    \expandafter\IfValidInst\expandafter{\@IACR@author@inst}{}{%
      \ClassErr{The provided inst in \string\addauthor\space does not look valid: \@IACR@author@inst. Did you forget a comma?}%
    }{}%
  \fi
  % Check the format of the email
  \if\relax\expandafter\detokenize\expandafter{\@IACR@author@email}\relax\else
    \expandafter\IfValidEmail\expandafter{\@IACR@author@email}{}{%
      \ClassErr{The provided email in \string\addauthor\space does not look valid: \@IACR@author@email. Did you forget a comma?}%
    }{}%
  \fi
  %
  \@writemeta{\IACRSS name: #2}%
  \if\relax\expandafter\detokenize\expandafter{\@IACR@author@surname}\relax\else
    % If a surname is provided does some basic sanity checking on the string
    \MathAllowedInCheckStringfalse
    \expandafter\checkstring\expandafter{\@IACR@author@surname}{surname should not contain macros or math}%
    \@writemeta{\IACRSS surname: \@IACR@author@surname}%
  \fi
  \@writemeta{\IACRSS affil: \@IACR@author@inst}%
  % Create the unlabeled footnote consisting of:
  % First the provided footnote (if any) and next
  % the provided e-mail addresses
  \if\relax\expandafter\detokenize\expandafter{\@IACR@author@email}\relax\else
    \if\relax\expandafter\detokenize\expandafter{\IACR@displayemails}\relax
      \edef\IACR@displayemails{E-mail: \noexpand\href{mailto:\@IACR@author@email}{\noexpand\nolinkurl{\@IACR@author@email}} (\unexpanded{#2})}%
    \else
      \eappto\IACR@displayemails{, \noexpand\href{mailto:\@IACR@author@email}{\noexpand\nolinkurl{\@IACR@author@email}} (\unexpanded{#2})}%
    \fi
    \@writemeta{\IACRSS email: \@IACR@author@email}%
    \stepcounter{IACR@email@cnt}%
  \fi
  % Author name + optionally clickable
  \ifx\@author\@empty
    \def\@author{\unexpanded{\mbox{#2}}}%
    \ifx\IACR@userdefinedrunningauthors\@empty
      \def\IACR@runningauthors{#2}%
    \fi
    \def\IACR@listofauthors{#2}%
  \else
    \appto\@author{\and\unexpanded{\mbox{#2}}}%
    \ifx\IACR@userdefinedrunningauthors\@empty
      \appto\IACR@runningauthors{,\space\unexpanded{#2}}%
    \fi
    \appto\IACR@listofauthors{,\space #2}%
  \fi
  % Add the footnote text if present
  % Define two seperate macros for the institute
  % \inst and \instwcomma where the latter inserts a comma
  % between the footnote and the institute marker
  \if\relax\expandafter\detokenize\expandafter{\@IACR@author@footnote}\relax
    \if\relax\expandafter\detokenize\expandafter{\@IACR@author@inst}\relax\else
      \eappto\@author{\noexpand\inst{\@IACR@author@inst}}%
    \fi
  \else
    \eappto\@author{\noexpand\footnote{\expandafter\noexpand\csname IACR@author@footnote\alphalph{\theIACR@author@cnt} \endcsname}}%
    \if\relax\expandafter\detokenize\expandafter{\@IACR@author@inst}\relax\else
      \eappto\@author{\noexpand\instwcomma{\@IACR@author@inst}}%
    \fi
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@author@orcid}\relax\else
    \eappto\@author{~\noexpand\orcidlink{\@IACR@author@orcid}}%
    \@writemeta{\IACRSS orcid: \@IACR@author@orcid}%
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@author@onclick}\relax\else
    \eappto\@author{~\noexpand\authorlink{\@IACR@author@onclick}}%
  \fi
  \IACR@author@params@clearkeys%
}
\let\store@addauthor\addauthor% Save macro away

% Define the \addfunding macro to capture funding meta-data
\newcommand{\addfunding}[2][\@empty]{%
  \IACR@funding@params@set@keys{#1}%
  \gdef\@IACR@funding@name{#2}%
  \pgfkeysgetvalue{/IACR-funding/entities/country}{\@IACR@funding@country}%
  \pgfkeysgetvalue{/IACR-funding/entities/grantid}{\@IACR@funding@grantid}%
  \pgfkeysgetvalue{/IACR-funding/entities/fundref}{\@IACR@funding@fundref}%
  \pgfkeysgetvalue{/IACR-funding/entities/ror}{\@IACR@funding@ror}%
  \@writemeta{funding:}%
  \@writemeta{\IACRSS name: \@IACR@funding@name}%
  \if\relax\expandafter\detokenize\expandafter{\@IACR@funding@country}\relax\else
    \@writemeta{\IACRSS country: \@IACR@funding@country}%
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@funding@grantid}\relax\else
    \@writemeta{\IACRSS grantid: \@IACR@funding@grantid}%
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@funding@fundref}\relax\else
    \@writemeta{\IACRSS fundref: \@IACR@funding@fundref}%
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@funding@ror}\relax\else
    \@writemeta{\IACRSS ror: \@IACR@funding@ror}%
  \fi
  \IACR@funding@params@clearkeys%
}

% This is a complicated implementation to test whether a token list is
% appropriate to use as metadata. It is intended to make sure that
% \write will produce a string without macros, except that macros are
% allowed in math mode. In a previous implementation we compared the argument
% to \text_purify:n applied to the argument, but this did not allow accents
% to be applied. This implementation is based on tokcycle, which
% provides handlers for four classes of tokens: character, group,
% macro, and space.

% tokcycle: Build tools to process tokens from an input stream
\RequirePackage{tokcycle}

% listofitems: Grab items in lists using user-specified sep char
\RequirePackage{listofitems}

% Just a shortcut for Errors
\newcommand\ClassErr[1]{\ClassError{iacrcc}{#1}{}}

% TODO: Check if this is neccesary with new fixes.
% Check if a token macro (in pdflatex) is a UTF-8 char
\ExplSyntaxOn
\prg_new_conditional:Npnn \iacr_check_uitfeight:n #1 { T, F, TF }
{
  % Define a regular expression where the second argument
  % needs to be expanded.
  % Look if the meaning of the token contains UTFviii
  % In (pdf)latex UTF8 tokens look like:
  % * \UTFviii@invalid@err
  % * \UTFviii@two@octets (or three or four octets)
  \cs_generate_variant:Nn \regex_match:nnTF {nV}
  \regex_match:nVTF { UTFviii } { \token_to_meaning:N #1 }
  { \prg_return_true:  }
  { \prg_return_false: }
}
\cs_new_eq:NN \IfUITFEight \iacr_check_uitfeight:nTF
\ExplSyntaxOff

% Macro which specifies if math is allowed in the
% first argument to \checkstring
\newif\ifMathAllowedInCheckString
\MathAllowedInCheckStringtrue

\newif\ifTokenNotFound
\newcommand\IsMacroAllowed[3]{%
  \TokenNotFoundtrue
  \setsepchar{,}% parsing-separator
  % List of macros which are allowed
  \readlist\phrase{\ ,\$,\#,\&,\%,\ss,\o,\O,\`,\',\^,\",\=,\~,\.,\u,\v,\H,\t,\c,\d,\b,\l,\L,\space,\{,\},\=,\\,\r}%
  \def\iacrtmp{#1}%
  \foreachitem\word\in\phrase{%
    \ifTokenNotFound
      \ifx\iacrtmp\word
        \TokenNotFoundfalse
      \fi
    \fi
  }%
  \ifTokenNotFound
    % Check if the macro is a UTF-8 character in pdflatex
    % If so, we do not complain
    \IfUITFEight{#1}{}{%
      \ClassErr{#3:^^Jmacro \iacrtmp not allowed in #2}%
    }{}%
  \fi
}

% #1 is a string to check as just text. No macros are allowed except accents
%    that are easily converted downstream and except in math mode.
% #2 is an error message prefix.
\newcommand\checkstring[2]{%
  % Since tokcycle treats the math toggle character $ as just another character,
  % we keep track of whether we are in math mode using this if. This allows us
  % to allow macros and groups in math mode but not in text mode.
  \newif\ifInMathMode
  \tokcycle{% character handler
    %\typeout{CHARACTER: ##1}
    \if##1$% Check if we see a math toggle catcode 3
      \ifMathAllowedInCheckString
        \ifInMathMode % toggle this
          \InMathModefalse
        \else
          \InMathModetrue
        \fi
      \else
        \ClassErr{#2:^^J math not allowed in ^^J #1}
      \fi
    \fi}% end of character handler
    {% group handler
    %\typeout{GROUP: ##1}
    \ifInMathMode % groups are allowed in math mode.
    \else
      % Recurse and check this group: this allows things like {\`e}
      \checkstring{##1}{#2}%
    \fi}% end of group handler
    {%  macro handler
    %\typeout{MACRO: \string##1}
    \ifInMathMode
      \ClassWarning{iacrcc}{^^JMacros are not recommended in the title^^J}
    \else
      \IsMacroAllowed{##1}{#1}{#2}%
    \fi
    }% end of macro handler
    {% spaces are just ok.
    }%
    {#1}% argument to be parsed by tokcycle
  % Reset the macro to check for math to the default (true) value
  \MathAllowedInCheckStringtrue
}

\global\let\@plaintitle\@empty%
\global\let\@IACR@title@subtitle\@empty%

% Provide the title of the paper with its various options
\renewcommand\title[2][]{%
  \IACR@title@params@set@keys{#1}%
  \gdef\@plaintitle{#2}%
  \pgfkeysgetvalue{/IACR-title/entities/running}{\@IACR@title@running}%
  \pgfkeysgetvalue{/IACR-title/entities/subtitle}{\@IACR@title@subtitle}%
  \pgfkeysgetvalue{/IACR-title/entities/plaintext}{\@IACR@title@plaintext}%
  \renewcommand\thanks[1]{\ClassError{iacrcc}{The \string\thanks\space macro is not supported. Please see the documentation how to use footnotes.}{}}%
  \if\relax\expandafter\detokenize\expandafter{\@IACR@title@plaintext}\relax
    \checkstring{#2}{error in title}
  \else
     \gdef\@plaintitle{\@IACR@title@plaintext}%
     \expandafter\checkstring\expandafter{\@IACR@title@plaintext}{plaintext argument to title must be plain text}%
  \fi
  \gdef\@title{#2}%
  \if\relax\expandafter\detokenize\expandafter{\@IACR@title@running}\relax
    \gdef\@IACR@title@running{\@plaintitle}%
    \saveexpandmode\noexpandarg % set \noexpandarg locally
    \StrLen{#2}[\IACR@tmp]%
    \restoreexpandmode % restore the previous mode
    \ifnumgreater{\IACR@tmp}{70}{%
      \ClassWarning{iacrcc}{The title appears to be very long. Please define a running title by passing running=<runningtitle> to the \string\title\string macro}{}%
    }{}
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@title@subtitle}\relax\else
    \expandafter\checkstring\expandafter{\@IACR@title@subtitle}{subtitle argument to title must be plain text}%
    \gdef\@IACR@title@subtitle@defined{}%
  \fi
}
\let\store@title\title% Save macro away

\newcommand\addaffiliation[2][]{%
  \stepcounter{IACR@inst@cnt}%
  % If a affiliation name is provided does some basic sanity checking on the string
  \MathAllowedInCheckStringfalse
  \checkstring{#2}{Affiliation name should not contain macros or math}%
  \@writemeta{affiliation:}%
  \@writemeta{\IACRSS name: #2}%
  % Set and retrieve all the parameters passed
  \IACR@affiliation@params@set@keys{#1}%
  \pgfkeysgetvalue{/IACR-affiliation/entities/ror}{\@IACR@affiliation@ror}%
  \pgfkeysgetvalue{/IACR-affiliation/entities/department}{\@IACR@affiliation@department}%
  \pgfkeysgetvalue{/IACR-affiliation/entities/street}{\@IACR@affiliation@street}%
  \pgfkeysgetvalue{/IACR-affiliation/entities/city}{\@IACR@affiliation@city}%
  \pgfkeysgetvalue{/IACR-affiliation/entities/state}{\@IACR@affiliation@state}%
  \pgfkeysgetvalue{/IACR-affiliation/entities/postcode}{\@IACR@affiliation@postcode}%
  \pgfkeysgetvalue{/IACR-affiliation/entities/country}{\@IACR@affiliation@country}%
  \ifx\@affiliation\@empty
    \gdef\@affiliation{\unexpanded{#2}}%
  \else
    \appto\@affiliation{\and\unexpanded{#2}}%
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@affiliation@ror}\relax\else
    \@writemeta{\IACRSS ror: \@IACR@affiliation@ror}%
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@affiliation@department}\relax\else
    \@writemeta{\IACRSS department: \@IACR@affiliation@department}%
    \appto\@affiliation{, }%
    \expandafter\appto\expandafter\@affiliation\expandafter{\@IACR@affiliation@department}%
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@affiliation@street}\relax\else
    \@writemeta{\IACRSS street: \@IACR@affiliation@street}%
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@affiliation@city}\relax\else
    \@writemeta{\IACRSS city: \@IACR@affiliation@city}%
    \appto\@affiliation{, }%
    \expandafter\appto\expandafter\@affiliation\expandafter{\@IACR@affiliation@city}%
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@affiliation@state}\relax\else
    \@writemeta{\IACRSS state: \@IACR@affiliation@state}%
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@affiliation@postcode}\relax\else
    \@writemeta{\IACRSS postcode: \@IACR@affiliation@postcode}%
  \fi
  \if\relax\expandafter\detokenize\expandafter{\@IACR@affiliation@country}\relax
    % We require a country for every author when compiling the final version
    \ifcsstring{@IACRversion}{final}{%
      \ClassError{iacrcc}{Specify a country for each affiliation for the final version}{}%
    }{}
  \else
    \@writemeta{\IACRSS country: \@IACR@affiliation@country}%
    \appto\@affiliation{, }%
    \expandafter\appto\expandafter\@affiliation\expandafter{\@IACR@affiliation@country}%
  \fi
  \IACR@affiliation@params@clearkeys%
}
\let\store@addaffiliation\addaffiliation% Save macro away

\if@anonymous
  \gdef\@author{Anonymous Submission to \publname}%
  \gdef\IACR@runningauthors{}%
  \gdef\IACR@listofauthors{}%
  \renewcommand{\addauthor}[2][]{}%
  \renewcommand{\addaffiliation}[2][]{}%
\fi

\newcommand{\inst}[1]{%
  \ifnum\theIACR@author@cnt=1\relax\else
    \ifnum\theIACR@inst@cnt=1\relax\else
      \unskip$^{#1}$%
    \fi
  \fi
}

\newcommand{\instwcomma}[1]{%
  \ifnum\theIACR@author@cnt=1\relax\else
    \ifnum\theIACR@inst@cnt=1\relax\else
      \unskip$^{,\,#1}$%
    \fi
  \fi
}

% fancyhdr: extensive control of page headers and footers in LATEX2ε
\RequirePackage{fancyhdr}

% graphicx: enhanced support for graphics
\RequirePackage{graphicx}

\global\let\@IACR@docdate\@empty%
\newcommand{\documentdate}[1]{%
  \gdef\@IACR@docdate{#1}%
  \gdef\@IACR@docdate@defined{1}%
}

% Ensure the bookmark for the reference points to the section header
% Insert a PDF anchor into the beginning of \refname
\let\oldrefname\refname%
\def\refname{\leavevmode\texorpdfstring{\vbox to 0pt{\vss\pdfdest name{references}XYZ\vskip\baselineskip}\relax\oldrefname}{\oldrefname}}%

\apptocmd{\thebibliography}{%
  \def\@currentHref{references}\relax%
  \addcontentsline{toc}{section}{References}%
}{}{}

\AtEndPreamble{%
  \@ifpackageloaded{babel}{%
    % Ensure the bookmark for the reference points to the section header
    % Insert a PDF anchor into the beginning of \refname
    % Add this to captionsenglish to avoid problems when babel is used
    \addto\captionsenglish{%
      \gdef\refname{\leavevmode\texorpdfstring{\vbox to 0pt{\vss\pdfdest name{references}XYZ\vskip\baselineskip}\relax\oldrefname}{\oldrefname}}%
    }%
  }{}%
}

% if the author decides to use biblatex, then we pass options for the style to enforce
% consistent look and feel.
\if@optbiblatex
  \typeout{biblatex options may not be changed with \@backslashchar usepackage}
  % csquotes: context sensitive quotation facilities
  \RequirePackage{csquotes} % to fix a conflict with biblatex and doclicense.
  % biblatex: sophisticated Bibliographies in LaTeX
  \RequirePackage[backend=biber,style=trad-alpha,minalphanames=3,maxalphanames=4,maxbibnames=40,useprefix=true]{biblatex}[2019/12/01]
  \DeclarePrintbibliographyDefaults{heading=bibintoc}%
  \DeclareLabelalphaTemplate{
    \labelelement{
      \field[strwidth=3,strside=left]{label}
      \field[strwidth=3,strside=left,ifnames=1]{labelname}
      \field[strwidth=1,strside=left]{labelname}
      \field[strwidth=3,strside=left]{citekey}
    }
    \labelelement{\field[strwidth=2,strside=right]{year}}
  }
  %% \DeclareNameFormat{author}{%
  %%   \usebibmacro{name:given-family}{\namepartfamily}{\namepartgiven}{\namepartprefix}{\namepartsuffix}%
  %% }%
\else % did not invoke \documentclass[biblatex]{iacrcc}
  \AtBeginDocument{%
    \@ifpackageloaded{biblatex}{%
      \ClassError{iacrcc}{biblatex should be loaded with \@backslashchar documentclass[biblatex]{iacrcc}}%
    }%
  }
\fi%!biblatex

% xurl: Allow URL breaks at any alphanumerical character
% Load xurl *after* biblatex to ensure the same behavior
\RequirePackage{xurl}

\global\let\@IACR@License\@empty%
\newcommand\license[1]{%
  \gdef\@IACR@License{#1}%
  \def\@IACR@CCby{CC-by}%
  \ifx\@IACR@License\@IACR@CCby%
    % doclicense: support for putting documents under a license. Only usable in preamble.
    \ifx\@onlypreamble\@notprerr\ClassError{iacrcc}{\string\license\space must be used before \string\begin{document}}{}\fi
    % load without hyperxmp integration.
    \RequirePackage[type={CC},modifier={by},version={4.0},hyperxmp=false]{doclicense}
  \else
    \ClassError{iacrcc}{Invalid license: only acceptable license is CC-by}{}%
  \fi
  \@writemeta{license: \@IACR@License}%
}

\def\ymdtoday{\leavevmode\hbox{\the\year-\twodigits\month-\twodigits\day}}\def\twodigits#1{\ifnum#1<10 0\fi\the#1}

\fancypagestyle{title}{%
  \fancyhf{} % clear all header and footer fields
  \ifcsstring{@IACRversion}{final}{%
      \ifx\@IACR@License\@empty
        \ClassError{iacrcc}{Please specify a license when using version=final: using for example \string\license{CC-by}}{}%
      \fi
      \fancyhead[L]{%
        \small%
        \publname{}\\
        \ifx\IACR@EISSN\@empty\else{ISSN~\IACR@EISSN, }\fi%
        Vol.~\IACR@vol, No.~\IACR@no, \IACR@lp\ pages.}
      \ifx\IACR@DOI\@empty\else\fancyhead[R]{\small%
        \begin{tabular}{r}\href{https://doi.org/\IACR@DOI}{https://doi.org/\IACR@DOI}\ifx\IACR@CROSSMARKURL\@empty\else\vspace{2px}\\%
        \href{\IACR@CROSSMARKURL}{\crossmarkimage{.35}}\fi\end{tabular}}\fi%
  }{}% final
  \ifx\@IACR@License\@empty\else%
    % If \license is provided show this for preprint and final (not for submission)
    \ifcsstring{@IACRversion}{submission}{}{%
      \fancyfoot[L]{%
        \small%
        \doclicenseText%
        \hfill{}%
        \doclicenseImage[imagewidth=4em]\\[.1em]%
        \ifcsstring{@IACRversion}{final}{% Only show this information on the final version
          \ifx\IACR@Received\@empty\else Received: \IACR@Received \hfill{}\fi%
          \ifx\IACR@Accepted\@empty\else Accepted: \IACR@Accepted \hfill{}\fi%
        }{%
          \ifdefined\@IACR@docdate@defined%
            \ifx\@IACR@docdate\@empty%
              % an empty string was passed \documentdate to
              % indicate to *not* display any date
            \else
              Date of this document: \@IACR@docdate.%
            \fi% !if \@IACR@docdate = \@empty
          \else%
            Date of this document: \ymdtoday.%
          \fi% !if \@IACR@docdate@defined is defined
        }%
      }%
    }% !if @IACRversion != submission
  \fi% !\@IACR@License
  \renewcommand{\headrulewidth}{0pt}
  \renewcommand{\footrulewidth}{0pt}
}%fancypagestyle

\fancyhf{}
\fancyhead[RO,LE]{\thepage}
\fancyhead[RE]{\@IACR@title@running}%
\fancyhead[LO]{%
  \if@anonymous
    \def\thanks##1{}%
    \def\inst##1{}%
    \def\instwcomma##1{}%
    \def\\{}%
    \def\footnote##1{}%
    \setcounter{IACR@author@cnt}{1}%
    \@author%
  \else
    \ifnum\theIACR@author@cnt>4\relax
      \ifx\IACR@userdefinedrunningauthors\@empty
        \ClassError{iacrcc}{When using more than 4 authors please define the running authors using the \string\authorrunning\space macro}{}%
      \fi
    \fi
    \IACR@runningauthors%
  \fi%!anonymous
}
\renewcommand{\markboth}[2]{}
\pagestyle{fancy}
\def\pagestyle#1{\ClassError{iacrcc}{The pagestyle is set by iacrcc.cls and may not be changed by the author}{}}
\def\pagenumbering#1{\ClassError{iacrcc}{The page numbering is set by iacrcc.cls and may not be changed by the author}{}}

% Abstract style, keywords
\global\let\IACR@text@keywords\@empty
\global\let\IACR@keywords\@empty
% \IACR@keywords may contain mathematics for display in LaTeX.
% \IACR@text@keywords is the plain text version used for PDF and metadata.

\newcommand{\keywords}[2][\@empty]{%
  \saveexpandmode\noexpandarg % set \noexpandarg locally
  \IfSubStr{#2}{ \and }{%
    \ClassError{iacrcc}{Do not use the \string\and\space macro in \string\keywords: use "," instead}{}%
  }%
  \restoreexpandmode % restore the previous mode
  \gdef\IACR@keywords{#2}%
  \ifx#1\@empty
    \checkstring{#2}{Keywords should be free of macros. Use optional argument to \string\keywords}
    \gdef\IACR@text@keywords{#2}%
  \else
    \checkstring{#1}{optional argument to keywords may not contain macros.}
    \gdef\IACR@text@keywords{#1}%
  \fi
  %% PDF keywords
  \ifx\IACR@text@keywords\@empty\else
    \@ifpackageloaded{hyperref}{%
      \hypersetup{pdfkeywords={\IACR@text@keywords}}
    }{}%
  \fi
}

% fancyvrb: sophisticated verbatim text
\RequirePackage{fancyvrb} % used to write the abstract into \jobname.abstract

% See: https://tex.stackexchange.com/questions/596323/unicode-characters-within-verbatimout-of-fancyvrb
% The fancyvrb package uses \immediate\write, but this has the consequence
% that active characters not explicitly inactivated are expanded.
% Patch to use a “protected” immediate write.
% Define the same as \protected@write, but with \immediate
\providecommand*\protected@iwrite@fancyvrb[3]{%
  \begingroup
  \let\thepage\relax
  #2%
  \let\protect\@unexpandable@protect
  \edef\reserved@a{\immediate\write#1{#3}}\reserved@a
  \endgroup
  \if@nobreak\ifvmode\nobreak\fi\fi
}
\patchcmd{\FVB@VerbatimOut}
  {\immediate\write\FV@OutFile}
  {\protected@iwrite@fancyvrb\FV@OutFile{}}
  {}{}

% To be used by an author to provide a text abstract. This is required
% for the final version.
\newenvironment{textabstract}{%
  \VerbatimOut{\jobname.abstract}}{\endVerbatimOut}

\renewenvironment{abstract}{%
  \ifx\IACR@text@keywords\@empty\else
    \@writemeta{keywords: \IACR@text@keywords}%
    \hypersetup{pdfkeywords={\IACR@text@keywords}}
  \fi
  \small\quotation\setlength{\parindent}{0pt}\noindent
  \textbf{\textsf{Abstract.}}
}%
{%
  \ifx\IACR@keywords\@empty\else
    \smallskip\par\textbf{\textsf{Keywords:}}
    % Replace comma by a centered period.
    \expandarg\StrSubstitute{\IACR@keywords}{,}{\unskip\space\textperiodcentered\space\ignorespaces}
  \fi
  \endquotation%
}

% autoref: capitals for Sections, and adding Algorithm
\def\equationautorefname{Equation}%
\def\footnoteautorefname{footnote}%
\def\itemautorefname{item}%
\def\figureautorefname{Figure}%
\def\tableautorefname{Table}%
\def\partautorefname{Part}%
\def\appendixautorefname{Appendix}%
\def\chapterautorefname{Chapter}%
\def\sectionautorefname{Section}%
\def\subsectionautorefname{Subsection}%
\def\subsubsectionautorefname{Subsubsection}%
\def\paragraphautorefname{paragraph}%
\def\subparagraphautorefname{subparagraph}%
\def\FancyVerbLineautorefname{line}%
\def\theoremautorefname{Theorem}%
\def\pageautorefname{page}%

\def\algorithmautorefname{Algorithm}%
\def\definitionautorefname{Definition}%
\def\exampleautorefname{Example}%
\def\exerciseautorefname{Exercise}%
\def\propertyautorefname{Property}%
\def\questionautorefname{Question}%
\def\solutionautorefname{Solution}%
\def\propositionautorefname{Proposition}%
\def\problemautorefname{Problem}%
\def\lemmaautorefname{Lemma}%
\def\conjectureautorefname{Conjecture}%
\def\corollaryautorefname{Corollary}%
\def\claimautorefname{Claim}%
\def\remarkautorefname{Remark}%
\def\noteautorefname{Note}%
\def\caseautorefname{Case}%

% amsmath: AMS mathematical facilities for LATEX
% amssymb: defines all the symbols found in the AMS symbol fonts
% amsthm: typesetting theorems (AMS style)
\RequirePackage{amsmath,amssymb,amsthm}
% mathtools: mathematical tools to use with amsmath
\RequirePackage{mathtools}
\theoremstyle{definition}%
\newtheorem{definition}{Definition}%
\newtheorem{example}{Example}%
\newtheorem{exercise}{Exercise}%
\newtheorem{property}{Property}%
\newtheorem{question}{Question}%
\newtheorem{solution}{Solution}%

\theoremstyle{plain}%
\newtheorem{theorem}{Theorem}%
\newtheorem{proposition}{Proposition}%
\newtheorem{problem}{Problem}%
\newtheorem{lemma}{Lemma}%
\newtheorem{conjecture}{Conjecture}%
\newtheorem{corollary}{Corollary}%
\newtheorem*{claim}{Claim}%

\theoremstyle{remark}%
\newtheorem{remark}{Remark}%
\newtheorem{note}{Note}%
\newtheorem{case}{Case}%

\theoremstyle{plain}%

% Floats and captions
\if@floatrow
  % floatrow: modifying the layout of floats
  \RequirePackage{floatrow}
  \floatsetup[table]{style=Plaintop}
  % caption: customising captions in floating environments
  \RequirePackage{caption}
  \captionsetup{labelfont={sf,bf}}
\else
  % float: improved interface for floating objects
  \RequirePackage{float}
  \newcommand\fs@iacrabove{%
    % Swap \abovecaptionskip and \belowcaptionskip
    \addtolength\abovecaptionskip{-\belowcaptionskip}
    \addtolength\belowcaptionskip{\abovecaptionskip}
    \addtolength\abovecaptionskip{-\belowcaptionskip}
    \setlength\abovecaptionskip{-\abovecaptionskip}
    \fs@plaintop%
    \def\@fs@cfont{\sffamily\bfseries}}
  \newcommand\fs@iacrbelow{%
    \fs@plain%
    \def\@fs@cfont{\sffamily\bfseries}
  }
  \floatstyle{iacrabove}
  \restylefloat{table}
  \floatstyle{iacrbelow}
  \restylefloat{figure}
\fi

\newcommand\IACR@linenumbers{%
  % lineno: line numbers on paragraphs
  \RequirePackage[mathlines,sep=11pt,width=11pt]{lineno}
  \AtBeginDocument{%
    \linenumbers%
    \AddToHook{env/lstlisting/before}{\nolinenumbers}
    \AddToHook{env/lstlisting/after}{\linenumbers}
    \AddToHook{cmd/lstinputlisting/before}{\nolinenumbers}
  }%
}
\ifcsstring{@IACRversion}{submission}{\IACR@linenumbers}{}
\ifcsstring{@IACRversion}{final}{%
  \InputIfFileExists{\jobname.copyedit}{% turn on linenumbers and
    % input any additional commands for copy editing.
    \typeout{^^JCopy editing enabled^^J}\IACR@linenumbers}{}
}{}
% microtype: subliminal refinements towards typographical perfection
\RequirePackage{microtype}

% We load lmodern to get latin modern fonts but only in pdflatex.
% Lualatex already uses latin modern for text and cm for math.
\ifpdftex
  % lmodern: Latin modern fonts in outline formats
  \RequirePackage{lmodern}
\fi

% Store the default font family used
\let\store@font\familydefault%

% Store the paper width
\let\store@paperwidth\paperwidth%

% One might get an “Unused global options” warning for some of our options.
% This can be removed using the \XKV@useoption command provided by the xkeyval
% package but this does not seem to work in all LaTeX environments.
% Simply remove the options from \@unusedoptionlist ourselves.
\ifx\@unusedoptionlist\@empty\else
  \StrDel{\@unusedoptionlist}{version=final}[\@unusedoptionlist]%
  \StrDel{\@unusedoptionlist}{version=preprint}[\@unusedoptionlist]%
  \StrDel{\@unusedoptionlist}{version=submission}[\@unusedoptionlist]%
  \StrDel{\@unusedoptionlist}{version}[\@unusedoptionlist]%
  \StrDel{\@unusedoptionlist}{floatrow}[\@unusedoptionlist]%
  \StrDel{\@unusedoptionlist}{notanonymous}[\@unusedoptionlist]%
  \StrDel{\@unusedoptionlist}{biblatex}[\@unusedoptionlist]%
  \StrDel{\@unusedoptionlist}{,}[\@unusedoptionlist]%
\fi

\endinput
%end of file iacrcc.cls
