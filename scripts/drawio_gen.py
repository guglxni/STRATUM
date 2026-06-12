#!/usr/bin/env python3
"""
STRATUM draw.io diagram generator.

Emits clean, consistent mxGraph (.drawio) XML with a shared design language so
every diagram across the docs looks like it came from the same hand. Authoring
mxGraph by hand is error-prone; these helpers keep colors, fonts, rounded nodes,
swimlane bands, and orthogonal labeled edges uniform.

Palette (financial meaning, not implementation detail):
  core/senior  -> deep blue     fill #1A3A5C / accent #1A4A8A, white text
  junior       -> green         fill #2D6A4A, white text
  reactive     -> purple        fill #5A2D6E, white text
  peripheral   -> teal-green    fill #2D6A4A dashed, white text
  protocol     -> gray          fill #6E6E73, white text
  soft/info    -> light blue     fill #EEF4FF / border #1A3A5C, dark text
  chain band   -> very light     fill #F7F9FC / border #C7D2DD
"""
from __future__ import annotations
from dataclasses import dataclass, field
from xml.sax.saxutils import escape

FONT = "Helvetica"

PALETTE = {
    "core":    ("#1A3A5C", "#0D2137", "#FFFFFF"),
    "senior":  ("#1A4A8A", "#0D2137", "#FFFFFF"),
    "junior":  ("#2D6A4A", "#16402C", "#FFFFFF"),
    "reactive":("#5A2D6E", "#341A40", "#FFFFFF"),
    "protocol":("#6E6E73", "#3A3A3D", "#FFFFFF"),
    "soft":    ("#EEF4FF", "#1A3A5C", "#10202E"),
    "warn":    ("#F4E2C2", "#9A6A14", "#3A2A08"),
    "ok":      ("#D6F0DE", "#1F7A4D", "#0F3A24"),
}

BAND = {
    "core":    ("#F2F7FC", "#1A3A5C"),
    "senior":  ("#F2F7FC", "#1A4A8A"),
    "junior":  ("#F1F8F3", "#2D6A4A"),
    "reactive":("#F6F1FA", "#5A2D6E"),
    "peripheral":("#F1F8F3", "#2D6A4A"),
    "neutral": ("#F7F9FC", "#C7D2DD"),
    "chainA":  ("#F2F7FC", "#1A3A5C"),
    "chainB":  ("#F1F8F3", "#2D6A4A"),
    "chainC":  ("#F6F1FA", "#5A2D6E"),
    "chainD":  ("#FBF4EC", "#9A6A14"),
}


@dataclass
class Diagram:
    name: str
    width: int = 1400
    height: int = 900
    cells: list[str] = field(default_factory=list)
    _id: int = 1

    def _nid(self) -> str:
        self._id += 1
        return f"n{self._id}"

    def node(self, x, y, w, h, label, kind="soft", *, fontsize=15, bold=True,
             rounded=True, dashed=False, parent="1", node_id=None) -> str:
        fill, stroke, font = PALETTE[kind]
        nid = node_id or self._nid()
        style = (
            f"rounded={1 if rounded else 0};whiteSpace=wrap;html=1;"
            f"fillColor={fill};strokeColor={stroke};fontColor={font};"
            f"fontFamily={FONT};fontSize={fontsize};"
            f"fontStyle={1 if bold else 0};arcSize=12;spacing=6;"
            f"shadow=0;{'dashed=1;dashPattern=6 4;' if dashed else ''}"
        )
        self.cells.append(
            f'<mxCell id="{nid}" value="{escape(label)}" style="{style}" '
            f'vertex="1" parent="{parent}">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>'
        )
        return nid

    def band(self, x, y, w, h, title, kind="neutral", *, parent="1", node_id=None) -> str:
        fill, stroke = BAND[kind]
        nid = node_id or self._nid()
        style = (
            f"rounded=1;whiteSpace=wrap;html=1;fillColor={fill};"
            f"strokeColor={stroke};fontColor={stroke};fontFamily={FONT};"
            f"fontSize=16;fontStyle=1;verticalAlign=top;align=left;"
            f"spacingLeft=16;spacingTop=10;arcSize=6;dashed=0;"
            f"strokeWidth=1.5;"
        )
        self.cells.append(
            f'<mxCell id="{nid}" value="{escape(title)}" style="{style}" '
            f'vertex="1" parent="{parent}">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>'
        )
        return nid

    def note(self, x, y, w, h, label, *, parent="1", fontsize=13) -> str:
        nid = self._nid()
        style = (
            f"rounded=0;whiteSpace=wrap;html=1;fillColor=none;strokeColor=none;"
            f"fontColor=#52606D;fontFamily={FONT};fontSize={fontsize};"
            f"fontStyle=2;align=left;verticalAlign=top;"
        )
        self.cells.append(
            f'<mxCell id="{nid}" value="{escape(label)}" style="{style}" '
            f'vertex="1" parent="{parent}">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>'
        )
        return nid

    def edge(self, src, dst, label="", *, style="solid", color="#52606D",
             parent="1", exitX=None, entryX=None, fontsize=13, points=None):
        nid = self._nid()
        dash = "dashed=1;dashPattern=6 4;" if style == "dashed" else ""
        thick = "strokeWidth=2.5;" if style == "thick" else "strokeWidth=1.6;"
        ex = ""
        if exitX is not None:
            ex += f"exitX={exitX[0]};exitY={exitX[1]};exitDx=0;exitDy=0;"
        if entryX is not None:
            ex += f"entryX={entryX[0]};entryY={entryX[1]};entryDx=0;entryDy=0;"
        st = (
            f"edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;"
            f"strokeColor={color};{thick}{dash}{ex}"
            f"fontFamily={FONT};fontSize={fontsize};fontColor=#33414D;"
            f"labelBackgroundColor=#FFFFFF;endArrow=block;endFill=1;"
        )
        geo = '<mxGeometry relative="1" as="geometry">'
        if points:
            pts = "".join(f'<mxPoint x="{x}" y="{y}"/>' for x, y in points)
            geo += f'<Array as="points">{pts}</Array>'
        geo += "</mxGeometry>"
        self.cells.append(
            f'<mxCell id="{nid}" value="{escape(label)}" style="{st}" '
            f'edge="1" parent="{parent}" source="{src}" target="{dst}">'
            f'{geo}</mxCell>'
        )
        return nid

    def xml(self) -> str:
        body = "".join(self.cells)
        return (
            f'<mxfile host="stratum-gen">'
            f'<diagram id="{escape(self.name)}" name="{escape(self.name)}">'
            f'<mxGraphModel dx="1024" dy="768" grid="0" gridSize="10" guides="1" '
            f'tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" '
            f'pageWidth="{self.width}" pageHeight="{self.height}" math="0" shadow="0">'
            f'<root><mxCell id="0"/><mxCell id="1" parent="0"/>'
            f'{body}</root></mxGraphModel></diagram></mxfile>'
        )

    def save(self, path: str):
        with open(path, "w") as f:
            f.write(self.xml())
