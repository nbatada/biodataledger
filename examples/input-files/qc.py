"""Synthetic display recipe. No clinical data or scientific inference."""
from pathlib import Path

def main():
    for name, label in [("library.svg", "Synthetic library QC"), ("genes.svg", "Synthetic genes QC")]:
        Path(name).write_text('<svg xmlns="http://www.w3.org/2000/svg" width="240" height="60"><text x="10" y="30">' + label + '</text></svg>')

if __name__ == "__main__":
    main()
