#!/usr/bin/env python3
"""
PDF splitter - splits a PDF into chunks of n pages each
"""
import sys
import os
from pathlib import Path

try:
    from pypdf import PdfReader, PdfWriter
except ImportError:
    print("pypdf not found. Installing...")
    os.system(f"{sys.executable} -m pip install pypdf")
    from pypdf import PdfReader, PdfWriter


def split_pdf(input_path, pages_per_chunk):
    """
    Split a PDF into multiple files with n pages each

    Args:
        input_path: Path to input PDF file
        pages_per_chunk: Number of pages per output file
    """
    input_path = Path(input_path)

    if not input_path.exists():
        print(f"Error: File {input_path} not found")
        return

    reader = PdfReader(input_path)
    total_pages = len(reader.pages)

    print(f"Total pages: {total_pages}")
    print(f"Splitting into chunks of {pages_per_chunk} pages...")

    output_dir = input_path.parent / f"{input_path.stem}_split"
    output_dir.mkdir(exist_ok=True)

    chunk_num = 1
    for start_page in range(0, total_pages, pages_per_chunk):
        writer = PdfWriter()
        end_page = min(start_page + pages_per_chunk, total_pages)

        for page_num in range(start_page, end_page):
            writer.add_page(reader.pages[page_num])

        output_filename = output_dir / f"{input_path.stem}_part{chunk_num:03d}_pages{start_page+1}-{end_page}.pdf"
        with open(output_filename, 'wb') as output_file:
            writer.write(output_file)

        print(f"Created: {output_filename.name} (pages {start_page+1}-{end_page})")
        chunk_num += 1

    print(f"\nDone! Split into {chunk_num-1} files in: {output_dir}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python split_pdf.py <pdf_file> <pages_per_chunk>")
        print("Example: python split_pdf.py paper.pdf 10")
        sys.exit(1)

    pdf_file = sys.argv[1]
    try:
        pages_per_chunk = int(sys.argv[2])
        if pages_per_chunk < 1:
            raise ValueError("Pages per chunk must be positive")
    except ValueError as e:
        print(f"Error: Invalid number of pages - {e}")
        sys.exit(1)

    split_pdf(pdf_file, pages_per_chunk)
