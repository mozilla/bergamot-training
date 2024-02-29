import os
import tempfile
from collections import deque
from io import TextIOWrapper
from random import Random
from typing import Iterator, Optional


def shuffle_with_max_lines(
    line_stream: Iterator[str],
    seed: str,
    max_lines: int,
    max_words_in_sentence,
    total_byte_size: int,
) -> Iterator[str]:
    """
    Shuffle a line stream, but only retain up to a maximum number of lines in memory.
    Note that the final ordering is determined by the seed and the contents of the file. So
    running this multiple times on the same dataset will return the same result, but running
    it with the same seed and different content will create a different ordering.

    Only run for monolingual data or where the parallel sentences are separated by a delimiter.

    The distribution should be even unless the initial content is not representative of the
    general size of the sentences, in this case the distribution will be slightly biased. See
    the test cases for more in-depth examples.
    """
    lines = deque()

    random = Random(seed)  # Make this deterministic based on dataset key.

    total_bytes = 0

    # Fill up the lines up until the max, and measure the total bytes.
    for line in line_stream:
        # Encoding returns the underlying byte representation which is then measured.
        total_bytes = total_bytes + len(line.encode("utf-8"))

        if len(line.split()) > max_words_in_sentence:
            # TODO(CJK) - Issue #424
            # This sentence is too long.
            continue

        lines.append(line)

        if len(lines) == max_lines:
            break

    random.shuffle(lines)

    # Consume the rest of the line stream, but sample based on the probability that adding
    # something to the collection will be representative.

    i = 0
    for line in line_stream:
        i = i + 1
        # Continuously adjust this estimation in case the first sampled data is not representative.
        total_bytes = total_bytes + len(line.encode("utf-8"))
        average_bytes_per_line = total_bytes / (max_lines + i)
        estimated_lines = total_byte_size / average_bytes_per_line
        line_sampling_probability = max_lines / estimated_lines

        if random.random() < line_sampling_probability:
            # Shift the deque so the oldest line is shifted out, and this new sample is shifted in.
            lines.popleft()
            lines.append(line)

    # Do a final shuffle to ensure that the newly sampled lines are shuffled with the original
    # set of shuffled lines.
    random.shuffle(lines)

    return lines


def shuffle_in_temp_files(
    line_stream: Iterator[str],
    output: TextIOWrapper,
    seed: str,
    chunk_bytes: int,
    bucket_bytes: int,
    chunk_dir: Optional[str] = tempfile.gettempdir(),
    keep_chunks=False,
):
    """
    Shuffle large datasets by storing chunks to the file system. The ordering is guaranteed to be
    stable across two datasets as long as they are the same length. For instance it could be used
    to shuffle `dataset.en.zst` and `dataset.ca.zst` the same if the two are parallel sentences.

    Take in a stream of lines (from a download, or stdin) and split it out to chunks.

    tmpdir
    ├── chunk.1
    ├── chunk.2
    ├── chunk.3
    ├── chunk.4
    ├── ...
    └── chunk.100

    After the entire dataset is written to chunks, pick random chunks and put them into a
    bucket. Only one bucket is fully loaded into memory at a time, and the contents
    of the bucket is shuffled in memory.

    Bucket:
    ┌───────────┐
    │ chunk.85  │
    │ chunk.3   │
    │ chunk.52  │
    │ chunk.30  │
    │ chunk.12  │
    │ chunk.18  │
    └───────────┘

    • shuffle bucket lines
    • write to output

    At most 1 bucket will be held in memory. At most the dataset + 1 bucket of file space will be
    needed when running this algorithm.
    """
    random = Random(seed)

    chunk_index = 0
    chunk_file = open(os.path.join(chunk_dir, f"chunk.{chunk_index}"), "wt")

    # Write out the chunks to disk.
    bytes_written_to_chunk = 0
    for line in line_stream:
        line_bytes = len(line.encode("utf-8")) + 1

        if bytes_written_to_chunk + line_bytes > chunk_bytes:
            # Start a new chunk.
            chunk_file.close()
            chunk_index += 1
            chunk_file = open(os.path.join(chunk_dir, f"chunk.{chunk_index}"), "wt")
            bytes_written_to_chunk = 0

        chunk_file.write(line + "\n")
        bytes_written_to_chunk += line_bytes

    chunk_file.close()

    # Shuffle the chunk indexes
    chunk_count = chunk_index + 1

    shuffled_chunk_indexes = [*range(chunk_count)]
    random.shuffle(shuffled_chunk_indexes)

    # Load a single bucket into memory, discarding the chunks.
    bucket_count = 0
    bytes_in_bucket = 0
    bucket = []

    for chunk_index in shuffled_chunk_indexes:
        chunk_name = os.path.join(chunk_dir, f"chunk.{chunk_index}")

        # Read in the chunk line by line.
        with open(chunk_name, "r") as file:
            for line in file.readlines():
                bucket.append(line)
                bytes_in_bucket += len(line.encode("utf-8"))

                # If the bucket overflows, shuffle and write it out.
                if bytes_in_bucket > bucket_bytes:
                    random.shuffle(bucket)
                    for shuffled_line in bucket:
                        output.write(shuffled_line)

                    # Create the new bucket.
                    bucket = []
                    bytes_in_bucket = 0
                    bucket_count += 1

        if not keep_chunks:
            os.remove(chunk_name)

    if len(bucket) > 0:
        random.shuffle(bucket)
        for shuffled_line in bucket:
            output.write(shuffled_line)

    print(f"Shuffled with {bucket_count} buckets.")
