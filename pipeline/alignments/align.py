#!/usr/bin/env python3
"""
Calculates alignments for a parallel corpus

Example:
    BIN=bin python pipeline/alignments/align.py \
        --corpus_src=fetches/corpus.ru.zst
        --corpus_trg=fetches/corpus.en.zst
        --output_path=artifacts/corpus.aln.zst
        --priors_input_path=fetches/corpus.priors
        --priors_output_path=artifacts/corpus.priors
"""

import argparse
import os
import subprocess
import sys
from contextlib import ExitStack
from typing import Optional

import eflomal
import zstandard

from pipeline.common.logging import get_logger

logger = get_logger("alignments")
COMPRESSION_CMD = "zstdmt"


def run(
    corpus_src: str,
    corpus_trg: str,
    output_path: str,
    priors_input_path: Optional[str],
    priors_output_path: Optional[str],
):
    bin = os.environ["BIN"]

    tmp_dir = os.path.join(os.path.dirname(output_path), "tmp")
    os.makedirs(tmp_dir, exist_ok=True)

    if corpus_src.endswith(".zst"):
        logger.info("Decompressing source corpus...")
        subprocess.check_call([COMPRESSION_CMD, "-d", "-f", "--rm", corpus_src])
        corpus_src = corpus_src[:-4]

    if corpus_trg.endswith(".zst"):
        logger.info("Decompressing target corpus...")
        subprocess.check_call([COMPRESSION_CMD, "-d", "-f", "--rm", corpus_trg])
        corpus_trg = corpus_trg[:-4]

    with ExitStack() as stack:
        fwd_path, rev_path = align(
            corpus_src=corpus_src,
            corpus_trg=corpus_trg,
            priors_input_path=priors_input_path,
            stack=stack,
            tmp_dir=tmp_dir,
        )
        symmetrize(
            bin=bin, fwd_path=fwd_path, rev_path=rev_path, output_path=output_path, stack=stack
        )

        if priors_output_path:
            write_priors(
                corpus_src=corpus_src,
                corpus_trg=corpus_trg,
                fwd_path=fwd_path,
                rev_path=rev_path,
                priors_output_path=priors_output_path,
                stack=stack,
            )


def align(
    corpus_src: str,
    corpus_trg: str,
    priors_input_path: Optional[str],
    stack: ExitStack,
    tmp_dir: str,
):
    if priors_input_path:
        logger.info(f"Using provided priors: {priors_input_path}")
        priors_input = stack.enter_context(open(priors_input_path, "r", encoding="utf-8"))
    else:
        priors_input = None

    # We use eflomal aligner.
    # It is less memory intensive than fast_align.
    # fast_align failed with OOM in a large white-space tokenized corpus
    aligner = eflomal.Aligner()
    src_input = stack.enter_context(open(corpus_src, "r", encoding="utf-8"))
    trg_input = stack.enter_context(open(corpus_trg, "r", encoding="utf-8"))
    fwd_path = os.path.join(tmp_dir, "aln.fwd")
    rev_path = os.path.join(tmp_dir, "aln.rev")
    logger.info("Calculating alignments...")
    aligner.align(
        src_input,
        trg_input,
        links_filename_fwd=fwd_path,
        links_filename_rev=rev_path,
        priors_input=priors_input,
        quiet=False,
        use_gdb=False,
    )
    return fwd_path, rev_path


def symmetrize(bin: str, fwd_path: str, rev_path: str, output_path: str, stack: ExitStack):
    """
    Symmetrize the forward and reverse alignments of the corpus.

    Alignments are generated in two directions, source to target, and target to source.
    This function symmetrizes them so that both directions share the same alignment information.
    It uses `atools` binary from `fast_align`
    """
    logger.info("Symmetrizing alignments...")
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    # Wrap the file with a compressor stream if it needs to be compressed
    with zstandard.ZstdCompressor().stream_writer(
        stack.enter_context(open(output_path, "wb"))
    ) if output_path.endswith(".zst") else stack.enter_context(
        open(output_path, "w", encoding="utf-8")
    ) as stream:
        with subprocess.Popen(
            [
                os.path.join(bin, "atools"),
                "-i",
                fwd_path,
                "-j",
                rev_path,
                "-c",
                "grow-diag-final-and",
            ],
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
            encoding="utf-8",
        ) as proc:
            for line in proc.stdout:
                stream.write(line.encode("utf-8") if output_path.endswith(".zst") else line)

            proc.wait()
            # Check for any errors in the subprocess execution
            if proc.returncode != 0:
                logger.error(f"atools exit code: {proc.returncode}")
                raise subprocess.CalledProcessError(proc.returncode, proc.args)


def write_priors(
    corpus_src: str,
    corpus_trg: str,
    fwd_path: str,
    rev_path: str,
    priors_output_path: str,
    stack: ExitStack,
):
    logger.info("Calculating priors...")
    src_input = stack.enter_context(open(corpus_src, "r", encoding="utf-8"))
    trg_input = stack.enter_context(open(corpus_trg, "r", encoding="utf-8"))
    fwd_f = stack.enter_context(open(fwd_path, "r", encoding="utf-8"))
    rev_f = stack.enter_context(open(rev_path, "r", encoding="utf-8"))
    priors_tuple = eflomal.calculate_priors(src_input, trg_input, fwd_f, rev_f)
    logger.info(f"Writing priors to {priors_output_path}...")
    priors_output = stack.enter_context(open(priors_output_path, "w", encoding="utf-8"))
    eflomal.write_priors(priors_output, *priors_tuple)


def main() -> None:
    logger.info(f"Running with arguments: {sys.argv}")
    parser = argparse.ArgumentParser(
        description=__doc__,
        # Preserves whitespace in the help text.
        formatter_class=argparse.RawTextHelpFormatter,
    )

    parser.add_argument("--type", metavar="TYPE", type=str, help="Dataset type: mono or corpus")
    parser.add_argument(
        "--corpus_src",
        metavar="CORPUS_SRC",
        type=str,
        help="Full path to the source sentences in a parallel dataset. Supports decompression using zstd. "
        "For example `fetches/corpus.ru` or `fetches/corpus.ru.zst`",
    )
    parser.add_argument(
        "--corpus_trg",
        metavar="CORPUS_TRG",
        type=str,
        help="Full path to the target sentences in a parallel dataset. Supports decompression using zstd. "
        "For example `fetches/corpus.en` or `fetches/corpus.en.zst`",
    )
    parser.add_argument(
        "--output_path",
        metavar="OUTPUT_PATH",
        type=str,
        help="A full path to the output alignments file. It will be compressed if the path ends with .zst. "
        "For example artifacts/corpus.aln or artifacts/corpus.aln.zst",
    )
    parser.add_argument(
        "--priors_input_path",
        metavar="PRIORS_INPUT_PATH",
        type=str,
        default=None,
        help="A full path to the model priors calculated in advance. This can speed up generation.",
    )
    parser.add_argument(
        "--priors_output_path",
        metavar="PRIORS_OUTPUT_PATH",
        type=str,
        default=None,
        help="Calculate and save the model priors to the specified file path. "
        "The file will be compressed if it ends with .zst",
    )
    args = parser.parse_args()
    logger.info("Starting generating alignments.")
    run(
        args.corpus_src,
        args.corpus_trg,
        args.output_path,
        args.priors_input_path,
        args.priors_output_path,
    )
    logger.info("Finished generating alignments.")


if __name__ == "__main__":
    main()
