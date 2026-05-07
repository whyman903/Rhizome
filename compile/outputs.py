"""Rich output format generators: Marp slides, matplotlib charts, Obsidian Canvas."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


# ---------------------------------------------------------------------------
# Marp slide decks
# ---------------------------------------------------------------------------

def generate_marp(title: str, body: str, *, theme: str = "default") -> tuple[str, dict]:
    """Prepare Marp slide content.

    Returns ``(body, extra_frontmatter)`` where *extra_frontmatter* contains
    the Marp-specific keys (``marp``, ``theme``, ``paginate``). These need to
    live in the page's own YAML frontmatter — that's the only block Marp's
    CLI parses for global directives. Without them the deck won't render.

    The caller is responsible for including ``---`` slide separators in *body*.
    """
    extra_fm = {
        "marp": True,
        "theme": theme,
        "paginate": True,
    }
    return body.rstrip() + "\n", extra_fm


# ---------------------------------------------------------------------------
# Matplotlib charts
# ---------------------------------------------------------------------------

def generate_chart(title: str, script: str, output_dir: Path) -> Path:
    """Execute a matplotlib *script* and save the resulting image.

    The script receives a pre-set ``OUTPUT_PATH`` variable pointing to the
    target ``.png`` file.  If the script does not call ``savefig`` itself the
    wrapper will call it automatically.

    Returns the path to the saved image.

    Raises ``RuntimeError`` if matplotlib is not installed.
    """
    try:
        import matplotlib  # noqa: F401
    except ModuleNotFoundError:
        raise RuntimeError(
            "matplotlib is required for chart generation. "
            "Install it with: pip install matplotlib"
        )
    from compile.text import slugify

    output_dir.mkdir(parents=True, exist_ok=True)
    slug = slugify(title) or "chart"
    dest = output_dir / f"{slug}.png"
    counter = 1
    while dest.exists():
        dest = output_dir / f"{slug}-{counter}.png"
        counter += 1

    # Build a wrapper script that sets OUTPUT_PATH and auto-saves
    wrapper = (
        "import matplotlib\n"
        "matplotlib.use('Agg')\n"
        "import matplotlib.pyplot as plt\n"
        f"OUTPUT_PATH = {str(dest)!r}\n"
        "\n"
        f"{script}\n"
        "\n"
        "# Auto-save if the script hasn't already\n"
        "import os\n"
        "if not os.path.exists(OUTPUT_PATH):\n"
        "    plt.savefig(OUTPUT_PATH, dpi=150, bbox_inches='tight')\n"
    )

    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as tmp:
        tmp.write(wrapper)
        tmp_path = tmp.name

    try:
        result = subprocess.run(
            [sys.executable, tmp_path],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"Chart script failed (exit {result.returncode}):\n{result.stderr}"
            )
    finally:
        Path(tmp_path).unlink(missing_ok=True)

    if not dest.exists():
        raise RuntimeError("Chart script ran but did not produce an image.")

    return dest


# ---------------------------------------------------------------------------
# Obsidian Canvas
# ---------------------------------------------------------------------------

def generate_canvas(
    title: str,
    nodes: list[dict],
    edges: list[dict] | None = None,
) -> str:
    """Build an Obsidian ``.canvas`` JSON string.

    Each node dict should contain at minimum:
        - ``text``: the card content (markdown string)
    Optional keys: ``id``, ``x``, ``y``, ``width``, ``height``, ``color``,
    ``file`` (for file-reference cards instead of text cards).

    Each edge dict should contain:
        - ``from``: source node id
        - ``to``: target node id
    Optional keys: ``id``, ``fromSide``, ``toSide``, ``label``.

    If positions are omitted, nodes are laid out in a vertical stack.
    """
    if not isinstance(nodes, list):
        raise ValueError("nodes must be a JSON array of objects")
    if edges is not None and not isinstance(edges, list):
        raise ValueError("edges must be a JSON array of objects")

    canvas_nodes = []
    node_ids: list[str] = []
    y_cursor = 0
    default_width = 300
    default_height = 120
    gap = 40

    for i, node in enumerate(nodes):
        if not isinstance(node, dict):
            raise ValueError(f"node {i} must be an object")
        if "text" not in node and "file" not in node:
            raise ValueError(f"node {i} must include either 'text' or 'file'")

        raw_id = node.get("id")
        nid = str(raw_id) if raw_id not in (None, "") else str(uuid.uuid4())[:8]
        x = node.get("x", 0)
        y = node.get("y", y_cursor)
        w = node.get("width", default_width)
        h = node.get("height", default_height)

        entry: dict = {
            "id": nid,
            "x": x,
            "y": y,
            "width": w,
            "height": h,
        }

        if "file" in node:
            entry["type"] = "file"
            entry["file"] = node["file"]
        else:
            entry["type"] = "text"
            entry["text"] = node.get("text", "")

        if "color" in node:
            entry["color"] = node["color"]

        canvas_nodes.append(entry)
        node_ids.append(nid)

        # Advance cursor only when the node didn't provide explicit y
        if "y" not in node:
            y_cursor += h + gap

    canvas_edges = []
    valid_ids = set(node_ids)
    for edge in edges or []:
        if not isinstance(edge, dict):
            raise ValueError("each edge must be an object")
        if "from" not in edge or "to" not in edge:
            raise ValueError("each edge must include 'from' and 'to'")

        eid = edge.get("id") or str(uuid.uuid4())[:8]
        from_ref = edge["from"]
        to_ref = edge["to"]
        # Support integer index references into the node list
        if isinstance(from_ref, int):
            if from_ref < 0 or from_ref >= len(node_ids):
                raise ValueError(f"edge source index {from_ref} is out of range")
            from_ref = node_ids[from_ref]
        if isinstance(to_ref, int):
            if to_ref < 0 or to_ref >= len(node_ids):
                raise ValueError(f"edge target index {to_ref} is out of range")
            to_ref = node_ids[to_ref]
        from_ref = str(from_ref)
        to_ref = str(to_ref)
        if from_ref not in valid_ids:
            raise ValueError(f"edge source '{from_ref}' does not match any node id")
        if to_ref not in valid_ids:
            raise ValueError(f"edge target '{to_ref}' does not match any node id")
        canvas_edges.append({
            "id": eid,
            "fromNode": from_ref,
            "toNode": to_ref,
            "fromSide": edge.get("fromSide", "bottom"),
            "toSide": edge.get("toSide", "top"),
            **({"label": edge["label"]} if "label" in edge else {}),
        })

    return json.dumps({"nodes": canvas_nodes, "edges": canvas_edges}, indent=2)
