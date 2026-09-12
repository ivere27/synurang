"""Build a standalone, offline replay of queue metadata (no image payloads)."""
import argparse
import json
from pathlib import Path


def build_report(directory: Path) -> Path:
    reports = [json.loads(path.read_text()) for path in sorted(directory.glob("*.json"))]
    if not reports:
        raise ValueError("No queue reports found")
    template = Path(__file__).with_name("queue_report.html").read_text()
    data = json.dumps(reports).replace("<", "\\u003c")
    output = directory / "index.html"
    output.write_text(template.replace("/* QUEUE_REPORT_DATA */ []", data))
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    print(f"Open {build_report(parser.parse_args().directory).resolve()}")
