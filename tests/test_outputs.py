from __future__ import annotations

import json

import pytest
from click.testing import CliRunner

from compile.cli import main
from compile.outputs import generate_canvas, generate_marp
from compile.workspace import init_workspace


class TestGenerateMarp:
    def test_returns_body_and_frontmatter(self) -> None:
        body, fm = generate_marp("My Deck", "# Slide 1\n---\n# Slide 2")
        assert fm["marp"] is True
        assert fm["paginate"] is True
        assert "# Slide 1" in body
        assert "---" in body
        assert "# Slide 2" in body

    def test_custom_theme(self) -> None:
        _, fm = generate_marp("Deck", "content", theme="gaia")
        assert fm["theme"] == "gaia"

    def test_paginate_enabled(self) -> None:
        _, fm = generate_marp("Deck", "content")
        assert fm["paginate"] is True


class TestGenerateCanvas:
    def test_basic_nodes(self) -> None:
        nodes = [
            {"text": "Node A"},
            {"text": "Node B"},
        ]
        result = json.loads(generate_canvas("Test", nodes))
        assert len(result["nodes"]) == 2
        assert result["nodes"][0]["type"] == "text"
        assert result["nodes"][0]["text"] == "Node A"
        assert result["nodes"][1]["y"] > result["nodes"][0]["y"]

    def test_edges(self) -> None:
        nodes = [
            {"id": "a", "text": "A"},
            {"id": "b", "text": "B"},
        ]
        edges = [{"from": "a", "to": "b"}]
        result = json.loads(generate_canvas("Test", nodes, edges))
        assert len(result["edges"]) == 1
        assert result["edges"][0]["fromNode"] == "a"
        assert result["edges"][0]["toNode"] == "b"

    def test_file_node(self) -> None:
        nodes = [{"file": "wiki/articles/topic.md"}]
        result = json.loads(generate_canvas("Test", nodes))
        assert result["nodes"][0]["type"] == "file"
        assert result["nodes"][0]["file"] == "wiki/articles/topic.md"

    def test_explicit_positions(self) -> None:
        nodes = [
            {"text": "A", "x": 100, "y": 200},
            {"text": "B", "x": 300, "y": 400},
        ]
        result = json.loads(generate_canvas("Test", nodes))
        assert result["nodes"][0]["x"] == 100
        assert result["nodes"][0]["y"] == 200
        assert result["nodes"][1]["x"] == 300
        assert result["nodes"][1]["y"] == 400

    def test_empty(self) -> None:
        result = json.loads(generate_canvas("Empty", []))
        assert result["nodes"] == []
        assert result["edges"] == []

    def test_edge_label(self) -> None:
        nodes = [{"id": "a", "text": "A"}, {"id": "b", "text": "B"}]
        edges = [{"from": "a", "to": "b", "label": "relates to"}]
        result = json.loads(generate_canvas("Test", nodes, edges))
        assert result["edges"][0]["label"] == "relates to"

    def test_index_based_edges(self) -> None:
        nodes = [{"text": "First"}, {"text": "Second"}, {"text": "Third"}]
        edges = [{"from": 0, "to": 1}, {"from": 1, "to": 2}]
        result = json.loads(generate_canvas("Test", nodes, edges))
        # Edges should resolve to the auto-generated node IDs
        node_ids = [n["id"] for n in result["nodes"]]
        assert result["edges"][0]["fromNode"] == node_ids[0]
        assert result["edges"][0]["toNode"] == node_ids[1]
        assert result["edges"][1]["fromNode"] == node_ids[1]
        assert result["edges"][1]["toNode"] == node_ids[2]

    def test_rejects_non_list_nodes(self) -> None:
        with pytest.raises(ValueError, match="nodes must be a JSON array of objects"):
            generate_canvas("Bad", {"text": "oops"})  # type: ignore[arg-type]

    def test_rejects_out_of_range_edge_indices(self) -> None:
        with pytest.raises(ValueError, match="edge target index 2 is out of range"):
            generate_canvas("Bad", [{"text": "Only"}], [{"from": 0, "to": 2}])


