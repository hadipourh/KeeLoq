# Revisiting Practical Attacks on KeeLoq

This directory contains the [LaTeX source](paper.tex) and [PDF](paper.pdf)
of the technical write-up by Hosein Hadipour. It is distributed with the
code as a standalone technical report, not as an accepted journal or
conference publication.

## Build

Use a TeX Live or MacTeX installation with `latexmk`, pdfLaTeX, BibTeX,
the `alphaurl` bibliography style, and the packages loaded by `paper.tex`
and the bundled `iacrcc.cls`.

From this directory:

```sh
latexmk -pdf -interaction=nonstopmode -halt-on-error -outdir=build paper.tex
cp build/paper.pdf paper.pdf
```

The bibliography is in `paper.bib`. The two external diagrams are in
`figures/`; the remaining diagrams are defined in the LaTeX source.
The class and `tikzlibrarycipher.code.tex` are included so the build does
not depend on the local template checkout.

Git tracks the source, bibliography, required class and drawing library,
figure PDFs, this README, and the compiled `paper.pdf`. Build products in
`build/`, local notes, and the template checkout are ignored.

## License

The document declares CC BY 4.0 in its LaTeX source and PDF. The bundled
class and drawing library retain their original author and license notices.
The repository's software license is recorded in [LICENSE](../../LICENSE).