class TestRenderCommands:
    def test_render_marp_preserves_leading_slide_separator(self, tmp_path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        result = runner.invoke(
            main,
            ["render", "marp", "Deck", "--path", str(tmp_path), "--body", "---\n# Slide 1"],
        )

        assert result.exit_code == 0
        content = (tmp_path / "wiki" / "outputs" / "Deck.md").read_text()
        assert "\n# Deck\n" not in content
        assert content.rstrip().endswith("---\n# Slide 1")

    def test_render_marp_reads_body_file(self, tmp_path) -> None:
        init_workspace(tmp_path, "Test")
        body_file = tmp_path / "deck.md"
        body_file.write_text("# Slide 1\n---\n# Slide 2")
        runner = CliRunner()

        result = runner.invoke(
            main,
            ["render", "marp", "Deck", "--path", str(tmp_path), "--body-file", str(body_file)],
        )

        assert result.exit_code == 0
        content = (tmp_path / "wiki" / "outputs" / "Deck.md").read_text()
        assert "# Slide 2" in content

    def test_render_marp_rejects_body_and_body_file(self, tmp_path) -> None:
        init_workspace(tmp_path, "Test")
        body_file = tmp_path / "deck.md"
        body_file.write_text("# Slide 1")
        runner = CliRunner()

        result = runner.invoke(
            main,
            [
                "render",
                "marp",
                "Deck",
                "--path",
                str(tmp_path),
                "--body",
                "# Slide 1",
                "--body-file",
                str(body_file),
            ],
        )

        assert result.exit_code != 0
        assert "Use either --body or --body-file" in result.output

    def test_render_chart_reads_script_file(self, tmp_path, monkeypatch) -> None:
        init_workspace(tmp_path, "Test")
        script_file = tmp_path / "chart.py"
        script_file.write_text("print('chart')")
        runner = CliRunner()
        captured: list[str] = []

        def fake_generate_chart(title: str, script: str, output_dir) -> object:
            captured.append(script)
            output_dir.mkdir(parents=True, exist_ok=True)
            image_path = output_dir / "deck.png"
            image_path.write_bytes(b"png")
            return image_path

        monkeypatch.setattr("compile.cli.generate_chart", fake_generate_chart)
        result = runner.invoke(
            main,
            ["render", "chart", "Deck", "--path", str(tmp_path), "--script-file", str(script_file)],
        )

        assert result.exit_code == 0
        assert captured == ["print('chart')"]
        content = (tmp_path / "wiki" / "outputs" / "Deck.md").read_text()
        assert "print('chart')" in content

    def test_render_chart_rejects_script_and_script_file(self, tmp_path) -> None:
        init_workspace(tmp_path, "Test")
        script_file = tmp_path / "chart.py"
        script_file.write_text("print('chart')")
        runner = CliRunner()

        result = runner.invoke(
            main,
            [
                "render",
                "chart",
                "Deck",
                "--path",
                str(tmp_path),
                "--script",
                "print('chart')",
                "--script-file",
                str(script_file),
            ],
        )

        assert result.exit_code != 0
        assert "Use either --script or --script-file" in result.output

    def test_render_chart_rejects_non_utf8_script_file(self, tmp_path) -> None:
        init_workspace(tmp_path, "Test")
        script_file = tmp_path / "chart.py"
        script_file.write_bytes(b"\xff")
        runner = CliRunner()

        result = runner.invoke(
            main,
            ["render", "chart", "Deck", "--path", str(tmp_path), "--script-file", str(script_file)],
        )

        assert result.exit_code != 0
        assert "Failed to read script file as UTF-8" in result.output

    def test_render_canvas_reads_json_files(self, tmp_path) -> None:
        init_workspace(tmp_path, "Test")
        nodes_file = tmp_path / "nodes.json"
        edges_file = tmp_path / "edges.json"
        nodes_file.write_text('[{"id": "a", "text": "Node A"}, {"id": "b", "text": "Node B"}]')
        edges_file.write_text('[{"from": "a", "to": "b", "label": "supports"}]')
        runner = CliRunner()

        result = runner.invoke(
            main,
            [
                "render",
                "canvas",
                "Map",
                "--path",
                str(tmp_path),
                "--nodes-file",
                str(nodes_file),
                "--edges-file",
                str(edges_file),
            ],
        )

        assert result.exit_code == 0
        assert (tmp_path / "wiki" / "outputs" / "map.canvas").exists()
        content = (tmp_path / "wiki" / "outputs" / "Map.md").read_text()
        assert "Nodes: 2 | Edges: 1" in content

    def test_render_canvas_rejects_nodes_and_nodes_file(self, tmp_path) -> None:
        init_workspace(tmp_path, "Test")
        nodes_file = tmp_path / "nodes.json"
        nodes_file.write_text('[{"text": "Node A"}]')
        runner = CliRunner()

        result = runner.invoke(
            main,
            [
                "render",
                "canvas",
                "Map",
                "--path",
                str(tmp_path),
                "--nodes",
                '[{"text": "Node A"}]',
                "--nodes-file",
                str(nodes_file),
            ],
        )

        assert result.exit_code != 0
        assert "Use either --nodes or --nodes-file" in result.output

    def test_render_canvas_rejects_edges_and_edges_file(self, tmp_path) -> None:
        init_workspace(tmp_path, "Test")
        nodes_file = tmp_path / "nodes.json"
        edges_file = tmp_path / "edges.json"
        nodes_file.write_text('[{"text": "Node A"}]')
        edges_file.write_text("[]")
        runner = CliRunner()

        result = runner.invoke(
            main,
            [
                "render",
                "canvas",
                "Map",
                "--path",
                str(tmp_path),
                "--nodes-file",
                str(nodes_file),
                "--edges",
                "[]",
                "--edges-file",
                str(edges_file),
            ],
        )

        assert result.exit_code != 0
        assert "Use either --edges or --edges-file" in result.output

    def test_render_canvas_reports_invalid_json_from_file(self, tmp_path) -> None:
        init_workspace(tmp_path, "Test")
        nodes_file = tmp_path / "nodes.json"
        nodes_file.write_text("{not valid json}")
        runner = CliRunner()

        result = runner.invoke(
            main,
            ["render", "canvas", "Map", "--path", str(tmp_path), "--nodes-file", str(nodes_file)],
        )

        assert result.exit_code != 0
        assert "Invalid JSON" in result.output

    def test_render_canvas_rejects_invalid_payload_shape(self, tmp_path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        result = runner.invoke(
            main,
            [
                "render",
                "canvas",
                "Bad",
                "--path",
                str(tmp_path),
                "--nodes",
                '{"text":"not an array"}',
            ],
        )

        assert result.exit_code != 0
        assert "Invalid canvas payload" in result.output
